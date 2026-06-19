import XCTest
@testable import ViewerCore

/// Codable round-trip tests for `WalkthroughScript` and its action
/// variants. Types ship ahead of the engine (commit bbae9d5) so we
/// pin the wire format here — the loader and engine will arrive in
/// follow-up commits and rely on this shape being stable.
///
/// Coverage matrix:
///   - Every `Action` variant encodes a `kind` discriminator and
///     decodes back to the same case.
///   - Unknown `kind` rejects the whole script.
///   - Wrong `schema` value rejects the whole script.
///   - Optional fields round-trip nil correctly.
final class WalkthroughScriptTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Helpers

    private func roundTrip(_ script: WalkthroughScript) throws -> WalkthroughScript {
        let data = try encoder.encode(script)
        return try decoder.decode(WalkthroughScript.self, from: data)
    }

    private func makeScript(actions: [Action]) -> WalkthroughScript {
        WalkthroughScript(
            id: "wt-test",
            title: "Test",
            subtitle: "subtitle",
            author: "claude:opus-4.7",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            estimatedDurationSec: 60,
            rootHint: "/tmp/repo",
            defaultTargets: DefaultTargets(editor: .main, popover: .anchorToEditor),
            steps: [
                Step(id: "s1", narration: "n", speakerLabel: "claude",
                     dwellSec: 1.5, actions: actions)
            ]
        )
    }

    // MARK: - Top-level round-trip

    func test_fullScript_roundTrips() throws {
        let s = makeScript(actions: [.narrateOnly])
        let r = try roundTrip(s)
        XCTAssertEqual(r, s)
    }

    func test_optionalFields_roundTripNil() throws {
        // Minimum legal script: id + title + schema + steps only.
        let s = WalkthroughScript(
            id: "minimal",
            title: "Minimal",
            steps: [Step(id: "only", actions: [.narrateOnly])]
        )
        let r = try roundTrip(s)
        XCTAssertEqual(r, s)
        XCTAssertNil(r.subtitle)
        XCTAssertNil(r.author)
        XCTAssertNil(r.createdAt)
        XCTAssertNil(r.estimatedDurationSec)
        XCTAssertNil(r.rootHint)
        XCTAssertNil(r.defaultTargets)
    }

    // MARK: - Every Action variant

    func test_openFile_roundTrips() throws {
        let a = Action.openFile(OpenFilePayload(
            path: "Sources/X.swift", target: .split
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_revealLine_roundTrips() throws {
        let a = Action.revealLine(RevealLinePayload(path: nil, line: 42))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_highlightRange_roundTrips() throws {
        let a = Action.highlightRange(HighlightRangePayload(
            path: "a.swift", startLine: 10, endLine: 12, style: .agent
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_showPopover_roundTrips() throws {
        let a = Action.showPopover(ShowPopoverPayload(
            body: "**hi**",
            anchor: .line(path: "a.swift", line: 11),
            style: .floating
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_setView_roundTrips() throws {
        let a = Action.setView(SetViewPayload(mode: .source, path: nil))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_splitFile_roundTrips() throws {
        let a = Action.splitFile(SplitFilePayload(
            path: "b.swift", alongside: "a.swift"
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_runDiff_roundTrips() throws {
        let a = Action.runDiff(RunDiffPayload(
            sha: "abc123", path: "a.swift", target: .main
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_awaitUser_roundTrips() throws {
        let a = Action.awaitUser(AwaitUserPayload(
            prompt: "Pick:", placeholder: "type…",
            pills: ["one", "two"]
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_addBookmark_roundTrips() throws {
        let a = Action.addBookmark(AddBookmarkPayload(
            path: "a.swift", line: 7
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_revealInSidebar_roundTrips() throws {
        let a = Action.revealInSidebar(RevealInSidebarPayload(path: "a.swift"))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_openGitPanel_roundTrips() throws {
        let a = Action.openGitPanel(OpenGitPanelPayload(tab: .log))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_narrateOnly_roundTrips() throws {
        let a = Action.narrateOnly
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_flash_roundTrips_allFields() throws {
        let a = Action.flash(FlashPayload(
            path: "a.swift", startLine: 10, endLine: 14,
            style: .warn, durationMs: 1200
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_flash_roundTrips_optionalsNil() throws {
        // path / style / durationMs are all optional (current file,
        // .focus, overlay-default duration respectively).
        let a = Action.flash(FlashPayload(startLine: 3, endLine: 3))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
        guard case .flash(let p) = r.steps[0].actions[0] else {
            return XCTFail("not a flash")
        }
        XCTAssertNil(p.path)
        XCTAssertNil(p.style)
        XCTAssertNil(p.durationMs)
    }

    func test_flash_decodesFromWire() throws {
        // Pin the wire shape an external author writes by hand.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "flash", "startLine": 5, "endLine": 8,
              "style": "agent", "durationMs": 600 }
          ]}]
        }
        """
        let s = try decoder.decode(WalkthroughScript.self, from: Data(json.utf8))
        guard case .flash(let p) = s.steps[0].actions[0] else {
            return XCTFail("expected flash, got \(s.steps[0].actions)")
        }
        XCTAssertEqual(p.startLine, 5)
        XCTAssertEqual(p.endLine, 8)
        XCTAssertEqual(p.style, .agent)
        XCTAssertEqual(p.durationMs, 600)
    }

    func test_flash_encodesKindDiscriminator() throws {
        let s = makeScript(actions: [.flash(FlashPayload(
            startLine: 1, endLine: 1
        ))])
        let data = try encoder.encode(s)
        let str = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(str.contains("\"kind\":\"flash\""),
                      "flash action must encode a `kind` discriminator")
    }

    // MARK: - diagram (illustration) verb

    func test_diagram_mermaid_roundTrips() throws {
        let a = Action.diagram(DiagramPayload(
            diagramKind: .mermaid,
            data: "graph TD; A-->B;",
            caption: "the flow"
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_diagram_ascii_roundTrips() throws {
        let a = Action.diagram(DiagramPayload(
            diagramKind: .ascii,
            data: "+---+\n| A |\n+---+",
            caption: nil
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
        guard case .diagram(let p) = r.steps[0].actions[0] else {
            return XCTFail("not a diagram")
        }
        XCTAssertNil(p.caption)
    }

    func test_diagram_image_roundTrips() throws {
        let a = Action.diagram(DiagramPayload(
            diagramKind: .image,
            data: "assets/arch.png",
            caption: "architecture"
        ))
        let r = try roundTrip(makeScript(actions: [a]))
        XCTAssertEqual(r.steps[0].actions, [a])
    }

    func test_diagram_decodesFromWire() throws {
        // Pin the flat wire shape an external author writes by hand:
        // `diagramKind` (not `kind`, which is the action discriminator).
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "diagram", "diagramKind": "mermaid",
              "data": "sequenceDiagram\\n A->>B: hi",
              "caption": "handshake" }
          ]}]
        }
        """
        let s = try decoder.decode(WalkthroughScript.self, from: Data(json.utf8))
        guard case .diagram(let p) = s.steps[0].actions[0] else {
            return XCTFail("expected diagram, got \(s.steps[0].actions)")
        }
        XCTAssertEqual(p.diagramKind, .mermaid)
        XCTAssertEqual(p.data, "sequenceDiagram\n A->>B: hi")
        XCTAssertEqual(p.caption, "handshake")
    }

    func test_diagram_encodesKindDiscriminator() throws {
        let s = makeScript(actions: [.diagram(DiagramPayload(
            diagramKind: .ascii, data: "x"
        ))])
        let data = try encoder.encode(s)
        let str = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(str.contains("\"kind\":\"diagram\""),
                      "diagram action must encode a `kind` discriminator")
        XCTAssertTrue(str.contains("\"diagramKind\":\"ascii\""),
                      "diagram medium must encode under `diagramKind`")
    }

    func test_diagram_unknownKind_isRejected() throws {
        // An unknown medium must reject the whole script — DiagramKind is
        // a closed enum so the player never sees a kind it can't render.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [
            { "kind": "diagram", "diagramKind": "hologram", "data": "x" }
          ]}]
        }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8)
        ))
    }

    // MARK: - Reject paths

    func test_unknownActionKind_isRejected() throws {
        // A script payload that names an action kind the union doesn't
        // know. Loader must refuse rather than silently ignore.
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "x",
          "title": "T",
          "steps": [
            { "id": "s1", "actions": [ { "kind": "teleport" } ] }
          ]
        }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8)
        )) { err in
            // Must be a decoding-corrupted error, not a key-missing
            // error — distinguishes "version drift" from "malformed".
            guard case DecodingError.dataCorrupted = err else {
                return XCTFail("Expected dataCorrupted, got \(err)")
            }
        }
    }

    func test_unknownSchemaVersion_throwsUnsupportedSchemaError() throws {
        // Forward-compat / graceful failure: a script declaring a
        // version this binary doesn't know must throw the structured
        // `UnsupportedSchemaError` (naming the version + the supported
        // set) — NOT a generic dataCorrupted, and NOT a silent
        // best-effort decode against the wrong shape.
        let json = """
        {
          "schema": "textview.walkthrough/v3",
          "id": "x",
          "title": "T",
          "steps": []
        }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8)
        )) { err in
            guard let e = err as? UnsupportedSchemaError else {
                return XCTFail("Expected UnsupportedSchemaError, got \(err)")
            }
            XCTAssertEqual(e.version, "textview.walkthrough/v3")
            XCTAssertEqual(
                e.supported,
                ["textview.walkthrough/v1", "textview.walkthrough/v2"]
            )
        }
    }

    func test_v2Schema_decodes() throws {
        // v2 is a known version and decodes to `.v2`.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [{ "kind": "narrateOnly" }] }]
        }
        """
        let s = try decoder.decode(WalkthroughScript.self, from: Data(json.utf8))
        XCTAssertEqual(s.schema, .v2)
    }

    func test_v2Schema_roundTrips() throws {
        let s = WalkthroughScript(
            schema: .v2,
            id: "v2", title: "V2",
            steps: [Step(id: "s1", actions: [.narrateOnly])]
        )
        let r = try roundTrip(s)
        XCTAssertEqual(r, s)
        XCTAssertEqual(r.schema, .v2)
    }

    func test_unknownActionKind_throwsDataCorrupted_notSchemaError() throws {
        // An unknown VERB (vs unknown SCHEMA) is still a dataCorrupted
        // decode error, not an UnsupportedSchemaError — the two failure
        // modes are distinct. This is the other half of the old-binary
        // graceful-failure story: a v2 binary that doesn't know a future
        // verb rejects the action cleanly.
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "x", "title": "T",
          "steps": [{ "id": "s1", "actions": [{ "kind": "teleport" }] }]
        }
        """
        XCTAssertThrowsError(try decoder.decode(
            WalkthroughScript.self, from: Data(json.utf8)
        )) { err in
            XCTAssertNil(err as? UnsupportedSchemaError,
                         "Unknown verb must NOT surface as a schema error")
            guard case DecodingError.dataCorrupted = err else {
                return XCTFail("Expected dataCorrupted, got \(err)")
            }
        }
    }

    // MARK: - PopoverAnchor union

    func test_popoverAnchor_allCases_roundTrip() throws {
        // PopoverAnchor is an enum with associated values via Codable
        // synthesis. Exercise each case so a future refactor to a
        // tagged-union doesn't silently drop variants.
        let cases: [PopoverAnchor] = [
            .line(path: "a.swift", line: 1),
            .editor,
            .sidebar(section: .files),
            .gitTab(tab: .status),
            .window,
        ]
        for anchor in cases {
            let a = Action.showPopover(ShowPopoverPayload(
                body: "x", anchor: anchor, style: nil
            ))
            let r = try roundTrip(makeScript(actions: [a]))
            XCTAssertEqual(r.steps[0].actions, [a],
                           "PopoverAnchor case \(anchor) did not round-trip")
        }
    }
}
