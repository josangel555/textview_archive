import XCTest

@testable import RustCore

/// Canvas M1.S5c (TSK-1360): the Swift wrapper over the REAL canvas engine,
/// exercised against the actual staticlib — host-safe (no WebKit, no window).
final class CanvasDocSessionTests: XCTestCase {

    func test_open_apply_html_roundtrip_through_real_engine() throws {
        let session = try CanvasDocSession()

        // Empty doc: root page + theme block.
        let html0 = try session.html()
        XCTAssertTrue(html0.contains("data-cv-id=\"pg:1\""))
        XCTAssertTrue(html0.contains("--cv-color-accent"))

        // Build a hero frame + title through the real ops.
        let applied = try session.apply(
            baseRev: 0,
            ops: [
                .insert(
                    id: "nd:hero", kind: "frame", parent: CanvasDocSession.rootPage,
                    pos: .last,
                    props: [
                        ("fill", .token("color.surface")),
                        ("gap", .num(8)),
                    ]),
                .insert(
                    id: "nd:title", kind: "text", parent: "nd:hero", pos: .last,
                    props: [("text", .str("Hello from Swift"))]),
            ])
        XCTAssertEqual(applied.rev, 1)
        XCTAssertFalse(applied.noop)
        XCTAssertEqual(applied.patches.count, 2)
        guard case let .insertNode(parent, _, html) = applied.patches[0] else {
            XCTFail("expected insertNode, got \(applied.patches[0])")
            return
        }
        XCTAssertEqual(parent, "pg:1")
        XCTAssertTrue(html.contains("background:var(--cv-color-surface)"))

        // State stuck: re-lower carries both nodes.
        let html1 = try session.html()
        XCTAssertTrue(html1.contains(">Hello from Swift<"))

        // Update round-trips a setText + setStyle patch pair.
        let upd = try session.apply(
            baseRev: 1,
            ops: [
                .update(
                    id: "nd:title",
                    set: [("text", .str("v2")), ("color", .token("color.accent"))],
                    unset: [])
            ])
        XCTAssertEqual(upd.rev, 2)
        XCTAssertEqual(
            upd.patches,
            [
                .setText(id: "nd:title", text: "v2"),
                .setStyle(id: "nd:title", prop: "color", value: "var(--cv-color-accent)"),
            ])
    }

    func test_rejections_surface_as_typed_swift_errors() throws {
        let session = try CanvasDocSession()
        // Stale rev → conflict rejection with the current rev.
        XCTAssertThrowsError(
            try session.apply(baseRev: 42, ops: [.remove(id: "nd:none")])
        ) { error in
            guard let rejection = error as? CanvasRejection else {
                XCTFail("expected CanvasRejection, got \(error)")
                return
            }
            XCTAssertEqual(rejection.kind, "conflict")
            XCTAssertEqual(rejection.currentRev, 0)
        }
        // Fence violation (text on a frame) → fence rejection with detail.
        XCTAssertThrowsError(
            try session.apply(
                baseRev: 0,
                ops: [
                    .insert(
                        id: "nd:f", kind: "frame", parent: CanvasDocSession.rootPage,
                        pos: .last, props: [("text", .str("nope"))])
                ])
        ) { error in
            guard let rejection = error as? CanvasRejection else {
                XCTFail("expected CanvasRejection, got \(error)")
                return
            }
            XCTAssertEqual(rejection.kind, "fence")
            XCTAssertTrue(rejection.detail.contains("not allowed"))
        }
    }

    func test_lint_rides_the_apply_response() throws {
        let session = try CanvasDocSession()
        let applied = try session.apply(
            baseRev: 0,
            ops: [
                .insert(
                    id: "nd:s", kind: "shape", parent: CanvasDocSession.rootPage, pos: .last,
                    props: [("fill", .str("#ff0000"))])  // raw literal in a themeable slot
            ])
        XCTAssertTrue(
            applied.lint.contains { $0.code == "raw-literal-themeable" && $0.id == "nd:s" },
            "the tier-2 steer must ride the apply; got \(applied.lint)")
    }

    func test_idempotent_replay_is_noop_and_minted_ids_return() throws {
        let session = try CanvasDocSession()
        let op = CanvasOpRequest.insert(
            id: "nd:a", kind: "text", parent: CanvasDocSession.rootPage, pos: .last,
            props: [("text", .str("once"))])
        let first = try session.apply(baseRev: 0, ops: [op])
        XCTAssertEqual(first.rev, 1)
        let replay = try session.apply(baseRev: 1, ops: [op])
        XCTAssertTrue(replay.noop)
        XCTAssertEqual(replay.rev, 1)
        XCTAssertTrue(replay.patches.isEmpty, "replays must not re-patch the DOM")
        // Minted ids come back for id-less inserts.
        let minted = try session.apply(
            baseRev: 1,
            ops: [
                .insert(
                    id: nil, kind: "text", parent: CanvasDocSession.rootPage, pos: .last,
                    props: [("text", .str("minted"))])
            ])
        XCTAssertEqual(minted.minted.count, 1)
        XCTAssertTrue(minted.minted[0].hasPrefix("nd:"))
    }
}

/// UAT-M1 (06-MILESTONES-UAT §M1) at the Swift boundary: the full journey —
/// build via DSL → edit → undo → save → load → re-render identical.
final class CanvasUATM1Tests: XCTestCase {

    func test_uat_m1_journey_dsl_undo_save_load() throws {
        let session = try CanvasDocSession()

        // Build via DSL (token refs + nesting + text sugar).
        let built = try session.applyDSL(
            baseRev: 0,
            """
            frame #hero fill=$color.surface gap=8 {
              text #title "v1" font=$font.h1
            }
            """)
        XCTAssertEqual(built.rev, 1)
        XCTAssertEqual(built.patches.count, 2)
        XCTAssertTrue(try session.html().contains(">v1<"))

        // Edit, then undo restores.
        _ = try session.applyDSL(baseRev: 1, "set #title \"v2\"")
        XCTAssertTrue(try session.html().contains(">v2<"))
        let undoRev = try session.undo()
        XCTAssertEqual(undoRev, 3)
        XCTAssertTrue(try session.html().contains(">v1<"), "undo restored")
        // Empty the stack: one more undo (the build), then nil.
        let secondUndo = try session.undo()
        XCTAssertEqual(secondUndo, 4)
        XCTAssertNil(try session.undo(), "empty history is nil, not an error")

        // Rebuild, project, persist, reload — renders identical.
        _ = try session.applyDSL(
            baseRev: 4,
            """
            frame #card {
              text #t "persisted"
            }
            """)
        let projected = try session.renderDSL()
        XCTAssertTrue(projected.contains("frame #card"))
        let saved = try session.save()
        let reloaded = try CanvasDocSession.load(json: saved)
        XCTAssertEqual(try reloaded.html(), try session.html())
        XCTAssertEqual(try reloaded.renderDSL(), projected)

        // DSL parse failure: typed, line-anchored, kind "dsl".
        XCTAssertThrowsError(
            try reloaded.applyDSL(baseRev: 5, "wormhole #x")
        ) { error in
            guard let rejection = error as? CanvasRejection else {
                XCTFail("expected CanvasRejection, got \(error)")
                return
            }
            XCTAssertEqual(rejection.kind, "dsl")
            XCTAssertTrue(rejection.detail.contains("line 1"), "\(rejection.detail)")
        }
    }
}

/// M2.S1 (TSK-1366): the vocabulary reaches Swift with the document's tokens.
final class CanvasVocabTests: XCTestCase {
    func test_vocabulary_text_and_json_through_the_real_ffi() throws {
        let session = try CanvasDocSession()
        let text = try session.vocabulary()
        XCTAssertTrue(text.contains("ELEMENTS AND THEIR PROPS"))
        XCTAssertTrue(text.contains("frame (container)"))
        XCTAssertTrue(text.contains("$color.accent"))
        XCTAssertTrue(text.contains("conflict"))
        let json = try session.vocabulary(asJSON: true)
        XCTAssertTrue(json.contains("\"kinds\""))
        XCTAssertTrue(json.contains("\"caps\""))
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertNotNil(obj as? [String: Any], "vocab JSON parses")
    }
}
