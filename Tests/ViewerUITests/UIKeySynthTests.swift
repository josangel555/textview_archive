import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// UIEventSynth key layer (TSK-818) — the host-testable half of the real-keydown
/// interaction layer. The NSEvent stream builder (`keyEvents`) and the
/// flag/glyph translation helpers are PURE: they run in the host test process
/// against a laid-out (un-ordered) window, no GUI session. The actual CGEvent
/// injection (`typeKeys`) needs a WindowServer + GUI login session, so it runs
/// ONLY in the VM GUI lane — but everything up to delivery is pinned here so a
/// keycode/modifier/characters regression fails on the host gate.
@MainActor
final class UIKeySynthTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        return win
    }

    // MARK: - keyEvents: NSEvent stream

    /// Typing "Hi" must produce a keyDown/keyUp pair per char, with the keycode
    /// from the spec, the AppKit shift flag on 'H', and the reported characters
    /// (uppercased glyph on the shifted key) that the focused field inserts.
    func test_keyEvents_typesString_downUpPerChar() throws {
        let win = makeWindow()
        defer { win.close() }
        let spec = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "Hi"))
        let events = try XCTUnwrap(UIEventSynth.keyEvents(spec: spec, in: win))

        XCTAssertEqual(events.map(\.type),
                       [.keyDown, .keyUp, .keyDown, .keyUp])
        // 'H' = ⇧ + h (keycode 0x04); 'i' = i (keycode 0x22).
        XCTAssertEqual(events[0].keyCode, 0x04)
        XCTAssertTrue(events[0].modifierFlags.contains(.shift), "'H' carries shift")
        XCTAssertEqual(events[0].characters, "H", "shifted glyph is uppercased")
        XCTAssertEqual(events[2].keyCode, 0x22)
        XCTAssertFalse(events[2].modifierFlags.contains(.shift), "'i' is unshifted")
        XCTAssertEqual(events[2].characters, "i")
    }

    /// A ⌘C chord: command flag on the keyDown, and `characters` is EMPTY — a
    /// command chord is routed as a command (doCommandBySelector), not inserted
    /// as text. This is precisely the routing the CM6/AppKit key-tail bugs hit.
    func test_keyEvents_commandChord_emptyCharacters() throws {
        let win = makeWindow()
        defer { win.close() }
        let spec = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+c"))
        let events = try XCTUnwrap(UIEventSynth.keyEvents(spec: spec, in: win))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].type, .keyDown)
        XCTAssertEqual(events[0].keyCode, 0x08)
        XCTAssertTrue(events[0].modifierFlags.contains(.command))
        XCTAssertEqual(events[0].characters, "",
            "a command chord inserts no text — it routes as a command")
    }

    /// An arrow key: no inherent glyph, so `characters` is empty and the
    /// keycode is the navigation key. (The bug tail includes caret-nav routing.)
    func test_keyEvents_arrowKey_navigationNoText() throws {
        let win = makeWindow()
        defer { win.close() }
        let spec = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "left"))
        let events = try XCTUnwrap(UIEventSynth.keyEvents(spec: spec, in: win))
        XCTAssertEqual(events[0].keyCode, 0x7B)
        XCTAssertEqual(events[0].characters, "")
        XCTAssertEqual(events[0].charactersIgnoringModifiers, "")
    }

    func test_keyEvents_multipleChords_inOrder() throws {
        let win = makeWindow()
        defer { win.close() }
        let spec = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+a delete"))
        let events = try XCTUnwrap(UIEventSynth.keyEvents(spec: spec, in: win))
        // cmd+a (down/up), delete (down/up)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].keyCode, 0x00)
        XCTAssertTrue(events[0].modifierFlags.contains(.command))
        XCTAssertEqual(events[2].keyCode, 0x33)
    }

    // MARK: - flag / glyph translation

    func test_nsFlags_translation() {
        let flags = UIEventSynth.nsFlags(for: [.command, .shift, .control, .option])
        XCTAssertTrue(flags.contains(.command))
        XCTAssertTrue(flags.contains(.shift))
        XCTAssertTrue(flags.contains(.control))
        XCTAssertTrue(flags.contains(.option))
        XCTAssertTrue(UIEventSynth.nsFlags(for: []).isEmpty)
    }

    func test_cgFlags_translation() {
        let flags = UIEventSynth.cgFlags(for: [.command, .option])
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskAlternate))
        XCTAssertFalse(flags.contains(.maskShift))
        XCTAssertFalse(flags.contains(.maskControl))
    }

    func test_shiftedGlyph_symbolRow() {
        XCTAssertEqual(UIEventSynth.shiftedGlyph(forBase: "1"), "!")
        XCTAssertEqual(UIEventSynth.shiftedGlyph(forBase: "/"), "?")
        XCTAssertEqual(UIEventSynth.shiftedGlyph(forBase: "="), "+")
        XCTAssertEqual(UIEventSynth.shiftedGlyph(forBase: "a"), "A")
    }

    func test_characters_rules() throws {
        // Plain letter inserts its glyph.
        let a = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "a")).strokes[0]
        XCTAssertEqual(UIEventSynth.characters(for: a), "a")
        // Shifted letter inserts uppercase.
        let A = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "A")).strokes[0]
        XCTAssertEqual(UIEventSynth.characters(for: A), "A")
        // Command chord inserts nothing.
        let cmdC = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+c")).strokes[0]
        XCTAssertEqual(UIEventSynth.characters(for: cmdC), "")
        // Named navigation key inserts nothing.
        let left = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "left")).strokes[0]
        XCTAssertEqual(UIEventSynth.characters(for: left), "")
    }
}
