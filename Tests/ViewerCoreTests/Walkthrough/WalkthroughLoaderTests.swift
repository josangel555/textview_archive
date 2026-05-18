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
        let json = """
        { "schema": "textview.walkthrough/v99", "id": "x",
          "title": "T", "steps": [] }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .failure(.decodingFailed) = r else {
            return XCTFail("Expected decodingFailed, got \(r)")
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
