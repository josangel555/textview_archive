import XCTest
import SwiftUI
@testable import ViewerUI

/// UX-H (#230) — presence / construction check for the reusable
/// `IconHoverButtonStyle`. The hover fill, scale, and pointing-hand
/// cursor are visual + require a live NSApplication/window (exercised by
/// the VM-only UI bundles + the manual checklist), so there is nothing
/// behavioural to assert host-side. What we CAN pin host-green:
///   * the style type exists, is a `ButtonStyle`, and its `makeBody`
///     produces a view for a configuration — i.e. it compiles + conforms,
///   * the `isSelected` / `cornerRadius` knobs are wired,
/// so a refactor that drops the shared style (sending callers back to
/// inert `.plain` buttons) breaks the build here rather than silently.
///
/// Host-safe: constructing a `ButtonStyle` + calling `makeBody` allocates
/// no window. Run with the class filter `ViewerUITests.IconHoverButtonStyleTests`.
@MainActor
final class IconHoverButtonStyleTests: XCTestCase {

    /// The `isSelected` knob holds the passed value for both states. (We
    /// can't synthesize a `ButtonStyle.Configuration` to call `makeBody`
    /// directly — no public initializer — so we assert on the stored knobs,
    /// the host-observable surface.)
    func test_isSelected_holdsPassedValue() {
        XCTAssertFalse(IconHoverButtonStyle().isSelected)
        XCTAssertTrue(IconHoverButtonStyle(isSelected: true).isSelected)
    }

    /// Corner radius is configurable (call sites pass a zoom-scaled radius).
    func test_cornerRadius_isConfigurable() {
        let style = IconHoverButtonStyle(cornerRadius: 9)
        XCTAssertEqual(style.cornerRadius, 9, accuracy: 0.001)
    }

    /// Default corner radius matches the sibling `RowHoverButtonStyle` (5),
    /// so the two reusable styles round their fills consistently.
    func test_defaultCornerRadius_matchesRowStyle() {
        XCTAssertEqual(IconHoverButtonStyle().cornerRadius,
                       RowHoverButtonStyle().cornerRadius,
                       accuracy: 0.001)
    }

    /// The style conforms to `ButtonStyle` (the property the whole
    /// `.buttonStyle(...)` application relies on). A compile-time fact, but
    /// asserting it documents the contract + fails loudly if the
    /// conformance is ever dropped.
    func test_conformsToButtonStyle() {
        func accept<S: ButtonStyle>(_: S) {}
        accept(IconHoverButtonStyle())
        accept(IconHoverButtonStyle(cornerRadius: 4, isSelected: true))
    }
}
