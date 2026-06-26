import XCTest
@testable import ViewerCore

/// Hardening coverage for the tmux control-mode (`tmux -CC`) INBOUND codec
/// (`TmuxControlParser`), targeting the highest-severity gaps that the happy-
/// path suite (`TmuxControlParserTests`) leaves uncovered. These pin the wire
/// forms a REAL tmux emits under flow control / renames / raw high-byte output
/// — the exact mechanisms slice-d (live PTY pump + backpressure) will exercise.
///
/// Each test demonstrates TEETH where a fix landed: the asserted decode is the
/// CORRECT typed event, and (for the `%extended-output` fix) the test also pins
/// that it does NOT fall through to `.unknown`, so a regression to the old
/// drop-the-payload behaviour fails here.
final class TmuxControlParserHardeningTests: XCTestCase {

    private func feed(_ p: inout TmuxControlParser, _ s: String) -> [ControlModeEvent] {
        p.feed(Array(s.utf8))
    }

    // MARK: - HIGH: %extended-output (flow-controlled pane output)

    /// Real tmux emits `%extended-output %<pane> <age-ms> : <escaped-data>` (NOT
    /// `%output`) for every pane once a control client enables flow control.
    /// It MUST decode to the same `.output(paneId:bytes:)` as `%output`, with
    /// the age field discarded and the payload octal-unescaped — otherwise the
    /// pane goes blank/frozen on screen.
    func test_extendedOutput_decodesLikeOutput_ageDiscarded() {
        var p = TmuxControlParser()
        // "hi" then ESC "[m"  (\033 = ESC). Age = 12ms (discarded).
        let events = feed(&p, "%extended-output %3 12 : hi\\033[m\n")
        XCTAssertEqual(events, [
            .output(paneId: 3, bytes: Array("hi".utf8) + [0x1B, 0x5B, 0x6D]),
        ])
    }

    /// TEETH: the old code had no `case "extended-output"`, so it fell through
    /// to `.unknown(name:"extended-output", …)` and the payload was space-
    /// tokenised + never unescaped. Assert explicitly that it is NOT `.unknown`.
    func test_extendedOutput_doesNotFallThroughToUnknown() {
        var p = TmuxControlParser()
        let events = feed(&p, "%extended-output %3 152 : ok\\033[m\n")
        XCTAssertEqual(events.count, 1)
        guard case let .output(paneId, bytes) = events[0] else {
            return XCTFail("expected .output, got \(events[0])")
        }
        XCTAssertEqual(paneId, 3)
        XCTAssertEqual(bytes, Array("ok".utf8) + [0x1B, 0x5B, 0x6D])
    }

    func test_extendedOutput_emptyPayload() {
        var p = TmuxControlParser()
        // "%extended-output %5 0 :" with no trailing data → empty output.
        XCTAssertEqual(feed(&p, "%extended-output %5 0 :\n"),
                       [.output(paneId: 5, bytes: [])])
        // ...and the "...: " (colon + a space, then nothing) form is also empty.
        XCTAssertEqual(feed(&p, "%extended-output %6 0 : \n"),
                       [.output(paneId: 6, bytes: [])])
    }

    /// Binary payloads (raw high bytes + a real `\012` LF byte inside the
    /// escaped payload) survive the extended-output path exactly as for
    /// `%output` — the LF must NOT split the control line. Built as raw bytes
    /// (NOT via a String literal) so 0xC3/0xA9 land as single bytes, the actual
    /// tmux wire form.
    func test_extendedOutput_binaryPayload_survivesAndDoesNotSplitLine() {
        var p = TmuxControlParser()
        var bytes = Array("%extended-output %2 9 : ".utf8)
        bytes += [0xC3, 0xA9, 0x7F]              // raw é (0xC3 0xA9) + raw DEL
        bytes += Array("\\012".utf8)             // escaped LF byte (\012 = 0x0A)
        bytes += [0x0A]                          // LF terminates the control line
        let events = p.feed(bytes)
        XCTAssertEqual(events, [
            .output(paneId: 2, bytes: [0xC3, 0xA9, 0x7F, 0x0A]),
        ])
    }

    /// A malformed extended-output (missing the `:` separator) must NOT silently
    /// mis-demux as pane output — it degrades to a typed `.unknown` and the
    /// stream stays in sync for the next line.
    func test_extendedOutput_malformedFraming_typedUnknown_streamStaysInSync() {
        var p = TmuxControlParser()
        let events = feed(&p, "%extended-output %3 12 nope-no-colon\n%window-add @8\n")
        XCTAssertEqual(events.count, 2)
        if case .output = events[0] {
            XCTFail("malformed extended-output must not decode as .output")
        }
        XCTAssertEqual(events[1], .windowAdd(8))   // stream not desynced
    }

    // MARK: - MEDIUM: raw high bytes / 0x7F pass through (real wire form)

    /// Real tmux escapes ONLY bytes < 0x20 and `\` (as `\134`). Bytes 0x20–0xFF
    /// — including 0x7F (DEL) and all UTF-8 lead/continuation bytes ≥0x80 — are
    /// sent LITERALLY. The happy-path suite pre-escapes high bytes (a wire form
    /// tmux never produces), so this is the only guard that passthrough of raw
    /// ≥0x80 bytes survives `%output` end-to-end.
    func test_output_rawHighBytesAndDel_passThroughUnchanged() {
        var p = TmuxControlParser()
        // "%output %1 " then raw 0xC3 0xA9 0x7F then \134 (= backslash) then LF.
        var bytes = Array("%output %1 ".utf8)
        bytes += [0xC3, 0xA9, 0x7F]              // é (raw) + DEL (raw)
        bytes += Array("\\134".utf8)             // canonical escaped backslash
        bytes += [0x0A]                          // LF terminates the line
        let events = p.feed(bytes)
        XCTAssertEqual(events, [
            .output(paneId: 1, bytes: [0xC3, 0xA9, 0x7F, 0x5C]),
        ])
    }

    /// `\134` is the CANONICAL escaped-backslash form a real tmux emits (octal
    /// 134 = 0x5C). Distinct from the synthetic `\\` (double-backslash) the
    /// happy-path suite tests; pin it independently so a regression that handled
    /// only `\\` would be caught.
    func test_unescapeOctal_canonicalBackslashEscape_134() {
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("\\134".utf8)), [0x5C])
        // mixed: a\134b → a\b
        XCTAssertEqual(TmuxControlParser.unescapeOctal(Array("a\\134b".utf8)),
                       [0x61, 0x5C, 0x62])
    }

    // MARK: - MEDIUM: %window-renamed name fidelity

    /// A window name with internal runs of spaces must be preserved EXACTLY —
    /// the name is the remainder-of-line after the window-id token, not a set of
    /// space-collapsed tokens. The old `split + joined(separator:" ")` collapsed
    /// `a  b` (two spaces) to `a b`.
    func test_windowRenamed_preservesInternalSpaces() {
        var p = TmuxControlParser()
        XCTAssertEqual(feed(&p, "%window-renamed @3 a  b\n"),
                       [.windowRenamed(3, "a  b")])
    }

    /// A rename to an EMPTY name (the title was cleared) must apply as an empty
    /// string, not fall through to `.unknown` (which left the stale tab title).
    func test_windowRenamed_toEmptyName_applies() {
        var p = TmuxControlParser()
        // trailing space then newline: "%window-renamed @3 \n"
        let withSpace = feed(&p, "%window-renamed @3 \n")
        XCTAssertEqual(withSpace, [.windowRenamed(3, "")])

        // no trailing space: "%window-renamed @3\n"
        var p2 = TmuxControlParser()
        let noSpace = feed(&p2, "%window-renamed @3\n")
        XCTAssertEqual(noSpace, [.windowRenamed(3, "")])
    }

    /// Same fidelity for %session-changed names (id token + remainder-of-line).
    func test_sessionChanged_preservesInternalSpaces() {
        var p = TmuxControlParser()
        XCTAssertEqual(feed(&p, "%session-changed $1 my  session\n"),
                       [.sessionChanged(1, "my  session")])
    }

    // MARK: - LOW: %output unparseable pane token doesn't crash, stays in sync

    /// An `%output` whose pane token is genuinely unparseable (no digits at all,
    /// e.g. `xx`) must not crash and must keep the stream in sync — pinning the
    /// "never desync" contract for the output path, not just notifications. It
    /// degrades to a typed `.unknown` carrying the bad token rather than trapping.
    func test_output_unparseablePaneToken_doesNotCrash_streamStaysInSync() {
        var p = TmuxControlParser()
        let events = feed(&p, "%output xx payloadhere\n%window-add @2\n")
        XCTAssertEqual(events.count, 2)
        // First line must NOT be a successful pane-output decode (bad token).
        if case .output = events[0] {
            XCTFail("unparseable pane token must not decode as .output")
        }
        XCTAssertEqual(events[1], .windowAdd(2))   // next line still parses
    }

    /// A pane id WITHOUT a sigil (`%output 3 data`) is a legitimate lenient
    /// case `sigilInt` accepts (bare digits) — it decodes to that pane. Pinned
    /// so the lenient acceptance is intentional, not accidental.
    func test_output_bareDigitPaneToken_decodesToPane() {
        var p = TmuxControlParser()
        XCTAssertEqual(feed(&p, "%output 3 hi\n"),
                       [.output(paneId: 3, bytes: Array("hi".utf8))])
    }
}
