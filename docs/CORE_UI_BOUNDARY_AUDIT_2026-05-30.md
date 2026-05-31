# Core/UI Boundary Audit

> Status: 2026-05-30 — read-only investigation. No code changed.

## 1. Current state — how UI calls Core

ViewerCore is genuinely SwiftUI-free (only two AppKit imports in all of Core/Kit: `SyntaxTheme.swift:1`, `FileTreeRecency.swift:1`; zero `import SwiftUI`/`Cocoa`). The orchestrator `DocumentModel` lives in **ViewerUI** (`Sources/ViewerUI/DocumentModel.swift:14-15`, `import SwiftUI`+`Combine`, `@MainActor ObservableObject`, 2261 LOC) — it is the main *caller* of Core, not a Core type. The main *consumed* Core types are `DocumentController`, `TabsState`, `TextFile`, `EditorBuffer`.

| Mechanism | Where | Portability implication |
|---|---|---|
| Value types by copy (`TextFile`, `DocumentState`, `Tab`, `HighlightRun`, `CSVParser.Result`, `DiffMark`) | everywhere | Cleanly serializable; maps to uniffi records/enums. The good case. |
| Sync pure-logic calls (`DocumentController.open`, `Formatter.prettyPrint`, `HexDumpBuilder.build`, `CSVParser.parse`, `FuzzyMatcher`) | `DocumentModel.swift:1701`, `HexView.swift:443`, `CSVTableView.swift:161` | Ideal FFI targets — stateless, value-in/value-out. |
| `actor`+`async` (`LSPPool`, `HighlightCacheActor`) | `DocumentModel.swift:176`, `:1502` | Crosses to async FFI; doable but Swift-concurrency-shaped. |
| Combine `@Published` reactive state (~81, agent tally, unverified) | `DocumentModel`, `FindCoordinator`, `SidebarModel`, `TabCoordinator`, `EditorCoordinator` | **Hardest boundary problem.** A Rust/WASM/ratatui front-end cannot observe Combine; must become an explicit event/diff stream. |
| Closure callbacks (`editor.onReloadFromDisk`, `lspPool.setOnDiagnostics`) | `DocumentModel.swift:199-269` | In-process function pointers; must become typed messages across a serializable boundary. |

### Existing MCP surface (the good part)
- `AutomationHost` protocol (`AutomationHost.swift:15-68`) — **10 methods** (validator-corrected from "11"), defined in ViewerCore, no AppKit/SwiftUI import. DTOs `AutomationState`/`TabDescriptor` are Codable/Sendable (`:74-107`).
- `MCP.Value` (`MCPProtocol.swift:24-109`) — clean recursive JSON sum type, Int-before-Double guard.
- `MCPFraming` — LSP-style Content-Length framing, 16 MiB ceiling, transport-honest.
- `MCPServer` (`MCPServer.swift:19`) — off-main→MainActor bridge (`runOnMainActor`, `:189-206`).
- **10 MCP tools** (`MCPToolCatalog.swift:38-47`): `open_path`, `select_tab`, `set_view_mode`, `goto_line`, `find`, `visible_text`, `current_state`, `toggle_bookmark`, `list_bookmarks`, `snapshot_window`.

**Layering health:** good. The gap is *coverage + shape*, not purity.

## 2. What can move DOWN to Core (concrete candidates)

| Item | File:line | Why it's not UI |
|---|---|---|
| Tab state machine (open/close/reveal, per-tab caches, LRU eviction, language adjudication) | `TabCoordinator.swift:42-469` (`cleanupAfterClose:262`, `cacheFormatted:386`, `effectiveLanguage:318`) | Pure state-machine + cache logic; only UI tie is `ObservableObject`. Prime pilot. (Caveat below.) |
| Sidebar tree flatten/sort/keyboard-nav/git-status mapping | `SidebarModel.swift:139-401` | All Foundation-level. (Caveat: embeds FolderWatcher — see §3.) |
| Dirty tracking, save orchestration, external-edit conflict *decision* | `EditorCoordinator.swift:241-360` | Portable; NSAlert sites (`:434-449`, `:469+`) already behind test-override closures, so decision is separable from presentation. |
| `showGitLog` markdown-table assembly | `DocumentModel.swift:967-1019` | Pure string formatting over `GitClient.log`; belongs in `Sources/ViewerCore/Git/` next to `GitClient`. |
| `refreshDiffMarks` pipeline (`git diff`→`DiffHunkParser.parse:715`→`DiffGutterFeeder.markers:719`) | `DocumentModel.swift:685-729` | Orchestration reusable; only the `@Published` publish is UI. |
| `isUnderTCCProtectedRoot` path policy | `DocumentModel.swift:449-473` | Path-prefix decision rule; macOS *policy* but pure-logic, unit-test-shaped (no-op on Linux). |
| `openResolved`/`setCurrentViewMode` transition rules | `DocumentModel.swift:1699`, `:2133` | State-transition decision rules; portable rule-set entangled with `@Published`+Task dispatch. |

**Genuinely UI (do NOT move):** `MetadataPanel` (ImageIO/AVFoundation/PDFKit, `:114-207`), all `*View.swift`, `CodeMirrorEditorView` (WKWebView), `HexTextController` (NSTextView), NSAlert/NSMenu sites.

## 3. Interface critique — where the boundary is leaky/ad-hoc

| Aspect | Verdict | Evidence |
|---|---|---|
| MCP protocol/framing/value types | Elegant | `MCPProtocol.swift`, `MCPFraming.swift` — pure ViewerCore, Codable |
| `AutomationHost` as ViewerCore seam | Elegant | UI-free protocol; UI-side conformance mechanical (`DocumentModel+AutomationHost.swift:14`) |
| `FindMatch.range: NSRange` | Leaky | `FindEngine.swift:30` — Sendable but **not Codable**; UTF-16; hand-marshalled at `MCPToolCatalog.swift:163-170` |
| `SyntaxTheme` / `FileTreeRecency` use `NSColor` | Leaky — blocks Linux/WASM | `SyntaxTheme.swift:15-19,114` (`@retroactive @unchecked Sendable`); `FileTreeRecency.swift:94-124` |
| `SessionsCoordinator` is `ObservableObject`+`@Published` | Leaky (Combine in Core) | `SessionsCoordinator.swift:32,44-50` |
| `LSPNavigationStore` / `LSPDiagnosticsStore` are `ObservableObject`+`@Published` | Leaky (Combine in Core) — **missed by orig agents** | `LSPNavigationStore.swift:12,45-54`; `LSPDiagnosticsStore.swift:16,18` |
| "Headless" `--mcp-stdio` builds SwiftUI model + `NSApp.run()` | Leaky — core can't run headless | `main.swift:1518-1519` (`MCPServer(host: model)`, model is `DocumentModel`), `:1560-1580` |
| No read-model / no event stream | **Biggest gap** | `MCPServer.swift:117-122` drops all notifications; `current_state` is poll-only |
| Two serialization surfaces (`ScriptRunner` DSL + MCP) drift | Ad-hoc | `ScriptRunner.swift:57+` string verbs vs MCP tool names — different vocabularies, divergent coverage |
| `@MainActor`-by-protocol host | Latency risk at scale | `AutomationHost.swift:14`; every call hops main via `runOnMainActor` (`MCPServer.swift:188-206`) — fine at 10 cmd/s, bottleneck for a chatty live UI |

**MCP coverage gaps** (exist in Core, unreachable over MCP): edit (`EditorCoordinator` save/buffer/dirty), git (`GitClient.swift` — status/diff/log/graph, Sendable+subprocess, cleanest remoteable subsystem), LSP (hover/definition/diagnostics), sessions (`SessionSnapshot` Codable), review (`ReviewComment` Codable), cross-file search (`runCrossSearch`, `DocumentModel.swift:785`), **rendered HTML** (`HTMLRenderer.renderPage`, `HTMLRenderer.swift:31` — pure, web-ready, never exposed; only `loadHTMLString`'d at `MarkdownRenderedView.swift:147`), highlight spans.

## 4. Proposed interface — options + recommendation

| Option | Shape | Buys | Costs | Remote/browser fit |
|---|---|---|---|---|
| **A** — rich in-process Swift API + derived serializable boundary | Generate MCP/wire from a single verb catalog; Mac UI never serializes | Zero tax on Mac UI; smallest delta; MCP proves pattern | Two representations to sync forever (DSL-vs-MCP drift already manifesting); "same Mac UI remote" needs a 2nd adapter; doesn't force AppKit leaks out | Browser OK; same-Mac-UI-remote awkward |
| **B** — one Command/Query/Event protocol all front-ends use | Commands (mutate), Queries (read), Events (server→client, replaces Combine). Mac SwiftUI = just another client | Satisfies both vision halves; kills DSL/MCP drift; event channel replaces Combine that can't cross a wire | Highest Mac-UI rework (views re-derive from read model, lose `@Published`); serialize-at-edges tax; per-keystroke CM6 batching needed; `@MainActor` host main-hop inherited | Best fit; one protocol, N transports/front-ends |
| **C (recommended)** — Option B protocol as contract + in-process Swift fast-path for Mac | B's protocol is source-of-truth; Mac UI takes in-process Swift binding (pass Sendable values, skip JSON); non-Mac uses serialized transport | Mac near-zero tax + identical contract → "same UI remote" is a transport swap; natural uniffi/swift-bridge target (Commands/Queries/Events = generated FFI surface, payload-events = uniffi enums-with-payloads) | Two bindings, one contract; discipline needed so in-process path doesn't grow capabilities the wire lacks (the DSL/MCP drift trap); still inherits `@MainActor` main-hop unless host is de-main-actored | Full coverage with Mac fast-path |

**Recommendation: Option C.** Only option satisfying *both* halves of the vision (headless-Linux+browser AND same-Mac-UI-remote) without taxing the common Mac path, and the natural target for the uniffi/swift-bridge Rust migration. In all options MCP becomes the reference serialization: `tools/call`=Commands, a generalized `current_state`=Queries, `notifications/*`=Events (the dropped channel at `MCPServer.swift:117-122`).

**Prerequisites (option-independent):** (1) de-NSColor `SyntaxTheme`+`FileTreeRecency` → RGBA, resolve to NSColor at view edge; (2) make `FindMatch` Codable (byte/char offsets, not NSRange); (3) de-Combine the three Core `ObservableObject`s → plain state + event emission; (4) add the Event channel (tab-switch, file-changed, dirty-changed, diagnostics-arrived, git-status-changed, cursor-moved); (5) make `--mcp-stdio` truly headless — host on a UI-free core object, `DocumentModel` becomes a client; (6) collapse the `ScriptRunner` DSL into Commands; (7) fill verb gaps — edit + git first (`GitClient` is lowest-friction).

## 5. Map to the remote/browser vision

```
            Commands ─────────►┌──────────────┐◄───────── Commands
  Mac UI    Queries  ─────────►│  UI-free     │◄───────── Queries   Browser UI
  (in-proc  Events   ◄─────────│  CORE        │─────────► Events    (WebSocket)
   binding) [Swift values]     │ (host object)│         [JSON frames]
                               └──────────────┘
                          MCP = reference serialization
```
- **Reuse is high, reimplementation low.** The expensive/correctness-critical render is *already* web tech: `HTMLRenderer` emits a full CSP'd HTML page (`HTMLRenderer.swift:31-56`); Mermaid (`Resources/mermaid/`) and CodeMirror 6 (`Resources/codemirror/`) are browser-native JS hosted in WKWebView; the CM6 bridge envelope (`CodeMirrorBridgeV1.swift`, `{v,type,replyId}`) is a WebSocket protocol in disguise. Mac-specific rendering (NSTextView source/hex/diff) is the "dumb" surface; its *data* (text, spans, `HexLayout`, `DiffParser`) is all portable Core.
- **Transport:** WebSocket + JSON-RPC framing is the best fit (bidirectional → enables the missing notification stream; browser-native; reuse the exact `MCP.Request/Response` Codable types + a `Notification` shape). stdio stays for local automation only.
- **Core location:** thin client + remote core (headless Linux box is the stated goal); WASM-in-browser is a later, different deployment of the same portable core.

## 6. Risks + open questions
- **State ownership / multi-client conflict.** Today state lives in the SwiftUI model; remote mode inverts this (state server-side, UI is projection). `EditorCoordinator.presentExternalEditConflict` handles *single*-client external edits; multi-client (browser + Mac on one core) is strictly harder and has no code concept today.
- **Latency on per-keystroke paths.** CM6 does incremental edits (`CMEditApplier`, `v=2 incrementalChange`); round-tripping every keystroke to Linux adds RTT. Bridge is already batched-async, which helps.
- **`@MainActor` host bottleneck** (`AutomationHost.swift:14`) — must be addressed for a chatty live UI regardless of option.
- **DSL/MCP drift is a live warning** that Option A's "two representations" failure mode is real.
- **Numeric tallies** ("~140 referenced types", "195 DocumentModel methods", "81 @Published", "57/73 files") are the agent's own greps, **not independently verified** — treat as approximate.
- The "smallest-step uses the writeLock the server already holds for push" framing is **overstated**: the lock exists but no server-initiated write path does (`MCPServer.swift:147` only sends replies) — adding push is more than wiring a callback.