# tmux `-CC` (control mode) native integration — design

**Epic:** TSK-964 (supersedes the spike scope on TSK-690)
**Date:** 2026-06-18
**Status:** design — decomposed into 5 slices (see end)

## 0. Goal

Native tmux integration, the way iTerm2 does it. The user runs `tmux -CC`
(or attaches a remote session over `ssh … -t tmux -CC attach`) and instead
of seeing tmux's own status bar drawn *inside one* of our terminal panes,
the tmux **windows become native app tabs** and tmux **panes become native
splits** inside each tab. Scrollback, selection, copy/paste, find — all use
*our* terminal surface, not tmux copy-mode. Detach/reattach and session
restore are first-class.

This is **not** "run tmux in the terminal" (that already works — tmux is
just a program on the PTY). Control mode (`-CC`) makes tmux speak a text
protocol on the PTY instead of drawing a TUI, so the *host* renders the
windows/panes. We become a tmux **client**.

## 1. What tmux control mode actually is

When tmux is started with `-CC`, the PTY stops carrying a rendered TUI.
Instead it carries a **line-oriented control protocol**, multiplexing every
pane's output over the single stdout, and accepting tmux commands on stdin.

### 1.1 Reply framing (synchronous command results)

Every command we *write* to tmux's stdin gets a framed reply:

```
%begin <timestamp> <command-number> <flags>
…command output lines (may be empty)…
%end   <timestamp> <command-number> <flags>      ← success
        — or —
%error <timestamp> <command-number> <flags>      ← failure
```

The `<command-number>` correlates the reply to the command we sent (we keep
a FIFO of in-flight commands; tmux replies in order, but the number lets us
assert it). Lines between `%begin` and `%end`/`%error` are the literal
command output (e.g. `list-windows` rows, the `display-message` of a layout).

### 1.2 Notifications (asynchronous, unsolicited)

Interleaved with replies, tmux pushes notifications. The ones we must handle:

| Notification | Payload | Meaning / our action |
|---|---|---|
| `%output %<pane> <data>` | pane id + **octal-escaped** bytes | feed `<data>` (unescaped) into that pane's `TerminalScreen` |
| `%window-add @<win>` | window id | new tmux window → new app tab |
| `%window-close @<win>` | window id | window gone → close the tab |
| `%window-renamed @<win> <name>` | window id + name | retitle the tab |
| `%layout-change @<win> <layout> [<visible-layout>] [<flags>]` | window + layout string | re-parse panes → rebuild splits for that tab |
| `%session-changed $<sess> <name>` | session id + name | the attached session changed |
| `%client-session-changed <client> $<sess> <name>` | — | our client's session changed |
| `%sessions-changed` | — | session list changed; re-`list-sessions` |
| `%pane-mode-changed %<pane>` | pane id | pane entered/left a tmux mode (copy/view) |
| `%window-pane-changed @<win> %<pane>` | window + pane | active pane within a window changed |
| `%exit [<reason>]` | optional reason | tmux is detaching/exiting → tear down the controller |
| `%begin`/`%end`/`%error` | (see 1.1) | reply framing, not a notification |

Other `%…` lines (`%extended-output`, `%continue`, `%pause`, `%subscription-changed`,
`%paste-buffer-*`, `%unlinked-window-*`, …) are parsed into a typed
`.unknown(name, args)` case so the stream never desyncs on a tmux version we
don't fully model — forward-compat by default.

### 1.3 The octal escape of `%output`

`%output` payload bytes that are non-printable or control are escaped as
`\NNN` (backslash + **three octal digits**), and a literal backslash is
`\\`. Everything else is the raw byte. Unescaping is a pure byte transform:
scan for `\`, read exactly 3 octal digits → one byte; `\\` → `\`. This is
the single most test-critical transform (a bug here corrupts every pane).

### 1.4 The layout string

`%layout-change` (and `display-message -p '#{window_visible_layout}'`) gives
a layout string:

```
<checksum>,<WxH>,<X>,<Y>[,<pane-id> | {<h-split children>} | [<v-split children>]]
```

- A **leaf** is `WxH,X,Y,<pane-id>` (a pane).
- `{ … }` groups children laid out **left-to-right** (a horizontal split —
  panes side by side, a vertical divider between them).
- `[ … ]` groups children laid out **top-to-bottom** (a vertical split).
- The leading `<checksum>` is a 4-hex-digit csum of the rest (we can verify
  or ignore; parsing doesn't need it).

Example: `bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0[89x20,89,0,2,89x19,89,21,3]}`
= a top-level horizontal split: pane 1 on the left (88 wide), and on the
right a vertical split of pane 2 over pane 3.

This string → a `PaneNode` tree is slice (b).

## 2. Native behaviors (the iTerm2-parity contract)

1. **tmux windows → native app tabs.** Each tmux window `@N` maps to one
   terminal tab in the existing tab strip. `%window-add`/`%window-close`/
   `%window-renamed` keep the strip in sync. Creating a tab in our UI sends
   `new-window`; closing one sends `kill-window`.
2. **tmux panes → native splits.** Each window's `%layout-change` is parsed
   to a pane-tree; we render nested h/v `SplitView`s with our own dividers.
   Dragging a divider sends `resize-pane`. `split-window`/`kill-pane` are
   driven from our UI; tmux's own `prefix "` / `prefix %` arrive as layout
   changes we apply.
3. **Native scrollback + selection (NOT tmux copy-mode).** Each pane is a
   normal `TerminalScreen` with our scrollback ring, scroll-wheel viewport,
   text selection, copy, and find. We never enter tmux copy-mode for
   scrolling — the user scrolls *our* buffer. (tmux's own scrollback beyond
   what it has streamed is out of v1 scope; we hold everything it sends.)
4. **Detach / reattach.** Detaching (`%exit` / our "Detach" command sending
   `detach-client`) tears down the controller but leaves tmux running. A
   later `tmux -CC attach` rebuilds tabs/splits from `list-windows` +
   per-window layout queries — the session's state is recovered from tmux,
   the source of truth.
5. **Session persistence / restore.** On attach we enumerate the existing
   session (windows, panes, names, active pane, layouts) and rebuild the
   native UI to match, so reconnecting "just works". Our own per-tab UI
   prefs (font size, scroll position) persist locally as today.
6. **Resize → `refresh-client`.** When our window/pane geometry changes we
   compute the overall client size and send
   `refresh-client -C <cols>x<rows>` (and `resize-pane` for explicit pane
   drags). tmux re-lays-out and answers with `%layout-change`, which we
   apply — geometry is *negotiated*, with tmux authoritative.
7. **Window-name / status sync.** `%window-renamed` updates the tab title;
   `set-titles` / `#{window_name}` flow into our tab labels. Conversely,
   our rename action sends `rename-window`.

## 3. Architecture — how it layers on the existing terminal

The existing terminal stack is clean for this:

```
            EXISTING (unchanged for raw shells)              NEW (tmux -CC)
            ──────────────────────────────────              ──────────────
  ViewerCore/Terminal  (PURE, host-tested)
    • ANSIParser → TerminalScreen          ───────────────▶ reused per pane
    • TerminalKeyEncoder                   ───────────────▶ reused per pane
    • TerminalPaneLayout (persist)                          + TmuxControlParser  (a)
                                                            + TmuxLayoutParser   (b)
                                                            + TmuxSession model  (c)

  ViewerUI/Terminal  (live, VM-tested render)
    • PTYProcess (forkpty)                 ───────────────▶ reused: spawns `tmux -CC` (d)
    • TerminalModel (PTY↔ANSIParser)                       + TmuxController     (d)
    • TerminalPaneStore (tabs)             ───────────────▶ tabs gain a tmux mode
    • TerminalRepresentable / NSView                       + split rendering    (e)
```

Key insight: a tmux pane is *just another `TerminalScreen`* fed by an
`ANSIParser` — exactly what `TerminalModel` already wraps, minus the 1:1 PTY.
So the new layer is: **one PTY (the `tmux -CC` process) fans out to N
`ANSIParser`/`TerminalScreen` instances**, keyed by tmux pane id, instead of
the current one-PTY-one-screen. The `TmuxController` owns the single PTY and
demultiplexes `%output` into per-pane parsers.

### 3.1 Data flow

```
 tmux -CC stdout ─▶ TmuxControlParser (a) ─▶ [ControlModeEvent] ─┐
                                                                 ▼
                                              TmuxSession (c) applies events:
    control commands  ◀── TmuxController (d) ── %output → pane.feed(unescaped)
   on tmux stdin                                %layout-change → TmuxLayoutParser (b) → pane tree
                                                %window-* → add/close/rename tab
                                                                 │
   keystrokes ──▶ active pane ──▶ send-keys / paste-buffer ──────┘  (d)
   geometry  ──▶ refresh-client / resize-pane                       (d)
                                                                 ▼
                              SwiftUI: tabs (windows) × nested splits (panes)  (e)
```

### 3.2 Why a separate controller (not bolted onto `TerminalModel`)

`TerminalModel` is a tidy 1 PTY ↔ 1 screen. tmux mode is 1 PTY ↔ N screens
+ a command/reply channel + a window/pane tree. Forcing that into
`TerminalModel` would muddy the simple shell path. Instead, a tmux tab in
`TerminalPaneStore` holds a `TmuxController` reference (shared across all
tmux windows of the same session) rather than its own `TerminalModel`. The
plain-shell path is untouched.

## 4. Constraints

- **No new dependencies.** tmux is the user's external binary; we parse its
  protocol with stdlib only (byte scanning, no regex engine needed). The
  octal-unescape, reply framing, and layout parsing are hand-written.
- **Pure/host-testable core.** Slices (a) parser, (b) layout, (c) model are
  pure `ViewerCore` logic with full host tests — no PTY, no AppKit. Feed
  them byte slices / strings and assert the typed output / model state.
- **Live spawn + render are VM-validated.** Slices (d) (spawn `tmux -CC` +
  pump) and (e) (split rendering + input routing + resize) touch the live
  PTY and the AppKit surface, so they self-skip on host and validate on the
  UTM VM (T4/T5), per the testing rules.
- **Graceful degradation.** If `tmux` is absent, or a non-`-CC` tmux is
  detected, fall back to running it as a normal TUI in one pane (today's
  behavior). Unknown `%…` lines never desync the parser (`.unknown` case).
- **Backpressure.** A busy pane can flood `%output`; the controller feeds
  parsers off-main on the existing parse queue and the throttled
  `version`-bump discipline (one frame/16ms) is reused per visible pane.

## 5. Slice decomposition (TSK-964)

| Slice | What | Tier |
|---|---|---|
| **a** | Control-mode **protocol parser**: byte/line stream → `[ControlModeEvent]` (reply framing + octal-unescape of `%output`) | host (pure) |
| **b** | **Layout-string parser**: `checksum,WxH,X,Y{…}/[…]` → `PaneNode` tree | host (pure) |
| **c** | **Session/window/pane model**: windows↔tabs, panes↔splits, active-pane, apply (a)+(b) events | host (pure) |
| **d** | Spawn `tmux -CC` + stdin command-writer + stdout event-pump wired to (c) | VM (live PTY) |
| **e** | Render windows/panes as native tabs/splits + route keys to active pane + resize→`refresh-client` | VM (render) |

Build order: a → b → c (independent pure cores, can land in parallel; c
depends on the *types* of a+b but not their impl), then d (wires a+c to the
live PTY), then e (renders c + routes input through d). Slices a/b/c carry
the bulk of the correctness risk and are fully host-guarded.
