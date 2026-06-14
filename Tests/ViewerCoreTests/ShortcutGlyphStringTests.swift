import XCTest
@testable import ViewerCore

/// TSK-678 — `Shortcut.glyphString`: the macOS menu-glyph rendering used by the
/// Keyboard Shortcuts help page. Pure; host-safe. (`displayString` stays the
/// `cmd+shift+f` config form — these tests pin the human glyph form.)
final class ShortcutGlyphStringTests: XCTestCase {

    func test_letterWithModifiers_uppercasesAndOrdersHIG() {
        XCTAssertEqual(Shortcut(key: "s", modifiers: [.command]).glyphString, "⌘S")
        // Apple HIG modifier order is ⌃⌥⇧⌘ regardless of insertion order.
        XCTAssertEqual(
            Shortcut(key: "r", modifiers: [.command, .shift]).glyphString, "⇧⌘R")
        XCTAssertEqual(
            Shortcut(key: "[", modifiers: [.command, .option]).glyphString, "⌥⌘[")
    }

    func test_allFourModifiers_inCanonicalOrder() {
        let sc = Shortcut(key: "a", modifiers: [.command, .control, .shift, .option])
        XCTAssertEqual(sc.glyphString, "⌃⌥⇧⌘A")
    }

    func test_symbolicKeys_renderAsGlyphs() {
        XCTAssertEqual(Shortcut(key: "tab", modifiers: [.control]).glyphString, "⌃⇥")
        XCTAssertEqual(Shortcut(key: "escape").glyphString, "⎋")
        XCTAssertEqual(Shortcut(key: "return", modifiers: [.command]).glyphString, "⌘⏎")
        XCTAssertEqual(Shortcut(key: "delete").glyphString, "⌫")
        XCTAssertEqual(Shortcut(key: "left").glyphString, "←")
        XCTAssertEqual(Shortcut(key: "right").glyphString, "→")
        XCTAssertEqual(Shortcut(key: "up").glyphString, "↑")
        XCTAssertEqual(Shortcut(key: "down").glyphString, "↓")
        XCTAssertEqual(Shortcut(key: "space").glyphString, "␣")
        XCTAssertEqual(Shortcut(key: "pageup").glyphString, "⇞")
        XCTAssertEqual(Shortcut(key: "pagedown").glyphString, "⇟")
    }

    func test_punctuationKeys_passThrough() {
        XCTAssertEqual(Shortcut(key: "=", modifiers: [.command]).glyphString, "⌘=")
        XCTAssertEqual(Shortcut(key: "-", modifiers: [.command]).glyphString, "⌘-")
        XCTAssertEqual(Shortcut(key: "0", modifiers: [.command]).glyphString, "⌘0")
        XCTAssertEqual(Shortcut(key: "backslash", modifiers: [.command]).glyphString, "⌘\\")
    }

    func test_parseRoundTrip_toGlyph() {
        // The config-string parse path and the glyph render compose as expected.
        XCTAssertEqual(Shortcut.parse("cmd+shift+r")?.glyphString, "⇧⌘R")
        XCTAssertEqual(Shortcut.parse("ctrl+tab")?.glyphString, "⌃⇥")
        XCTAssertEqual(Shortcut.parse("opt+cmd+f")?.glyphString, "⌥⌘F")
    }
}
