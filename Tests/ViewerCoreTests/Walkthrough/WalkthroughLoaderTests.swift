import XCTest
@testable import ViewerCore

/// `WalkthroughLoader` is the security boundary for the file-drop
/// transport — these tests pin the rejection rules so a regression
/// can't sneak a path-escape past us.
final class WalkthroughLoaderTests: XCTestCase {

    // MARK: - Happy path

    func test_validScript_loads() {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "ok",
          "title": "Valid",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
                { "kind": "openFile", "path": "src/A.swift" }
            ]},
            { "id": "s2", "actions": [{ "kind": "narrateOnly" }] }
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        switch r {
        case .success(let s):
            XCTAssertEqual(s.id, "ok")
            XCTAssertEqual(s.steps.count, 2)
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }
    }

    func test_validScript_withoutRootHint_loads() {
        // Without rootHint, path-escape checking is intentionally
        // skipped — the caller has accepted absolute-paths-only.
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "no-root",
          "title": "No root",
          "steps": [
            { "id": "s1", "actions": [
                { "kind": "openFile", "path": "/usr/bin/whatever" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .success = r else {
            return XCTFail("Expected success, got \(r)")
        }
    }

    // MARK: - Schema rejection

    func test_unknownSchemaVersion_rejected() {
        // A well-formed script declaring a version this binary doesn't
        // know must fail with the structured `unsupportedSchema` error
        // (NOT decodingFailed) so the UI can say "update the app" rather
        // than report a parse error. This is the graceful-failure
        // contract for an old binary handed a newer script.
        let json = """
        { "schema": "textview.walkthrough/v99", "id": "x",
          "title": "T", "steps": [] }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.unsupportedSchema(let version, let supported)) = r else {
            return XCTFail("Expected unsupportedSchema, got \(r)")
        }
        XCTAssertEqual(version, "textview.walkthrough/v99")
        // The reported supported set is the current known versions.
        XCTAssertTrue(supported.contains("textview.walkthrough/v1"))
        XCTAssertTrue(supported.contains("textview.walkthrough/v2"))
    }

    func test_v2Schema_loads() {
        // v2 is a known version — a v2 script with only v1-era verbs
        // must load cleanly (additive evolution).
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "v2-ok", "title": "V2",
          "steps": [{ "id": "s1", "actions": [{ "kind": "narrateOnly" }] }]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .success(let s) = r else {
            return XCTFail("Expected success, got \(r)")
        }
        XCTAssertEqual(s.schema, .v2)
    }

    func test_flashVerb_loadsAndValidatesPathEscape() {
        // The flash verb carries an optional `path` — the loader's
        // path-escape pass must cover it (exhaustive `pathsIn` switch).
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "flash-escape", "title": "Flash",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "flash", "path": "../../etc/passwd",
                "startLine": 1, "endLine": 2 }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape(let sid, _)) = r else {
            return XCTFail("Expected pathEscape on flash path, got \(r)")
        }
        XCTAssertEqual(sid, "s1")
    }

    func test_diagramImage_pathEscape_rejected() {
        // The `image` diagram kind references the file system via `data`,
        // so the loader's path-escape pass must cover it — otherwise a
        // script could point an illustration at /etc/passwd.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "diagram-escape", "title": "Diagram",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "diagram", "diagramKind": "image",
                "data": "../../etc/passwd" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape(let sid, let p)) = r else {
            return XCTFail("Expected pathEscape on diagram image, got \(r)")
        }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(p, "../../etc/passwd")
    }

    func test_diagramImage_inFence_loads() {
        // An image path that stays inside the fence is accepted.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "diagram-ok", "title": "Diagram",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "diagram", "diagramKind": "image",
                "data": "assets/arch.png", "caption": "arch" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .success = r else {
            return XCTFail("Expected success for in-fence image, got \(r)")
        }
    }

    func test_diagramMermaid_dataNotTreatedAsPath() {
        // Mermaid (and ASCII) `data` is INLINE content, not a path. A
        // mermaid source containing slashes / dots must NOT trip the
        // path-escape check — only the `image` kind is path-bearing.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "diagram-mermaid", "title": "Diagram",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "diagram", "diagramKind": "mermaid",
                "data": "graph TD; ../x-->/etc/passwd;" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .success = r else {
            return XCTFail("Mermaid data must not be path-checked, got \(r)")
        }
    }

    func test_diagramAscii_dataNotTreatedAsPath() {
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "diagram-ascii", "title": "Diagram",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "diagram", "diagramKind": "ascii",
                "data": "../../not a path just art" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .success = r else {
            return XCTFail("ASCII data must not be path-checked, got \(r)")
        }
    }

    func test_missingRequiredField_rejected() {
        // `title` is required by the model — no default.
        let json = """
        { "schema": "textview.walkthrough/v1", "id": "x", "steps": [] }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.decodingFailed) = r else {
            return XCTFail("Expected decodingFailed, got \(r)")
        }
    }

    func test_malformedJSON_rejected() {
        let json = "{ not actually json"
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.decodingFailed) = r else {
            return XCTFail("Expected decodingFailed, got \(r)")
        }
    }

    // MARK: - Path-escape rejection

    func test_pathEscapeViaDotDot_rejected() {
        // `../../etc/passwd` standardized against `/tmp/repo` lands
        // outside the root → reject.
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "evil", "title": "Evil",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "openFile", "path": "../../etc/passwd" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape(let sid, let p)) = r else {
            return XCTFail("Expected pathEscape, got \(r)")
        }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(p, "../../etc/passwd")
    }

    func test_pathEscapeViaAbsolutePath_rejected() {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "abs", "title": "Absolute",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "openFile", "path": "/etc/passwd" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape) = r else {
            return XCTFail("Expected pathEscape, got \(r)")
        }
    }

    func test_pathEscapeViaSiblingPrefix_rejected() {
        // Trailing-slash check: `/tmp/repofoo` must NOT count as
        // inside `/tmp/repo`.
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "sib", "title": "Sibling",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "openFile", "path": "/tmp/repofoo/A.swift" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape) = r else {
            return XCTFail("Expected pathEscape, got \(r)")
        }
    }

    func test_pathEscape_checksAllActionVariants() {
        // splitFile has two paths — make sure the second one is also
        // checked, not just the first.
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "split", "title": "Split",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "splitFile",
                "path": "src/ok.swift",
                "alongside": "../../etc/passwd" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape) = r else {
            return XCTFail("Expected pathEscape for `alongside`, got \(r)")
        }
    }

    func test_pathEscape_popoverLineAnchorChecked() {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "pop", "title": "Pop",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [
              { "kind": "showPopover", "body": "hi",
                "anchor": { "line": { "path": "../../etc/passwd", "line": 1 } } }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.pathEscape) = r else {
            return XCTFail("Expected pathEscape on popover anchor, got \(r)")
        }
    }

    // MARK: - Duplicate step ids

    func test_duplicateStepIDs_rejected() {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "dup", "title": "Dup",
          "steps": [
            { "id": "s1", "actions": [{ "kind": "narrateOnly" }] },
            { "id": "s1", "actions": [{ "kind": "narrateOnly" }] }
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.duplicateStepID(let id)) = r else {
            return XCTFail("Expected duplicateStepID, got \(r)")
        }
        XCTAssertEqual(id, "s1")
    }

    // MARK: - Disk read

    func test_loadFromFile_roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-loader-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = """
        { "schema": "textview.walkthrough/v1", "id": "f",
          "title": "F", "steps": [
            { "id": "s1", "actions": [{ "kind": "narrateOnly" }] }
        ] }
        """
        try Data(json.utf8).write(to: tmp)
        let r = WalkthroughLoader.load(fileAt: tmp)
        guard case .success(let s) = r else {
            return XCTFail("Expected success, got \(r)")
        }
        XCTAssertEqual(s.id, "f")
    }

    func test_loadFromMissingFile_returnsIoFailed() {
        let nowhere = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        let r = WalkthroughLoader.load(fileAt: nowhere)
        guard case .failure(.ioFailed) = r else {
            return XCTFail("Expected ioFailed, got \(r)")
        }
    }

    /// Sanity test for the relative-path resolution that's
    /// platform-fragile (Swift 6.1 vs 6.3 Foundation behavior
    /// diverges for URL(...relativeTo:)). Loader uses
    /// NSString.appendingPathComponent under the hood; pin that here
    /// so a future "simplification" can't silently regress to the
    /// URL-based approach.
    func test_relativePath_resolvesAgainstRootHintConsistently() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkthrough-loader-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "r",
          "title": "R",
          "rootHint": "\(tmp.path)",
          "steps": [
            { "id": "s1", "actions": [
                { "kind": "openFile", "path": "deep/nested/A.swift" }
            ]}
          ]
        }
        """
        guard case .success = WalkthroughLoader.load(data: Data(json.utf8)) else {
            return XCTFail("expected success — `deep/nested/A.swift` is under rootHint")
        }
    }
}
