import Testing
import Foundation
@testable import ViewerCore

/// Host tests for the typed OUTBOUND tmux serializer (`TmuxCommand`). Pure
/// logic — Swift Testing per CLAUDE.md. Pins each command's exact rendered
/// string, its `@window` vs `%pane` targeting, the send-keys / argument
/// escaping edge cases (spaces, quotes, control bytes), and the
/// `encodeCommand` round-trip (typed → string → framed `Data` + FIFO number).
@Suite("TmuxCommand serializer")
struct TmuxCommandTests {

    // Convenience id factories.
    private func pane(_ n: Int) -> TmuxPaneID { TmuxPaneID(n) }
    private func window(_ n: Int) -> TmuxWindowID { TmuxWindowID(n) }

    // MARK: - Sigil discipline (the transpose footgun)

    @Test("window ids sigil with @, pane ids with %")
    func idSigils() {
        #expect(window(3).description == "@3")
        #expect(window(3).target == "@3")
        #expect(pane(5).description == "%5")
        // Same numeric value must NOT collide across the two id spaces.
        #expect(window(7).description != pane(7).description)
    }

    // MARK: - new-window

    @Test("new-window default: detached + id capture, no -t")
    func newWindowDefault() {
        let s = TmuxCommand.newWindow().controlModeString
        #expect(s == "new-window -d -P -F '#{window_id}'")
        // window-granularity: must NOT target a %pane.
        #expect(!s.contains("%"))
        #expect(!s.contains("-t"))
    }

    @Test("new-window non-detached omits -d (switches client)")
    func newWindowAttached() {
        let s = TmuxCommand.newWindow(detached: false).controlModeString
        #expect(s == "new-window -P -F '#{window_id}'")
    }

    @Test("new-window with name + cwd single-quotes both")
    func newWindowNamedCwd() {
        let s = TmuxCommand.newWindow(name: "my logs", workingDirectory: "/tmp/a b", detached: true).controlModeString
        #expect(s == "new-window -d -n 'my logs' -c '/tmp/a b' -P -F '#{window_id}'")
    }

    @Test("new-window name with tmux specials stays a single quoted arg")
    func newWindowSpecialChars() {
        // `;` (separator), `#` (comment), `$VAR` (expansion) all must be inert.
        let s = TmuxCommand.newWindow(name: "a; rm -rf # $HOME").controlModeString
        #expect(s == "new-window -d -n 'a; rm -rf # $HOME' -P -F '#{window_id}'")
    }

    // MARK: - kill-window / rename-window / select-window (window targeting)

    @Test("kill-window targets @window")
    func killWindow() {
        #expect(TmuxCommand.killWindow(window: window(2)).controlModeString == "kill-window -t @2")
    }

    @Test("select-window targets @window, never %pane")
    func selectWindow() {
        let s = TmuxCommand.selectWindow(window: window(4)).controlModeString
        #expect(s == "select-window -t @4")
        #expect(!s.contains("%"))
    }

    @Test("rename-window: -t @window then quoted positional name")
    func renameWindow() {
        #expect(TmuxCommand.renameWindow(window: window(1), name: "build").controlModeString
                == "rename-window -t @1 'build'")
    }

    @Test("rename-window with spaces and a semicolon stays one quoted arg")
    func renameWindowSpecials() {
        #expect(TmuxCommand.renameWindow(window: window(1), name: "step 1; step 2").controlModeString
                == "rename-window -t @1 'step 1; step 2'")
    }

    @Test("rename-window with an embedded single quote uses '\\'' break-out")
    func renameWindowEmbeddedQuote() {
        let s = TmuxCommand.renameWindow(window: window(0), name: "Jos's tab").controlModeString
        #expect(s == "rename-window -t @0 'Jos'\\''s tab'")
    }

    // MARK: - split-window (pane targeting + flags)

    @Test("split horizontal: -h, pane target, id capture")
    func splitHorizontal() {
        let s = TmuxCommand.splitWindow(pane: pane(3), axis: .horizontal).controlModeString
        #expect(s == "split-window -h -t %3 -P -F '#{pane_id}'")
        // pane-granularity: never an @window for split.
        #expect(!s.contains("@"))
    }

    @Test("split vertical: -v default axis form")
    func splitVertical() {
        #expect(TmuxCommand.splitWindow(pane: pane(0), axis: .vertical).controlModeString
                == "split-window -v -t %0 -P -F '#{pane_id}'")
    }

    @Test("split with percentage size and -b before flag")
    func splitSizedBefore() {
        let s = TmuxCommand.splitWindow(pane: pane(1), axis: .horizontal,
                                        size: .percent(50), before: true).controlModeString
        #expect(s == "split-window -h -b -l 50% -t %1 -P -F '#{pane_id}'")
    }

    @Test("split with absolute cells + full + cwd")
    func splitCellsFullCwd() {
        let s = TmuxCommand.splitWindow(pane: pane(2), axis: .vertical,
                                        size: .cells(20), before: false, full: true,
                                        workingDirectory: "/var/log").controlModeString
        #expect(s == "split-window -v -f -l 20 -c '/var/log' -t %2 -P -F '#{pane_id}'")
    }

    // MARK: - select-pane

    @Test("select-pane targets %pane")
    func selectPane() {
        #expect(TmuxCommand.selectPane(pane: pane(6)).controlModeString == "select-pane -t %6")
    }

    @Test("select-pane directional flags", arguments: [
        (TmuxDirection.left, "-L"), (.right, "-R"), (.up, "-U"), (.down, "-D"),
    ])
    func selectPaneDirectional(dir: TmuxDirection, flag: String) {
        #expect(TmuxCommand.selectPane(pane: pane(6), direction: dir).controlModeString
                == "select-pane \(flag) -t %6")
    }

    // MARK: - resize-pane

    @Test("resize-pane absolute -x -y with cells")
    func resizeAbsolute() {
        let s = TmuxCommand.resizePane(pane: pane(4),
                                       mode: .absolute(cols: .cells(80), rows: .cells(24))).controlModeString
        #expect(s == "resize-pane -t %4 -x 80 -y 24")
    }

    @Test("resize-pane absolute with percentages")
    func resizeAbsolutePercent() {
        let s = TmuxCommand.resizePane(pane: pane(4),
                                       mode: .absolute(cols: .percent(40), rows: .percent(30))).controlModeString
        #expect(s == "resize-pane -t %4 -x 40% -y 30%")
    }

    @Test("resize-pane relative nudge")
    func resizeRelative() {
        let s = TmuxCommand.resizePane(pane: pane(4),
                                       mode: .relative(direction: .left, amount: 5)).controlModeString
        #expect(s == "resize-pane -t %4 -L 5")
    }

    @Test("resize-pane zoom toggle prepends -Z")
    func resizeZoom() {
        let s = TmuxCommand.resizePane(pane: pane(4),
                                       mode: .absolute(cols: .cells(80), rows: .cells(24)),
                                       zoom: true).controlModeString
        #expect(s == "resize-pane -Z -t %4 -x 80 -y 24")
    }

    // MARK: - kill-pane

    @Test("kill-pane targets %pane")
    func killPane() {
        #expect(TmuxCommand.killPane(pane: pane(9)).controlModeString == "kill-pane -t %9")
    }

    // MARK: - send-keys (the only non-trivial escaping path)

    @Test("send-keys -H: arbitrary control bytes as two-hex tokens")
    func sendKeysHex() {
        // ESC [ A = Up arrow.
        let s = TmuxCommand.sendKeys(pane: pane(5), keys: .hexBytes([0x1b, 0x5b, 0x41])).controlModeString
        #expect(s == "send-keys -H -t %5 1b 5b 41")
    }

    @Test("send-keys -H: Ctrl-C single byte")
    func sendKeysCtrlC() {
        #expect(TmuxCommand.sendKeys(pane: pane(5), keys: .hexBytes([0x03])).controlModeString
                == "send-keys -H -t %5 03")
    }

    @Test("send-keys -H: bytes that look like flags/separators are still inert hex")
    func sendKeysHexDangerousBytes() {
        // 0x2d '-', 0x3b ';', 0x23 '#', 0x27 '\'' — as hex none can be misparsed.
        let bytes: [UInt8] = [0x2d, 0x3b, 0x23, 0x27, 0x0d]
        let s = TmuxCommand.sendKeys(pane: pane(2), keys: .hexBytes(bytes)).controlModeString
        #expect(s == "send-keys -H -t %2 2d 3b 23 27 0d")
    }

    @Test("send-keys -H: high byte zero-pads to two digits")
    func sendKeysHexZeroPad() {
        #expect(TmuxCommand.sendKeys(pane: pane(0), keys: .hexBytes([0x00, 0x0a, 0xff])).controlModeString
                == "send-keys -H -t %0 00 0a ff")
    }

    @Test("send-keys -l: literal text single-quoted")
    func sendKeysLiteral() {
        #expect(TmuxCommand.sendKeys(pane: pane(1), keys: .literal("ls -la")).controlModeString
                == "send-keys -l -t %1 'ls -la'")
    }

    @Test("send-keys -l: literal text with a semicolon stays quoted (no separator)")
    func sendKeysLiteralSemicolon() {
        #expect(TmuxCommand.sendKeys(pane: pane(1), keys: .literal("echo a; echo b")).controlModeString
                == "send-keys -l -t %1 'echo a; echo b'")
    }

    @Test("send-keys -l: literal text with an embedded quote breaks out")
    func sendKeysLiteralQuote() {
        #expect(TmuxCommand.sendKeys(pane: pane(1), keys: .literal("can't")).controlModeString
                == "send-keys -l -t %1 'can'\\''t'")
    }

    @Test("send-keys named: key names emitted verbatim, no -l/-H")
    func sendKeysNamed() {
        #expect(TmuxCommand.sendKeys(pane: pane(1), keys: .named(["C-c"])).controlModeString
                == "send-keys -t %1 C-c")
        #expect(TmuxCommand.sendKeys(pane: pane(1), keys: .named(["Enter"])).controlModeString
                == "send-keys -t %1 Enter")
    }

    @Test("send-keys always targets %pane, never @window")
    func sendKeysPaneOnly() {
        let s = TmuxCommand.sendKeys(pane: pane(7), keys: .hexBytes([0x41])).controlModeString
        #expect(!s.contains("@"))
        #expect(s.contains("%7"))
    }

    // MARK: - paste-buffer

    @Test("paste-buffer default targets %pane")
    func pasteBufferDefault() {
        #expect(TmuxCommand.pasteBuffer(pane: pane(3)).controlModeString == "paste-buffer -t %3")
    }

    @Test("paste-buffer named buffer + bracketed")
    func pasteBufferNamed() {
        #expect(TmuxCommand.pasteBuffer(pane: pane(3), buffer: "buf0", bracketed: true).controlModeString
                == "paste-buffer -p -b 'buf0' -t %3")
    }

    // MARK: - refresh-client (geometry, no -t target)

    @Test("refresh-client whole client WxH")
    func refreshClient() {
        #expect(TmuxCommand.refreshClient(size: .client(cols: 178, rows: 40)).controlModeString
                == "refresh-client -C 178x40")
    }

    @Test("refresh-client per-window @id:WxH")
    func refreshClientWindow() {
        #expect(TmuxCommand.refreshClient(size: .window(window(0), cols: 80, rows: 24)).controlModeString
                == "refresh-client -C @0:80x24")
    }

    // MARK: - detach

    @Test("detach-client")
    func detach() {
        #expect(TmuxCommand.detachClient.controlModeString == "detach-client")
    }

    // MARK: - topology discovery (format-string # is NOT a comment)

    @Test("list-windows format string is single-quoted intact")
    func listWindows() {
        #expect(TmuxCommand.listWindows().controlModeString
                == "list-windows -F '#{window_id} #{window_name} #{window_active} #{window_layout}'")
    }

    @Test("list-windows targeted at a window")
    func listWindowsTargeted() {
        #expect(TmuxCommand.listWindows(window: window(2)).controlModeString
                == "list-windows -t @2 -F '#{window_id} #{window_name} #{window_active} #{window_layout}'")
    }

    @Test("list-panes -s session-wide")
    func listPanes() {
        #expect(TmuxCommand.listPanesInSession.controlModeString
                == "list-panes -s -F '#{window_id} #{pane_id} #{pane_active} #{pane_width}x#{pane_height}'")
    }

    @Test("display-message -p for one window's visible layout")
    func displayLayout() {
        #expect(TmuxCommand.displayLayout(window: window(0)).controlModeString
                == "display-message -p -t @0 '#{window_visible_layout}'")
    }

    @Test("list-sessions")
    func listSessions() {
        #expect(TmuxCommand.listSessions.controlModeString
                == "list-sessions -F '#{session_id} #{session_name}'")
    }

    // MARK: - quote() helper edge cases

    @Test("quote wraps plain text")
    func quotePlain() {
        #expect(TmuxCommand.quote("hello") == "'hello'")
    }

    @Test("quote breaks out every embedded single quote")
    func quoteMultiQuote() {
        #expect(TmuxCommand.quote("a'b'c") == "'a'\\''b'\\''c'")
    }

    @Test("quote of empty string is a quoted empty arg")
    func quoteEmpty() {
        #expect(TmuxCommand.quote("") == "''")
    }

    // MARK: - encodeCommand round-trip (the integration seam)

    @Test("rendered command feeds encodeCommand with trailing newline")
    func encodeRoundTrip() {
        var core = TmuxControllerCore()
        let cmd = TmuxCommand.killPane(pane: pane(2))
        let data = core.encodeCommand(cmd.controlModeString)
        #expect(data == Data("kill-pane -t %2\n".utf8))
        // No trailing newline / no leading % in the serializer output itself —
        // framing is owned by encodeCommand.
        #expect(!cmd.controlModeString.hasSuffix("\n"))
        #expect(!cmd.controlModeString.hasPrefix("%"))
    }

    @Test("typed send() convenience renders + frames + enqueues a FIFO number")
    func typedSend() {
        var core = TmuxControllerCore()
        let data = core.send(.newWindow(detached: true))
        #expect(data == Data("new-window -d -P -F '#{window_id}'\n".utf8))
        // First command on the client → number 0; one entry now in flight.
        #expect(core.commandQueue.inFlightCount == 1)
        #expect(core.commandQueue.nextCommandNumber == 1)
    }

    @Test("FIFO assigns monotonic numbers across typed sends and correlates the reply")
    func fifoCorrelation() {
        var core = TmuxControllerCore()
        core.send(.newWindow())                                  // number 0
        core.send(.splitWindow(pane: pane(0), axis: .horizontal)) // number 1
        #expect(core.commandQueue.nextCommandNumber == 2)
        #expect(core.commandQueue.inFlightCount == 2)

        // tmux replies to command 0 (a window-id line, then %end 0).
        let fx = core.ingest([
            .beginReply(cmdNum: 0),
            .replyLine("@3"),
            .endReply(cmdNum: 0),
        ])
        #expect(fx.replies.count == 1)
        #expect(fx.replies.first?.command == "new-window -d -P -F '#{window_id}'")
        #expect(fx.replies.first?.lines == ["@3"])
        #expect(fx.replies.first?.succeeded == true)
        // command 1 is still in flight.
        #expect(core.commandQueue.inFlightCount == 1)
    }

    // MARK: - Teeth: targeting must not transpose pane <-> window sigil

    @Test("teeth: every pane-scoped command renders % and never @")
    func teethPaneScoped() {
        let paneScoped: [TmuxCommand] = [
            .splitWindow(pane: pane(1), axis: .horizontal),
            .selectPane(pane: pane(1)),
            .resizePane(pane: pane(1), mode: .relative(direction: .up, amount: 1)),
            .killPane(pane: pane(1)),
            .sendKeys(pane: pane(1), keys: .hexBytes([0x41])),
            .pasteBuffer(pane: pane(1)),
        ]
        for c in paneScoped {
            let s = c.controlModeString
            #expect(s.contains("%1"), "expected %1 in \(s)")
            #expect(!s.contains("@"), "pane-scoped command leaked @: \(s)")
        }
    }

    @Test("teeth: every window-scoped command renders @ and never targets %")
    func teethWindowScoped() {
        let windowScoped: [TmuxCommand] = [
            .killWindow(window: window(1)),
            .renameWindow(window: window(1), name: "x"),
            .selectWindow(window: window(1)),
            .listWindows(window: window(1)),
            .displayLayout(window: window(1)),
        ]
        for c in windowScoped {
            let s = c.controlModeString
            #expect(s.contains("@1"), "expected @1 in \(s)")
            // No %pane target token (the format strings don't contain a bare %).
            #expect(!s.contains("%"), "window-scoped command leaked %: \(s)")
        }
    }
}
