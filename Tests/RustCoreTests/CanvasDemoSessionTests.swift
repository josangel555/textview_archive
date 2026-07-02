import XCTest

@testable import RustCore

/// Canvas M0 (TSK-1353): the Swift wrapper over the canvas FFI, exercised
/// against the REAL staticlib — host-safe (no WebKit, no window).
final class CanvasDemoSessionTests: XCTestCase {

    func test_open_html_apply_roundtrip_through_real_ffi() throws {
        let session = try CanvasDemoSession()

        // Initial lowering: 201 stamped nodes.
        let html = try session.html()
        XCTAssertEqual(html.components(separatedBy: "data-cv-id=").count - 1, 201)
        XCTAssertTrue(html.contains("Row 0.0"))

        // Apply both op kinds; the plan mirrors them and bumps rev.
        let plan = try session.apply([
            .setText(id: 3, text: "patched from Swift"),
            .setStyle(id: 3, key: "color", value: "rgb(1, 2, 3)"),
        ])
        XCTAssertEqual(plan.rev, 1)
        XCTAssertEqual(plan.rejected, [])
        XCTAssertEqual(
            plan.patches,
            [
                .setText(id: 3, text: "patched from Swift"),
                .setStyle(id: 3, key: "color", value: "rgb(1, 2, 3)"),
            ])

        // State stuck in the core: re-lowering reflects the mutation.
        let html2 = try session.html()
        XCTAssertTrue(html2.contains("patched from Swift"))
        XCTAssertTrue(html2.contains("color:rgb(1, 2, 3);"))
    }

    func test_unknown_id_lands_in_rejected() throws {
        let session = try CanvasDemoSession()
        let plan = try session.apply([.setText(id: 55555, text: "x")])
        XCTAssertEqual(plan.rejected, [55555])
        XCTAssertTrue(plan.patches.isEmpty)
        XCTAssertEqual(plan.rev, 0, "no applied patches ⇒ rev unchanged")
    }

    func test_empty_batch_is_valid_and_rev_stable() throws {
        let session = try CanvasDemoSession()
        let plan = try session.apply([])
        XCTAssertEqual(plan.rev, 0)
        XCTAssertTrue(plan.patches.isEmpty)
        XCTAssertTrue(plan.rejected.isEmpty)
    }
}
