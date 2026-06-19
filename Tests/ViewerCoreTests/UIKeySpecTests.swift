import XCTest
@testable import ViewerCore

/// `UIKeySpec` — the host-testable synthesis-spec builder (TSK-818): the
/// keycode/modifier mapping for a given character / chord. The actual CGEvent
/// injection runs on the VM GUI lane; everything UP TO the event — which
/// physical key + which modifiers + which glyph — is PURE LOGIC and pinned
/// here. Strict grammar: a typo'd modifier or unknown key must FAIL the parse,
/// never silently degrade into the wrong keystroke (the false green we kill).
final class UIKeySpecTests: XCTestCase {

    // Known kVK_* virtual keycodes (HIToolbox/Events.h, ANSI US).
    private let kA: UInt16 = 0x00
    private let kC: UInt16 = 0x08
    private let kZ: UInt16 = 0x06
    private let kReturn: UInt16 = 0x24
    private let kLeft: UInt16 = 0x7B
    private let kRight: UInt16 = 0x7C
    private let kUp: UInt16 = 0x7E
    private let kDown: UInt16 = 0x7D
    private let kTab: UInt16 = 0x30
    private let kSpace: UInt16 = 0x31
    private let kDelete: UInt16 = 0x33
    private let k1: UInt16 = 0x12

    // MARK: - ui-type: literal text → one stroke per character

    func test_type_lowercaseLetter_noModifier() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "a"))
        XCTAssertEqual(s.strokes.count, 1)
        let stroke = s.strokes[0]
        XCTAssertEqual(stroke.keyCode, kA)
        XCTAssertEqual(stroke.modifiers, [])
        XCTAssertEqual(stroke.baseCharacter, "a")
    }

    /// '⇧A' — an uppercase letter must map to the UNSHIFTED key + `.shift`
    /// (a real keyboard presses ⇧ + the base key, not a distinct keycode).
    func test_type_uppercaseLetter_carriesShift_onBaseKeycode() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "A"))
        let stroke = s.strokes[0]
        XCTAssertEqual(stroke.keyCode, kA, "shifted letter shares the base key's code")
        XCTAssertEqual(stroke.modifiers, .shift)
        XCTAssertEqual(stroke.baseCharacter, "a")
    }

    func test_type_word_mapsEachCharInOrder() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "Cat"))
        XCTAssertEqual(s.strokes.count, 3)
        XCTAssertEqual(s.strokes[0].keyCode, kC)
        XCTAssertEqual(s.strokes[0].modifiers, .shift)   // 'C'
        XCTAssertEqual(s.strokes[1].keyCode, kA)
        XCTAssertEqual(s.strokes[1].modifiers, [])       // 'a'
        XCTAssertEqual(s.strokes[2].keyCode, 0x11)       // 't'
        XCTAssertEqual(s.strokes[2].baseCharacter, "t")
        XCTAssertEqual(s.strokes[2].modifiers, [])
    }

    func test_type_digitAndShiftedSymbol_shareKeycode() throws {
        let digit = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "1"))
        XCTAssertEqual(digit.strokes[0].keyCode, k1)
        XCTAssertEqual(digit.strokes[0].modifiers, [])

        let bang = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "!"))
        XCTAssertEqual(bang.strokes[0].keyCode, k1, "'!' is ⇧+1")
        XCTAssertEqual(bang.strokes[0].modifiers, .shift)
        XCTAssertEqual(bang.strokes[0].baseCharacter, "1")
    }

    func test_type_spaceAndPunctuation() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-type", arg: "a b"))
        XCTAssertEqual(s.strokes.count, 3)
        XCTAssertEqual(s.strokes[1].keyCode, kSpace)
        XCTAssertEqual(s.strokes[1].baseCharacter, " ")
    }

    func test_type_emptyArg_rejected() {
        XCTAssertNil(UIKeySpec.parse(verb: "ui-type", arg: ""))
    }

    func test_type_unmappableCharacter_rejected() {
        // A non-ANSI glyph has no virtual keycode in the host table → fail
        // loudly rather than post a garbage keystroke.
        XCTAssertNil(UIKeySpec.parse(verb: "ui-type", arg: "é"),
                     "an unmappable glyph must FAIL the parse")
    }

    // MARK: - ui-key: chord tokens

    func test_key_cmdC_copyChord() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+c"))
        XCTAssertEqual(s.strokes.count, 1)
        let stroke = s.strokes[0]
        XCTAssertEqual(stroke.keyCode, kC)
        XCTAssertEqual(stroke.modifiers, .command)
        XCTAssertEqual(stroke.baseCharacter, "c")
    }

    func test_key_multiModifierChord() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+shift+z"))
        let stroke = s.strokes[0]
        XCTAssertEqual(stroke.keyCode, kZ)
        XCTAssertEqual(stroke.modifiers, [.command, .shift])
    }

    func test_key_modifierAliases() throws {
        let a = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "command+c"))
        XCTAssertEqual(a.strokes[0].modifiers, .command)
        let b = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "ctrl+a"))
        XCTAssertEqual(b.strokes[0].modifiers, .control)
        let c = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "control+a"))
        XCTAssertEqual(c.strokes[0].modifiers, .control)
        let d = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "opt+a"))
        XCTAssertEqual(d.strokes[0].modifiers, .option)
        let e = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "alt+a"))
        XCTAssertEqual(e.strokes[0].modifiers, .option)
    }

    func test_key_arrowKeys_haveNilBaseCharacter() throws {
        let pairs: [(String, UInt16)] = [
            ("left", kLeft), ("right", kRight), ("up", kUp), ("down", kDown),
            ("arrow-left", kLeft),
        ]
        for (token, code) in pairs {
            let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: token))
            XCTAssertEqual(s.strokes[0].keyCode, code, "arrow '\(token)'")
            XCTAssertNil(s.strokes[0].baseCharacter,
                         "a navigation key has no inherent glyph: \(token)")
            XCTAssertEqual(s.strokes[0].modifiers, [])
        }
    }

    func test_key_namedKeysAndAliases() throws {
        XCTAssertEqual(try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "enter")).strokes[0].keyCode, kReturn)
        XCTAssertEqual(try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "return")).strokes[0].keyCode, kReturn)
        XCTAssertEqual(try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "tab")).strokes[0].keyCode, kTab)
        XCTAssertEqual(try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "space")).strokes[0].keyCode, kSpace)
        XCTAssertEqual(try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "backspace")).strokes[0].keyCode, kDelete)
        XCTAssertEqual(try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "delete")).strokes[0].keyCode, kDelete)
    }

    func test_key_modifiedArrow_carriesModifier() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "shift+left"))
        XCTAssertEqual(s.strokes[0].keyCode, kLeft)
        XCTAssertEqual(s.strokes[0].modifiers, .shift)
    }

    func test_key_multipleChordTokens_inOrder() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+a delete enter"))
        XCTAssertEqual(s.strokes.count, 3)
        XCTAssertEqual(s.strokes[0].modifiers, .command)
        XCTAssertEqual(s.strokes[1].keyCode, kDelete)
        XCTAssertEqual(s.strokes[2].keyCode, kReturn)
    }

    /// A bare-character key in a chord token keeps any implicit shift (a
    /// shifted symbol) AND merges explicit chord modifiers (`cmd+?` → ⌘⇧/).
    func test_key_shiftedSymbolInChord_mergesImplicitShift() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "cmd+?"))
        XCTAssertEqual(s.strokes[0].keyCode, 0x2C, "'?' is the '/' key")
        XCTAssertEqual(s.strokes[0].modifiers, [.command, .shift])
    }

    func test_key_barePlus_isThePlusKey() throws {
        let s = try XCTUnwrap(UIKeySpec.parse(verb: "ui-key", arg: "+"))
        XCTAssertEqual(s.strokes[0].keyCode, 0x18, "'+' is ⇧+=")
        XCTAssertEqual(s.strokes[0].modifiers, .shift)
    }

    // MARK: - Strict grammar: malformed forms must FAIL

    func test_invalidForms_rejected() {
        XCTAssertNil(UIKeySpec.parse(verb: "ui-key", arg: ""), "empty")
        XCTAssertNil(UIKeySpec.parse(verb: "ui-key", arg: "cmmd+c"), "typo'd modifier must FAIL")
        XCTAssertNil(UIKeySpec.parse(verb: "ui-key", arg: "cmd+"), "trailing '+' (empty key)")
        XCTAssertNil(UIKeySpec.parse(verb: "ui-key", arg: "cmd+notakey"), "unknown multi-char key")
        XCTAssertNil(UIKeySpec.parse(verb: "ui-key", arg: "cmd+ab"), "two-char non-named key")
        XCTAssertNil(UIKeySpec.parse(verb: "ui-press", arg: "a"), "unknown verb")
    }

    func test_equatable() throws {
        let a = UIKeySpec.parse(verb: "ui-key", arg: "cmd+c")
        let b = UIKeySpec.parse(verb: "ui-key", arg: "cmd+c")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, UIKeySpec.parse(verb: "ui-key", arg: "cmd+v"))
    }
}
