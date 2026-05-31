# One-way-door analysis — unprimed blank-slate explorer

I now have a comprehensive understanding of the codebase, the existing architecture decisions (especially the well-developed core/UI split thinking), the persistence model, and the state of each feature area mentioned. I have enough to write a candid, grounded answer.

---

# Review: Pre-Split Feature/Bug List — Architectural Risk, Gaps, and Sequencing

I read the architecture docs (`DESIGN.md`, `STATE.md`, the three `*2026-05-30` core/boundary/state docs), the session persistence layer, the shoulder-rail/panel store, the image/SQLite/diagnostic views, and the `Package.swift`. The team has already done unusually deep thinking on the core/UI split (`CORE_UI_BOUNDARY_AUDIT`, `STATE_ARCHITECTURE`, `REUSABLE_CORE_STRATEGY`). My answer leans on what's actually in the tree, and deliberately challenges the list rather than just ratifying it.

The single most important framing: **most of this list is UI surface area being piled onto an orchestration layer (`DocumentModel`, ~125 KB / ~2261 LOC, ~81 `@Published`, `@MainActor`) that lives in `ViewerUI` and that you've already decided is the months-long blocker to the split.** Every feature added the "easy" way (more `@Published` on `DocumentModel`, more direct AppKit reads in views) is debt you'll pay twice — once now, once when you extract the core. That tension runs through everything below.

---

## 1. Architecturally RISKY / likely-to-be-regretted items

### Tier A — genuine two-way-door-violations or core-shape commitments

**1. "Our own custom terminal" — and the terminal tool window as a "must".**
This is the highest-regret item on the list, for two independent reasons:

- **A terminal is a PTY + process lifecycle + a VT100/xterm emulator.** Writing your own emulator is a multi-month tar pit (escape-sequence coverage, scrollback, reflow, mouse, 256-color/truecolor, alt-screen, bracketed paste) that the project's "minimal dependencies / prefer stdlib" ethos will fight you on the whole way. xterm.js is the pragmatic answer **for the web/CM6-style WKWebView host you already run** — but it's a ~250 KB+ JS dep with its own supply-chain surface, and you'd still own the PTY bridge (`forkpty`/`posix_spawn` + a master-fd read loop) on the Swift side.
- **It collides head-on with the core split.** A terminal is the canonical *stream topic* in your own `STATE_ARCHITECTURE` doc (§3.8: "terminal output, tail-follow a growing log" — FIFO, bounded buffer, backpressure). You explicitly noted the MCP surface **drops all notifications** (`MCPServer.swift:117-122`) and that the **server→client event/stream channel is the single biggest gap**. So a terminal built *now*, before that channel exists, gets wired straight into `DocumentModel` as Mac-only AppKit glue — and then has to be torn out and re-plumbed through the stream-topic abstraction when the core moves. **If you build a terminal, build the stream-topic event channel first and make the terminal its first consumer.** That's the non-regret path; doing it the other way is the regret.

Also a security note the list doesn't mention: an embedded terminal is a full arbitrary-code-execution surface inside a *file viewer*. That detonates your sandboxing/notarization story (the app is "local signing only" today per `CLAUDE.md`, but Phase 9 wants Developer ID). A viewer that ships an interactive shell is a different threat model and a different App Store review conversation.

**2. HTML rendering.**
"HTML rendering?" sounds cheap because you already have `WKWebView`. The regret is **security model drift**. You have a carefully-built `HTMLSanitizer` (allowlist) + CSP for *user-supplied* HTML rendered to WKWebView, and `URLSchemePolicy` containment. Rendering arbitrary `.html` files *as live HTML* (JS enabled, remote subresource loads, `file://` access to the rest of the disk) blows through all of that. The DESIGN.md already flagged "JS disabled by default (opt-in per-tab)" — hold that line hard. The two-way-door risk: if you ship permissive HTML rendering and users rely on it (local JS dashboards, etc.), clamping it later is a breaking change. Decide the JS/network/file-access policy *before* shipping, not after.

**3. CORE vs UI SPLIT bundled as one list item.**
This isn't risky to *do* — it's risky to treat as a single line item alongside "fit images." It's the most expensive thing on the entire list (your own docs say months), and it's a **prerequisite** for several other items being done *right* (terminal, instrumentation streams, session independence, deeplinks). The risk is sequencing it as peer-priority with cosmetic fixes. See §3.

**4. Customization / scripting.**
You already have *two* divergent serialization surfaces — the `ScriptRunner` DSL (string verbs in `main.swift`) and the MCP tool catalog (10 tools) — and the boundary audit flags them as **already drifting** (`CORE_UI_BOUNDARY_AUDIT §3`: "Two serialization surfaces drift"). Adding a *third* scripting/customization vocabulary now, before you've collapsed those two into the Command/Query/Event contract (the audit's recommendation), institutionalizes a 3-way drift problem. Scripting is also a sandbox/security surface (what can a script *do*? read any file? spawn processes?). **Scripting should be defined as "the public name for the Command/Query/Event protocol," not a bolt-on.** Doing it before the protocol exists is a regret.

**5. Compressed files → "becomes a folder" without unzipping.**
The *feature* is fine and genuinely nice. The regret risk is in the naive implementation: zip-bomb amplification (a 1 MB zip → 100 GB expanded), path-traversal entries (`../../etc/...` — "zip slip"), symlink entries, and resource exhaustion on huge archives. You've already done TOCTOU/symlink hardening (`EditorWriter symlink refuse`) and regex-DoS guards — an archive reader needs the same paranoia (entry-count cap, expanded-size cap, reject absolute/`..` paths, no symlink following, decompress lazily per-file, never to a real temp dir you then forget to clean). Treat it as a security feature, not a convenience feature. Also: do it as a *virtual* FS over the archive (read entries on demand), not an eager extract-to-tmp, or it fights your large-file/bounded-RAM goals.

### Tier B — moderate, mostly "easy to do wrong" rather than wrong to do

**6. Instrumentation grab-bag (logs, metrics, profiling, per-tab memory, diagnostic JSON, fds/ports).**
Several distinct concerns smashed together with different risk profiles:
- **Logs/metrics UI**: fine, *if* there's an observability **sink** to read from. There basically isn't one today — `os_log`/`Logger` appears in only ~4 files, and the LSP layer already has a noted gap: `LSPLog.warn` has "no ViewerCore observability sink" (BACKLOG). So the real work is *introducing structured logging across the core*, then a UI. Don't build the viewer before the thing it views.
- **Per-tab memory usage in the status bar**: this is a **measurement lie waiting to happen**. Your own BACKLOG memory notes are explicit: WKWebView spawns shared XPC helper processes; "TextView 230 MB" is mostly persistent WebKit helpers, not per-tab. Per-tab attribution for WebView-backed tabs is not cleanly possible — you can't ask WebKit "how much of the shared GPU/Networking process is *this* tab." If you ship a per-tab number it will be confidently wrong and users will file bugs. Total process RSS + a "WebKit helpers" line is honest; per-tab is not.
- **Open ports / open fds in a diagnostic window**: on a sandboxed/notarized macOS app, enumerating your own fds is doable (`proc_pidinfo`/`/dev/fd`) but "open ports" implies listening sockets — which a *viewer* shouldn't have, and enumerating system-wide ports needs entitlements you don't want. Scope this to "fds and temp files *we* own," not a netstat.
- **Profiling / perf capture**: macOS already has Instruments + signposts. Rolling your own profiler is effort better spent adding `os_signpost` regions so Instruments works well. Don't rebuild a profiler.
- The **diagnostic window (DocumentModel as JSON)** is the *good* part — you already have `DiagnosticDump.swift`, and this is exactly the read-model/snapshot shape the core split wants. Lean into it; it's a freebie that also de-risks the split.

**7. Image pan via click-and-drag + Cmd+Scroll zoom.**
Low architectural risk (the `MediaPreviewView` already has zoom 0.1×–10× + fit/actual + keyboard + wheel/pinch). The only trap: it's pure AppKit `NSImageView` gesture state — keep the *zoom math* (`ImageZoomState.nextMagnification`, already factored out) separate from the gesture plumbing so it survives the split. It already is. Fine.

**8. Git file-history window with Cmd-click-two-commits diff.**
Medium risk only because of the interaction-state complexity (multi-select commit semantics, "delta vs current" vs "delta between two") layered onto a `@Published`-heavy panel. `GitClient` is already the "cleanest remoteable subsystem" (Sendable, subprocess) per the audit, so the *data* is portable; the risk is building the table's selection state machine in the view instead of as a small reducer. Build the selection model as plain testable state.

---

## 2. What's MISSING that a viewer heading toward a core split should be thinking about

These are the unknown-unknowns the list doesn't name. Several are *more* important than items that are on it.

**1. The server→client event/stream channel — and you've already identified it.**
This is missing from *the list* even though your own docs call it "the single biggest gap." The list has *consumers* of it everywhere (terminal output, log/metrics UIs, LSP diagnostics, file-changed-on-disk red dot, git-status dots, walkthrough flash/scroll, live folder stats) but never names *building the channel itself*. **This is the keystone.** Without it, every "live" feature on the list gets wired ad-hoc into Combine `@Published` on `DocumentModel` — which is precisely what doesn't cross the wire to a browser/TUI/Linux UI. **It belongs at the top of the list, ahead of the terminal.**

**2. Concurrency / off-main-thread is on the list as "PERF: work off main thread" — but it's underweighted and it's a correctness issue, not a perf nicety.**
The BACKLOG calls `materializeIfNeeded` off-main the "highest-leverage remaining UX win" (selecting a lazy tab on a 32 MB log freezes the UI). `DocumentModel` is `@MainActor`. Almost every *new* feature on this list (folder stats, git history, archive expansion, log/metric collection, terminal) is I/O-heavy and will freeze the main thread if done naively. The "two distinct problems" framing in `STATE_ARCHITECTURE §3.3` (main-actor blocking vs republish amplification) is exactly right and should govern how *every* item ships. This is a cross-cutting constraint, not a single backlog line.

**3. Schema versioning / migration discipline for everything that persists.**
`SessionSnapshot` does this well (schemaVersion, additive-optional fields, forward/backward compat). But the list adds *many* new persisted shapes — walkthrough catalog/history, recently-opened files, session *types* (Project/CodeReview/Pipeline/Metrics), per-session tool-window state, panel layout. Each needs the same versioning rigor or you get the "WorkspaceStore silent schema downgrade" bug that's already in your history (fixed in the audit). Missing from the list: **a single persisted-state versioning policy** that all the new stores adopt.

**4. Accessibility, i18n, and the very-bottom-status-bar tooltip description channel as a system.**
The tooltips item is good but the list treats it as decoration. It's actually an **accessibility + observability primitive**: `[title + description]` per element maps directly to `.accessibilityLabel` + `.accessibilityHint` (the `PanelRailButton` already does `.help()` + `.accessibilityLabel`). Define it once as a `Tooltip { title, description }` value type that drives *both* the hover widget, the status-bar description line, *and* the a11y labels — or you'll build three parallel string sources that drift. Missing entirely: any mention of VoiceOver/keyboard-only navigation for the *new* surfaces (terminal, git table, metrics).

**5. Cancellation / lifecycle for long-running work.**
Cross-file search, git log on a huge repo, archive expansion, folder stats, metric polling — all need cancellation when the user switches tabs/sessions or closes the panel. The `TabCoordinator.addCloseHook` pattern is the right seam and it exists. Missing from the list: a stated rule that every async feature registers cancellation through it. Without it you leak tasks per session, which directly undermines "session independence."

**6. Multi-window / multi-client state ownership — flagged in the audit, absent from the list.**
The audit's open risk: "remote mode inverts state ownership; multi-client (browser + Mac on one core) has no code concept today." The list's "session independence" item is the *near* version of this, but it stops at single-process sessions. If "same Mac UI in remote mode" and "browser drives the Linux core" are real, the **single-writer-per-session** decision (`STATE_ARCHITECTURE §3.11`) needs to be baked in *now*, because retrofitting writer-ownership onto features that assume "I am the only UI" is a rewrite. Missing: an explicit statement of which list features are single-writer-domain vs view-local.

**7. File-watch correctness at scale — and the Linux gap.**
The red-dot "file changed on disk" and the auto-refresh features lean entirely on FSEvents (`FolderWatcher`, `FileWatcher`). FSEvents is macOS-only and doesn't port (the Linux portability doc flags this). The Rust-core strategy names `notify` as the cross-platform replacement. Missing from the list: file-watching is a **port** (`HostPorts.watch` in the architecture sketch), and the red-dot feature should be built against that port abstraction, not FSEvents directly, or it's another thing to rewrite for Linux.

**8. Empty/loading/error states as a first-class pattern (partly on the list).**
"proper waiting/loading/errors" is listed under PERF but it's really a **state-machine completeness** requirement. `DocumentState` needs a `.loading(URL)` case (BACKLOG already notes this for `materializeIfNeeded`). Every new async surface needs explicit loading + error rendering or you get blank-flash bugs (you've hit the WKWebView reload-flash class before). Missing: a stated "every viewer has loading/empty/error" contract.

**9. Undo/redo and clipboard semantics across the new surfaces.** Not mentioned. The CM6 editor has undo; the SQLite browser, CSV table, hex, git table do not have a coherent copy/undo story. Minor, but users expect ⌘C to do something sane everywhere.

**10. Telemetry/privacy stance for the instrumentation features.** The metrics/logs UIs imply *collecting* data. DESIGN.md said "no telemetry until v1.0." If logs/metrics get persisted or (worse) phoned home, that's a privacy decision the list silently makes. State it.

---

## 3. Where I'd push back or sequence differently

The list is presented flat. I'd impose a dependency-driven order. The governing principle: **build the boundary primitives the live features need *before* the live features, and don't grow `DocumentModel` for things that should live behind the core protocol.**

```
                    ┌─────────────────────────────────────────────┐
   KEYSTONE  ──────►│ Event/Stream channel (server→client)         │  ← biggest gap per your own audit
   (do first)       │ + off-main work as a rule                    │
                    └───────────────┬─────────────────────────────┘
                                    │ unblocks ↓
        ┌───────────────┬───────────┴───────────┬──────────────────┐
        ▼               ▼                       ▼                  ▼
  Terminal (stream  Instrumentation       Live red-dot /      Walkthrough
  topic consumer)   logs/metrics UIs      git-status dots     flash/scroll
                    (need a log SINK)     (state topics)      (event-driven)
```

### Do FIRST (cheap, high-value, low-risk, ship-now)
These pay rent immediately and most are bug fixes that erode daily trust:
- **The bug cluster.** Most are small and high-irritation: closing-one-tab-reopens-two; shoulder buttons 4/5/6 doing nothing (the `PanelLayoutStore.toggle` plumbing exists — these are likely a `SidebarPanelKind` → action wiring gap or a data-presence predicate returning false, ~hours to fix); right-click-folder→Open in New Session re-opening the dialog when the folder is already known; binary files showing Source instead of HEX-only; the row-count tool window with no dismiss. These are trust bugs — fix them before any new feature.
- **Crash-state-not-restored.** You're right to suspect "writing state only on quit." Confirmed: `SessionsAppCoordinator.flushForTermination()` re-snapshots the live `DocumentModel` only on `applicationWillTerminate`/detach; the per-session JSON for the *active* session is frozen at bootstrap until then (`SessionsAppCoordinator.swift:191`, `LifecycleBridge.detach:319`). A crash = lost tab list/selection. **Fix: debounced live snapshot during the session** (your own `STATE.md` proposed 500 ms cross-property debounce — it just wasn't wired for the active session's live tab state). This is the highest-leverage reliability fix on the entire list and it's small.
- **Tooltips-as-a-system**, image pan/zoom polish, "fit images / center / Cmd+Scroll" — all low-risk, ship them. Just define the `Tooltip` value type once (drives hover + status bar + a11y).
- **Tab UX cluster** (active-tab-always-visible, shrink-to-overflow, pin-to-follow-focus, blue/red dirty/stale dots, right-click Refresh/Open-in-new-session). High daily value, contained to `TabBar`/`TabCoordinator`. The dots specifically *want* the file-changed event topic — build the simple polling version now, swap to the event channel later.

### Do the KEYSTONE before the heavy live features
- **Build the server→client event/stream channel** (the dropped `notifications/*` in MCP) as the Command/Query/**Event** contract the boundary audit recommends (Option C). Make `--mcp-stdio` actually headless as part of this. This is the thing that makes terminal/metrics/live-dots/walkthrough *not* be throwaway work.
- **Collapse `ScriptRunner` DSL + MCP into one verb catalog** *before* adding "customization/scripting," so scripting is the public face of the contract, not a third vocabulary.

### Sequence the core split as the explicit gate it is
Push back on treating "core Linux port / Rust core / TUI / Web" as one bullet. The decision tree from your own docs:
1. The **boundary work (events + protocol + de-NSColor + Codable `FindMatch` + de-Combine the 3 core `ObservableObject`s) is needed either way** — Swift-portable-core *or* Rust. Do it regardless. It's also what makes the diagnostic-JSON window, sessions-as-snapshots, and remote mode fall out naturally.
2. Only *then* is "Rust core vs Swift-portable core" a real fork, and only if **Linux + Web are committed, not aspirational** (the still-open deciding question in `STATE_ARCHITECTURE §2`). Don't start a Rust rewrite to satisfy a hypothetical.
3. **Never rewrite the Mac GUI** (already your conclusion — keep it).

### Defer / de-scope
- **Custom terminal emulator → don't.** Either (a) defer the in-app terminal until the stream channel exists and then use xterm.js in the WebView host you already run, or (b) ship "Open in Terminal.app" (already done, `SidebarView.swift:654`) as the 90%-value stopgap. Building a VT emulator from scratch is the worst effort/value trade on the list.
- **Profiling tooling → use Instruments + os_signpost**, don't build a profiler.
- **Per-tab memory in status bar → drop or reframe** as total RSS + WebKit-helpers line. Per-tab is dishonest for WebView tabs (your own BACKLOG memory notes prove it).
- **HTML live rendering → defer** until the JS/network/file-access policy is written down. Default-deny JS.
- **Session *types* (Project/CodeReview/Pipeline/Metrics) → defer** until plain sessions + session independence are solid. These are presets on top of the session model; building them before the model is fully session-independent (the list's own "everything in a session needs its own state" item, which is *not* done — Phase 1 is "one DocumentModel slot," per `SessionsAppCoordinator`) is premature. **Session independence must land before session types.**

### One sequencing inversion to call out explicitly
The list has **"session independence"** and **"session types"** as peers, and **"terminal"** marked "a must." The real order is:
1. Session independence (per-session DocumentModel — currently a singleton; this is the Phase-2 work the session docs describe).
2. Event/stream channel.
3. *Then* terminal (as a per-session stream-topic consumer) and session types (as presets).

Building the terminal "a must" first means building it into the singleton model and then rebuilding it twice.

---

## Bottom line

- **Riskiest items:** custom terminal (build-your-own emulator + collides with the unbuilt stream channel + sandbox/security blast radius), permissive HTML rendering (security-model drift), scripting-as-a-third-vocabulary (drift you already have between ScriptRunner and MCP), and naive archive expansion (zip-bomb/zip-slip). The core split itself isn't risky to *do* but is risky to *under-sequence*.
- **Biggest omissions:** the server→client **event/stream channel** (your own audit's "biggest gap," and a prerequisite for half the list), off-main work as a *correctness* rule, single-writer/multi-client ownership, file-watch-as-a-port, persisted-state versioning policy, and tooltips/a11y as one system.
- **Sequencing:** fix the trust bugs + crash-recovery (debounced live snapshot) now; build the event channel + unify the verb catalog before the heavy live features; land session *independence* before session *types* and before the terminal; treat "core split" as a gated multi-step program, not a bullet; and only fork to Rust if Linux+Web are actually committed.

If you want, I can turn the bug cluster into a triaged punch-list with the specific files/lines for each (e.g. the shoulder-button 4/5/6 wiring, the close-one-tab-reopens-two path, the live-snapshot debounce hook), or draft the event/stream-channel interface against the existing `MCPServer`/`AutomationHost` types.