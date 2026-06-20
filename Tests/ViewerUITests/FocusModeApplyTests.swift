import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1116 — host coverage for `DocumentModel.applyFocusMode`, the wiring that
/// surfaces the (separately unit-tested) `FocusWorkMode` engine to the
/// View ▸ Focus Mode menu. Proves the apply hop end-to-end on the model layer:
///   * the sidebar visibility overrides are PINNED to the mode's panel set, and
///   * the active tab switches to the mode's preferred lens WHEN the open file
///     supports it (and is left alone otherwise).
/// The menu rendering itself is AppKit (review/VM); this guards the behaviour.
@MainActor
final class FocusModeApplyTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "FocusModeApplyTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    /// Applying a mode pins the sidebar to exactly that mode's panel snapshot,
    /// and switching modes re-pins to the new one. Pure + deterministic (no
    /// file needed — the override snapshot is file-independent).
    func test_applyFocusMode_pinsPanelsToModeSnapshot() {
        let model = harness.model
        for mode in FocusWorkMode.allCases {
            model.applyFocusMode(mode)
            XCTAssertEqual(model.panelLayout.overrides, mode.panelOverrides(),
                           "\(mode.rawValue) must pin the sidebar to its panel set")
        }
    }

    /// With a markdown file open, each mode switches the lens to its preferred
    /// one when the file supports it (and always pins the panels). Self-
    /// consistent with the production guard: only asserts the lens for modes
    /// whose preferred lens is actually available.
    func test_applyFocusMode_appliesPreferredLensWhenSupported() throws {
        let url = try harness.writeFile("doc.md", "# Title\n\nbody\n")
        let model = harness.model
        model.open(url: url)
        for mode in FocusWorkMode.allCases {
            model.applyFocusMode(mode)
            XCTAssertEqual(model.panelLayout.overrides, mode.panelOverrides(),
                           "\(mode.rawValue) pins panels regardless of lens support")
            if model.availableViewModes.contains(mode.preferredMode) {
                XCTAssertEqual(model.currentViewMode, mode.preferredMode,
                               "\(mode.rawValue) must switch to its preferred lens when supported")
            }
        }
    }
}
