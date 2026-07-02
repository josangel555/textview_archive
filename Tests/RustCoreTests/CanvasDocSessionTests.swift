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
