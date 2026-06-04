import XCTest
@testable import ViewerCore

/// Headless coverage for the pure key→bytes mapping the terminal view
/// uses to translate keystrokes into PTY input.
final class TerminalKeyEncoderTests: XCTestCase {

    func test_specialKeys_emitExpectedBytes() {
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .enter), [0x0D])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .backspace), [0x7F])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .tab), [0x09])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .escape), [0x1B])
    }

    func test_arrows_emitCSICursorForms() {
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .up),    [0x1B, 0x5B, 0x41]) // ESC[A
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .down),  [0x1B, 0x5B, 0x42]) // ESC[B
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .right), [0x1B, 0x5B, 0x43]) // ESC[C
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .left),  [0x1B, 0x5B, 0x44]) // ESC[D
    }

    func test_homeEnd_pageKeys_deleteForward() {
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .home), [0x1B, 0x5B, 0x48])      // ESC[H
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .end),  [0x1B, 0x5B, 0x46])      // ESC[F
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .pageUp), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .pageDown), [0x1B, 0x5B, 0x36, 0x7E])
        XCTAssertEqual(TerminalKeyEncoder.bytes(for: .deleteForward), [0x1B, 0x5B, 0x33, 0x7E])
    }

    func test_plainText_returnsUTF8() {
        XCTAssertEqual(
            TerminalKeyEncoder.bytes(forText: "ls", control: false, option: false),
            [0x6C, 0x73]
        )
    }

    func test_controlChords_mapToC0() {
        // Ctrl-C → 0x03 (ETX / SIGINT).
        XCTAssertEqual(TerminalKeyEncoder.bytes(forText: "c", control: true, option: false), [0x03])
        // Case-insensitive: Ctrl-C with shift still 0x03.
        XCTAssertEqual(TerminalKeyEncoder.bytes(forText: "C", control: true, option: false), [0x03])
        // Ctrl-D → 0x04 (EOF).
        XCTAssertEqual(TerminalKeyEncoder.bytes(forText: "d", control: true, option: false), [0x04])
        // Ctrl-Z → 0x1A (SIGTSTP).
        XCTAssertEqual(TerminalKeyEncoder.bytes(forText: "z", control: true, option: false), [0x1A])
        // Ctrl-A → 0x01, Ctrl-L → 0x0C.
        XCTAssertEqual(TerminalKeyEncoder.bytes(forText: "a", control: true, option: false), [0x01])
        XCTAssertEqual(TerminalKeyEncoder.bytes(forText: "l", control: true, option: false), [0x0C])
    }

    func test_controlSymbolChords() {
        XCTAssertEqual(TerminalKeyEncoder.controlCode(for: "["), 0x1B)  // Ctrl-[ → ESC
        XCTAssertEqual(TerminalKeyEncoder.controlCode(for: "\\"), 0x1C)
        XCTAssertEqual(TerminalKeyEncoder.controlCode(for: "@"), 0x00)
    }

    func test_optionPrefixesWithEscape() {
        // Alt-b → ESC b (word-back in readline).
        XCTAssertEqual(
            TerminalKeyEncoder.bytes(forText: "b", control: false, option: true),
            [0x1B, 0x62]
        )
    }

    func test_unknownControlChord_emitsNothing() {
        // Ctrl-5 has no standard mapping → empty (no stray byte).
        XCTAssertEqual(
            TerminalKeyEncoder.bytes(forText: "5", control: true, option: false),
            []
        )
    }
}
