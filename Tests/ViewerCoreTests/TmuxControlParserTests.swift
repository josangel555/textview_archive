import XCTest
@testable import ViewerCore

/// Headless (Tier 1) coverage for the tmux control-mode (`tmux -CC`) protocol
/// parser. Feeds byte/line scripts and asserts the exact typed
/// `[ControlModeEvent]` sequence. The LIVE PTY/`tmux -CC` spawn path is NOT
/// exercised here (it forks a real binary — VM tier); this pins the pure
/// protocol/framing/octal-unescape logic, modelled on `ANSIParserTests`.
final class TmuxControlParserTests: XCTestCase {

    private func feed(_ p: inout TmuxControlParser, _ s: String) -> [ControlModeEvent] {
        p.feed(Array(s.utf8))
    }

    // MARK: - Octal unescape (the test-critical transform)

    func test_unescapeOctal_threeDigitEscape_decodesOneByte() {
        // \033 = 0x1B (ESC), \007 = 0x07 (BEL), \377 = 0xFF.
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\033".utf8)), [0x1B])
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\007".utf8)), [0x07])
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\377".utf8)), [0xFF])
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\000".utf8)), [0x00])
    }

    func test_unescapeOctal_doubleBackslash_decodesOneBackslash() {
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\\\".utf8)), [0x5C])
        // a\\b → a\b
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("a\\\\b".utf8)),
                       [0x61, 0x5C, 0x62])
    }

    func test_unescapeOctal_literalBytesPassThrough() {
        let s = "hello world"
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array(s.utf8)), Array(s.utf8))
    }

    func test_unescapeOctal_mixedPayload_roundTrips() {
        // A payload mixing literal text, an ESC sequence, a BEL, 0xFF, a
        // backslash and embedded UTF-8 — exactly what a real pane emits.
        // raw bytes: "ok" ESC "[m" BEL 0xFF '\' "é"(0xC3 0xA9)
        let raw: [UInt8] = [0x6F, 0x6B,            // "ok"
                            0x1B, 0x5B, 0x6D,      // ESC [ m
                            0x07,                  // BEL
                            0xFF,                  // 0xFF
                            0x5C,                  // backslash
                            0xC3, 0xA9]            // "é"
        // tmux escapes: control + non-printable + backslash become \NNN / \\,
        // printable ASCII stays literal, high bytes (>=0x80) become \NNN too.
        let escaped = "ok\\033[m\\007\\377\\\\\\303\\251"
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array(escaped.utf8)), raw)
    }

    func test_unescapeOctal_malformedEscape_emitsBackslashLiterally() {
        // trailing lone backslash → literal '\'
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("a\\".utf8)),
                       [0x61, 0x5C])
        // \12 (only two octal digits before end) → '\' '1' '2'
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\12".utf8)),
                       [0x5C, 0x31, 0x32])
        // \089 — '8'/'9' are NOT octal digits → '\' '0' '8' '9'
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\089".utf8)),
                       [0x5C, 0x30, 0x38, 0x39])
    }

    // MARK: - Reply framing

    func test_replyFrame_beginEndCorrelateByCommandNumber() {
        var p = TmuxControlParser()
        let script = """
        %begin 1700000000 7 1
        window 0
        window 1
        %end 1700000000 7 1

        """
        let events = feed(&p, script)
        XCTAssertEqual(events, [
            .beginReply(cmdNum: 7),
            .replyLine("window 0"),
            .replyLine("window 1"),
            .endReply(cmdNum: 7),
        ])
    }

    func test_replyFrame_errorFramesAFailure() {
        var p = TmuxControlParser()
        let events = feed(&p, """
        %begin 1700000000 3 1
        no such session: bogus
        %error 1700000000 3 1

        """)
        XCTAssertEqual(events, [
            .beginReply(cmdNum: 3),
            .replyLine("no such session: bogus"),
            .errorReply(cmdNum: 3),
        ])
    }

    func test_replyFrame_percentPrefixedLineInsideFrameIsReplyLine_notNotification() {
        // list-keys output can begin with '%'; inside a frame it's literal.
        var p = TmuxControlParser()
        let events = feed(&p, """
        %begin 1 9 1
        %some-keybinding-row
        %end 1 9 1

        """)
        XCTAssertEqual(events, [
            .beginReply(cmdNum: 9),
            .replyLine("%some-keybinding-row"),
            .endReply(cmdNum: 9),
        ])
    }

    // MARK: - Notifications

    func test_output_unescapesPayloadAndStripsPaneSigil() {
        var p = TmuxControlParser()
        // %output %2 "ok" ESC "[31m"  (red SGR)
        let events = feed(&p, "%output %2 ok\\033[31m\n")
        XCTAssertEqual(events, [
            .output(paneId: 2, bytes: [0x6F, 0x6B, 0x1B, 0x5B, 0x33, 0x31, 0x6D]),
        ])
    }

    func test_output_emptyPayload() {
        var p = TmuxControlParser()
        let events = feed(&p, "%output %5 \n")
        XCTAssertEqual(events, [.output(paneId: 5, bytes: [])])
    }

    func test_windowLifecycle_addCloseRename() {
        var p = TmuxControlParser()
        let events = feed(&p, """
        %window-add @3
        %window-renamed @3 my shell
        %window-close @3

        """)
        XCTAssertEqual(events, [
            .windowAdd(3),
            .windowRenamed(3, "my shell"),     // multi-word name preserved
            .windowClose(3),
        ])
    }

    func test_layoutChange_keepsWindowAndLayoutString() {
        var p = TmuxControlParser()
        let layout = "bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2}"
        let events = feed(&p, "%layout-change @1 \(layout)\n")
        XCTAssertEqual(events, [.layoutChange(window: 1, layout: layout)])
    }

    func test_sessionAndPaneNotifications() {
        var p = TmuxControlParser()
        let events = feed(&p, """
        %session-changed $1 main
        %client-session-changed /dev/ttys001 $1 main
        %sessions-changed
        %pane-mode-changed %4
        %window-pane-changed @1 %4
        %exit detached

        """)
        XCTAssertEqual(events, [
            .sessionChanged(1, "main"),
            .clientSessionChanged,
            .sessionsChanged,
            .paneModeChanged(4),
            .windowPaneChanged(window: 1, pane: 4),
            .exit(reason: "detached"),
        ])
    }

    func test_exit_withoutReason() {
        var p = TmuxControlParser()
        XCTAssertEqual(feed(&p, "%exit\n"), [.exit(reason: nil)])
    }

    func test_unknownNotification_neverDesyncs() {
        var p = TmuxControlParser()
        let events = feed(&p, """
        %subscription-changed foo 1 2
        %window-add @9

        """)
        XCTAssertEqual(events, [
            .unknown(name: "subscription-changed", args: ["foo", "1", "2"]),
            .windowAdd(9),                     // stream still in sync after unknown
        ])
    }

    func test_nonPercentLineOutsideFrameIsIgnored() {
        var p = TmuxControlParser()
        XCTAssertEqual(feed(&p, "garbage not a control line\n"), [])
    }

    // MARK: - Interleaved script + chunk-boundary invariance

    /// The design's canonical mixed script: a reply frame, then interleaved
    /// %output / %window-add / %layout-change notifications.
    private static let mixedScript = """
    %begin 100 1 0
    @1: 3 windows
    %end 100 1 0
    %output %1 hello\\040world\\033[m
    %window-add @2
    %layout-change @2 abcd,80x24,0,0,2
    %output %2 done\\012

    """

    private static let expectedMixed: [ControlModeEvent] = [
        .beginReply(cmdNum: 1),
        .replyLine("@1: 3 windows"),
        .endReply(cmdNum: 1),
        // "hello world" ESC "[m"  (\040 = space, \033 = ESC)
        .output(paneId: 1, bytes: Array("hello world".utf8) + [0x1B, 0x5B, 0x6D]),
        .windowAdd(2),
        .layoutChange(window: 2, layout: "abcd,80x24,0,0,2"),
        // "done\n"  (\012 = LF inside the escaped payload — must NOT split the line)
        .output(paneId: 2, bytes: Array("done".utf8) + [0x0A]),
    ]

    func test_mixedScript_exactEventSequence() {
        var p = TmuxControlParser()
        let events = feed(&p, Self.mixedScript)
        XCTAssertEqual(events, Self.expectedMixed)
    }

    func test_mixedScript_splitAcrossEveryByteBoundary_identicalOutput() {
        // Feed the SAME script one byte at a time; the buffered partial-line
        // logic must produce the identical event sequence (no corruption,
        // no extra/dropped events). This is the chunk-boundary invariant.
        var p = TmuxControlParser()
        var events: [ControlModeEvent] = []
        for byte in Array(Self.mixedScript.utf8) {
            events.append(contentsOf: p.feed([byte]))
        }
        XCTAssertEqual(events, Self.expectedMixed)
    }

    func test_mixedScript_splitAtSeveralArbitraryOffsets_identicalOutput() {
        let bytes = Array(Self.mixedScript.utf8)
        // Try a spread of split points (including ones that land mid-escape
        // and mid-token) — all must yield the canonical sequence.
        for split in [1, 7, 23, 50, 80, 120, bytes.count - 1] where split < bytes.count {
            var p = TmuxControlParser()
            var events: [ControlModeEvent] = []
            events.append(contentsOf: p.feed(Array(bytes[0..<split])))
            events.append(contentsOf: p.feed(Array(bytes[split...])))
            XCTAssertEqual(events, Self.expectedMixed, "split at \(split) corrupted the stream")
        }
    }

    func test_partialTrailingLine_isBufferedUntilNewline() {
        var p = TmuxControlParser()
        // No newline yet → no event.
        XCTAssertEqual(feed(&p, "%window-add @"), [])
        XCTAssertEqual(feed(&p, "7"), [])
        // Newline completes it.
        XCTAssertEqual(feed(&p, "\n"), [.windowAdd(7)])
    }

    func test_crlfLineEnding_stripsCarriageReturn() {
        var p = TmuxControlParser()
        // tmux pairs CR/LF; the CR must not leak into a reply line.
        XCTAssertEqual(feed(&p, "%window-add @4\r\n"), [.windowAdd(4)])
    }
}
