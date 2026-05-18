# Parallel work status — 2026-05-18 evening

Background agents working in isolated git worktrees off the main
repo. Each branch is reviewable independently before deciding whether
to land.

## Worktrees

| Branch | Worktree path | Scope | Status |
|---|---|---|---|
| `poc/sessions` | `/Users/me/Documents/workspaces/claude/_poc_sessions` | PoC: tabs-within-tabs | **Done** — 26 tests pass |
| `poc/plugins` | `/Users/me/Documents/workspaces/claude/_poc_plugins` | PoC: plugin v1 surface | **Done** — 18 tests pass |
| `poc/lsp` | `/Users/me/Documents/workspaces/claude/_poc_lsp` | PoC: SourceKit-LSP integration | **Done** — 19 tests pass (incl. real sourcekit-lsp smoke) |
| `feat/treesitter-lazyload` | `/Users/me/Documents/workspaces/claude/_feat_treesitter` | TreeSitter lazy-grammar refactor + 6 new langs | Running |
| `feat/mcp-stdio` | `/Users/me/Documents/workspaces/claude/_feat_mcp` | MCP roll-our-own stdio JSON-RPC server | **Done** — 51 tests pass + manual e2e verified |
| `feat/walkthrough-ui` | `/Users/me/Documents/workspaces/claude/_feat_walkthrough_ui` | Walkthrough player UI (per user mock) | **Done** — 22 tests pass, end-to-end sample verified |

## What landed on `main`

Today's commits since `5b74676`:

- `492fca5` — review-agent fixes (HIGH MediaPreview, MED engine reentrancy + loader portability, LOW transport perms/bound)
- `e863291` — LESSONS: Foundation URL portability + NSViewControllerRepresentable intrinsic-size leak
- `30464f4` — ModeBar overflow at high uiScale + ClaudeTimeline VoiceOver fix
- `85998c9` — overnight session summary
- `617e962` — md narrow-strip — frame on TextDisplayView + clamp invalid persisted viewMode
- `9655700` — perf + hardening 4-item small batch (cancellation token, CSV threshold, typed Walkthrough enums, renderedHTMLCache content-hash)
- `cd9c761` — build: bundle-size check split (35 MB total + opt-in 15 MB exec cap)

## Sessions PoC summary (already in `poc/sessions`)

Single squashed commit on branch `poc/sessions`. **No push.**

- `Sources/ViewerCore/Sessions/{SessionSnapshot,SessionStore,SessionsCoordinator}.swift`
- `Sources/ViewerUI/Sessions/{SessionStripView,SessionsCoordinatorBox}.swift`
- Additive change to `ContentView` (optional `sessionsCoordinator` param)
- `Sources/MarkdownViewer/main.swift` — temp-dir test bootstrap with 2 hardcoded sessions
- `Tests/ViewerCoreTests/Sessions/...` — 26 tests, all passing

### Design-doc gaps surfaced

1. **Persistence concurrency unspecified** — design says "500 ms debounced write" but doesn't name the coalescer. Two writes can race on terminate-flush. Needs an explicit serial dispatch queue + flushSync().
2. **`Lifecycle.mount/detach` ordering for the first open** — detach-then-mount is implied for switches but undefined for initial open. Real `DocumentModel` hookup will trip on this when `mount` needs a file-watcher fd `detach` was supposed to free.
3. **`forceNew` symlink-equivalence rule** is contradictory — design says worktrees through different symlinks are distinct, but the duplicate-detection logic stores the *resolved* path. Either store original-URL and compare resolved, or accept symlinks always collapse.

### Effort estimate

- **Phase 1 (single-session façade)**: 40-55 hours
- **Phase 2 (multi-session + DocumentModel SRP split)**: 70-104 hours
- Risk multiplier ×1.3 on the SRP split

## Plugins PoC summary (already in `poc/plugins`)

Single commit on branch `poc/plugins`. **No push.**

- `Sources/ViewerCore/Plugins/{PluginManifest,PluginRegistry,SidebarSectionRegistry}.swift`
- `Sources/ViewerCore/Plugins/BundledPlugins/RowCounterPlugin.swift` — trivial bundled plugin
- `Sources/ViewerUI/PluginSidebarSection.swift` + wired into `SidebarView`
- `Sources/MarkdownViewer/main.swift` — registers bundled + on-disk plugins at app launch
- `Tests/ViewerCoreTests/Plugins/...` — 18 tests, all passing

Manifest is JSON, narrow Tier A subset. Discovers plugins under
`~/Library/Application Support/com.markdownviewer.MarkdownViewer/Plugins/*/plugin.json`.
Per-folder fail isolation. Tier B/C parse and emit
`loadedWithWarnings` rather than registering.

Extension point wired: sidebar sections (a new section appears
between first-party sections and the FILES tree).

### Design-doc gaps surfaced

1. **Tier A static-bind format is undefined.** Design says "sidebar
   sections bound to a host variable" but never specifies the binding
   shape — query/filter syntax, refresh trigger, which host vars.
   Without this, on-disk Tier A sections can only render placeholder
   rows. Either add an expression mini-language or admit Tier A
   sidebars are theme-only.
2. **Bundled vs third-party split is implicit.** The doc lists three
   tiers but doesn't formally name a "first-party bundled" path —
   which is exactly where the row-counter sits. Add a "Tier 0:
   bundled" row to the §3 table so the seam is explicit.
3. **In-process Swift fail isolation has no story.** §9.5 covers
   Tier A/B/C but says nothing about bundled-Swift plugins running
   in-process. Swift has no panic boundary; a bundled plugin that
   traps crashes the host. Doc should either forbid native third-
   party explicitly or define a runtime contract (no throws at
   boundary, wall-clock guard, row cap, fatalError audit). The PoC
   has a `safeRows` placeholder for the contract approach.

### Effort estimate

- **PoC → production**: 8-12 engineer-days
  - Tier B subprocess host: 3-4 days
  - Tier C WKWebView bridge: 3-4 days
  - Permission grant store + first-install UX: 1-2 days
  - Settings → Plugins pane: 1 day
  - Drag-drop install + validator UX: 0.5-1 day
  - Two more contribution points wired: 1-2 days

## LSP PoC summary (already in `poc/lsp`)

Single squashed commit on branch `poc/lsp`. **No push.**

- `Sources/ViewerCore/LSP/{LSPProtocol,LSPFraming,LSPClient,LSPDiscovery}.swift`
- `Sources/ViewerUI/LSP/LSPHoverAttachment.swift` — Cmd-click + Option-hover NSEvent monitors
- Additive extension on `TextDisplayView.SourceTextController` exposing `lspTextView`
- 19 tests: 9 framing, 9 polymorphic-decode, 1 real-process smoke against `sourcekit-lsp` on this workspace (~5s end-to-end)

Smoke test skips gracefully if the binary is missing; set
`MDV_RUN_LSP_SMOKE=1` to make it required.

### Design-doc gaps surfaced

1. **Swift 6 `isolated deinit` is unspoken**. Holders touching
   non-Sendable AppKit state (NSTrackingArea, monitors) need it
   under strict concurrency. Doc never references SE-0371. Caught
   on first build.
2. **`hover.contents` decode order is silently load-bearing**.
   MarkedString `{language, value}` decode must come *before*
   MarkupContent `{kind, value}` — both expose `value` and naive
   Codable enum decoding swallows the language. Doc's sketch
   implies a Codable enum which Swift's default order would
   misdecode.
3. **Hover trigger is unspecified**. Doc says "mouse-over an
   identifier" but §3.5 only walks Cmd-click. Mouse-move on
   NSTextView is non-trivial (tracking-area lifecycle, modifier
   gate vs cursor-paused timer vs subclass). PoC compromised on
   Option+mouse-move. The doc should pin the trigger.

### Effort estimate

- **PoC → production**: 3-5 engineer-days
  - Workspace-root + language detection: 0.5d
  - `LSPPool` actor (key-based lookup, idle reaper, shutdown): 1d
  - Cancellation token + restart-on-crash + `$/cancelRequest`: 1d
  - Position-encoding negotiation (utf-16 ↔ utf-8 ↔ grapheme): 0.5d
  - Real hover popover (markdown rendering, dismissal): 1d
  - Outline sidebar section (`textDocument/documentSymbol`): 1d
  - Tests + diagnostics panel: 1d

### Surprises

- `Data.subdata(in:)` traps on `0..<n` when the `Data` value has
  non-zero `startIndex` after `removeFirst` — signal-5 with no
  stack. Re-base with `Data(rawBuffer)` at decoder entry.
- `Process` write via `FileHandle.write(contentsOf:)` is blocking;
  fine for ~50 KB `didOpen` but a real impl needs an async write
  queue.
- `sourcekit-lsp` cold-launch is fast on a warm toolchain (~5s
  end-to-end for init/open/hover/def/shutdown). Cold-toolchain
  numbers TBD.

## Walkthrough UI summary (already in `feat/walkthrough-ui`)

Three atomic commits on branch `feat/walkthrough-ui`. **No push.**
22 tests pass on host.

- `Sources/ViewerUI/Walkthrough/DocumentModel+Walkthrough.swift` —
  `WalkthroughBridge` + `selectTab(forURL:)` (folds the missing
  `switchTab` verb into `openFile`'s handler per user decision).
- `Sources/ViewerUI/Walkthrough/WalkthroughAutoAdvance.swift` —
  timer + speed (1x / 1.5x / 2x).
- `Sources/ViewerUI/Walkthrough/WalkthroughPlayerImpl.swift` —
  engine delegate, maps Actions to existing DocumentModel methods.
- `Sources/ViewerUI/Walkthrough/WalkthroughPlayerView.swift` —
  controller strip (docked bottom of right pane per user decision).
- `Sources/ViewerUI/Walkthrough/WalkthroughOverlay.swift` —
  line / editor / sidebar / gitTab / window anchors (full design-v2
  suite per user decision).
- `Tests/Fixtures/walkthroughs/sample.json` + 4 test files.
- `Sources/MarkdownViewer/main.swift` — `--walkthrough PATH` CLI
  flag drives the engine on startup for local dev.

Player layout:

```
┌──── content (right pane) ──────────────────────────┐
│  source/rendered view  ◀── WalkthroughOverlay      │
│                            (highlight + popover)   │
├──── WalkthroughPlayerView (when isActive) ─────────┤
│  [claude] Welcome — let's tour…       ●●●─         │
│  [<][⏯][>]  1x▾  Steps▾  [+ Note]      [Exit]      │
└────────────────────────────────────────────────────┘
```

### Open issues / cut

- Popover anchor positioning is approximate (alignment-based, not
  measured frames). Precise anchoring needs `PreferenceKey` from
  each anchor target. Follow-up.
- `splitFile.alongside` field is unused (split pane doesn't accept
  a primary swap on command yet).
- `runDiff` maps to `showGitLog(scope: .file)` — per-SHA diff view
  not wired.
- `addBookmark` with a line uses `toggleCurrentLineBookmark` after
  scroll — non-idempotent so guarded with `bookmarkedLines(for:)`
  check. Cleaner: add `setBookmark(url:line:)` API. Off-scope here.
- Note button logs to stderr only; Code Review thread wire-up is a
  separate task (per user decision — visual-only for v1).
- UI smoke deferred to VM per CLAUDE.md test rules; host filter
  covers pure logic.

## MCP stdio summary (already in `feat/mcp-stdio`)

Two atomic commits on branch `feat/mcp-stdio`. **No push.** 51 tests
pass + manual e2e against `.build/debug/MarkdownViewer --mcp-stdio`
confirms initialize → tools/list → tools/call round-trips. **Zero
new dependencies.** Bundle delta: +492 KB debug binary.

- `Sources/ViewerCore/Automation/MCPFraming.swift` — Content-Length
  codec, body cap 16 MiB. Subtle CRLF-as-single-grapheme bug caught
  and fixed (split at UnicodeScalar level, not Character).
- `Sources/ViewerCore/Automation/MCPProtocol.swift` — JSON-RPC +
  MCP DTOs (initialize, tools/list, tools/call).
- `Sources/ViewerCore/Automation/AutomationHost.swift` — protocol +
  `AutomationState`. All methods `@MainActor`.
- `Sources/ViewerCore/Automation/MCPServer.swift` — runtime; parks
  on stdin, dispatches to handlers via `DispatchQueue.main.sync` +
  `MainActor.assumeIsolated`.
- `Sources/ViewerCore/Automation/MCPToolCatalog.swift` — 10 tools.
- `Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift` —
  conformance; every method delegates to existing model API. No new
  model methods needed.
- `Sources/MarkdownViewer/main.swift` — `--mcp-stdio` flag. Sets
  activation policy to `.prohibited` (no Dock/menu/window), skips
  workspace restore, runs server. Stderr-only logging so stdout
  stays clean for framed protocol bytes.
- `Tests/ViewerCoreTests/Automation/...` — 51 tests:
  - 13 framing (encode/decode, multi-message, embedded newlines,
    LF-only, EOF, oversized body, case-insensitive headers)
  - 10 protocol envelope (Value Int-vs-Double fidelity, string ids,
    notifications, typed arg accessors)
  - 23 tool-catalog (FakeAutomationHost; per-tool args + result
    shapes; `/etc/hosts` → permissionDenied; missing UUID →
    invalidParams)
  - 5 server-over-pipe (initialize, tools/list with 10 tools,
    unknown method → -32601, tools/call success + path-denial as
    `isError=true`)

### Tools shipped (all 10 from design §6)

| Tool | Returns |
|---|---|
| `open_path` | `{ tabId }`; path must exist + be under `$HOME` or tempdir |
| `select_tab` | `{ changed }`; 1-based `byIndex` or UUID `byId` |
| `set_view_mode` | enum-validated against six `ViewMode` raw values |
| `find` | `{ matches, total, truncated }`; cap 1000 matches |
| `goto_line` | 1-based line ≥1, optional column |
| `visible_text` | UTF-8 byte-capped at 10 MB |
| `current_state` | `AutomationState` (tabs, viewMode, zoom, sidebar) |
| `toggle_bookmark` | file-level or line-level |
| `list_bookmarks` | array of `{ path, displayName, addedAt, line? }` |
| `snapshot_window` | `{ pngBase64, bytes }`; uses `cacheDisplay` so no Screen Recording permission |

### Intentionally cut

- `subscribe(events)` (design rank 10) — streaming + back-pressure,
  out of "just initialize/tools/list/tools/call" scope. Server's
  `writeLock` is in place so adding `publish(_:)` later is mechanical.
- Unix socket / TCP transports — explicitly out of v1.
- App Intents facade — separate from MCP v1.
- Audit log + first-connect prompt — stdio is per-launch-by-trusted-
  parent, so design §8 audit log doesn't apply.
- `notifications/tools/list_changed` — `listChanged: false` advertised.

### Manual verification (actually run)

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {capabilities:{tools:{listChanged:false}}, protocolVersion:"2024-11-05", ...}

→ {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
← 10 tools

→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"current_state","arguments":{}}}
← {content:[{text:"{...}",type:"text"}], isError:false}
```

## Cleanup when done reviewing

```bash
# Land what you want, then:
git -C /Users/me/Documents/workspaces/claude/markdown_viewer worktree remove _poc_sessions
# (repeat for each branch you don't want to keep)
```

Each worktree has only the diff for that one feature — no contamination
between branches.
