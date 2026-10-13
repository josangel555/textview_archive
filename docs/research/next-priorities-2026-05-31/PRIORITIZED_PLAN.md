Confirmed the key facts: `DocumentState` already has `.loading(URL)`/`.error` cases, and the only `makeSnapshot`/`replaceSnapshot` call sites are the terminate-flush and detach paths (lines 193-194, 319-320) — no incremental driver. The triage holds. Writing the plan now.

# MarkdownViewer — Pre-PoC Implementation Plan

## 1. Executive Summary

The through-line: **stop accreting session/runtime state on the `@MainActor` `DocumentModel` god-object, and lift it into a `Sendable` ViewerCore value type — even while everything stays Swift.** The expensive, irreversible cost is untangling SwiftUI-coupled state *after* the fact; the owner has confirmed we pay that now. Almost every "live" feature on the list (disk-staleness dots, metrics, terminal output, walkthrough flash) is a *consumer* of two missing core primitives — an **observability/event sink** and an **authoritative session-state value type** — so those primitives are foundations, not features.

Foundational ordering: build (0a) the observability sink and (0b) the session-runtime value type + incremental/debounced persistence first; they unblock the widest set of downstream items and they are the genuine one-way doors. The crash-recovery bug and the "highest-leverage UX" perf work are not separate efforts — they fall out of doing 0b correctly. `DocumentState.{loading,error}` and the async-open machinery are **already shipped** — that BACKLOG item is stale; document it, don't rebuild it.

Biggest one-way-door risks, in order: (1) session/runtime state staying welded to `DocumentModel`; (2) the observability event-record shape, once subsystems emit against it and it eventually crosses the Rust FFI; (3) the command vocabulary forking (a third scripting surface vs. growing `AutomationHost`); (4) the terminal backend reaching straight into `Process` from the WKWebView host instead of sitting behind a swappable `TerminalBackend` protocol. Everything else is a two-way door — fix in place.

A standing constraint governs *how* every item ships, not just *what*: subscribe to **narrow `@Published` streams with equality guards + debounce**, never `model.objectWillChange` wholesale (the REPUB-1 / republish-amplification trap is the single most repeated regression in this codebase).

---

## 2. Dependency DAG

```
                          ┌───────────────────────────────────────────────┐
   T0 FOUNDATIONS         │ 0a. ObservabilitySink (ViewerCore, FFI-shaped) │◄── root, unblocks all instrumentation
                          └───────────────┬───────────────────────────────┘
                                          │
   ┌──────────────────────────────────────┼─────────────────────────────────────────┐
   │                                       │                                          │
   ▼                                       ▼                                          ▼
 logs UI ──► metrics UI ──► status-bar    os_signpost spans          diagnostic window (debug/flag-gated,
 (T2)        (T2)           memory (T2)    (T1, independent)          NEVER via MCP)  (T2)

                          ┌───────────────────────────────────────────────┐
                          │ 0b. SessionRuntimeState value type (ViewerCore)│◄── promote SessionSnapshot to
                          │     + incremental/debounced persistence        │    authoritative runtime model
                          └───┬───────────────┬───────────────┬───────────┘
                              │               │               │
        ┌─────────────────────┘               │               └──────────────────────────┐
        ▼                                      ▼                                          ▼
 crash-recovery (free,         session independence (R1–R3,        per-session PanelLayoutStore
 same debounced trigger)       per-session DocumentModel) ──┐      (global UserDefaults → per-session)
        │                              │                    │              │
        │                              ▼                    ▼              ▼
        │                       open/move file →     pin/follow (per-    SESSION TYPES
        │                       new session (clean    session variant)   (Project/CodeReview/…)
        │                       form needs Phase-2)                       HARD-BLOCKED on per-session panel state
        │
        └─► (tab dedup fix, item below, MUST land before incremental save amplifies it)

   ┌───────────────────────────────────────────────┐
   │ 0c. Tooltip model: HelpInfo + HelpSink         │──► status-bar description region ──┐
   └───────────────────────────────────────────────┘                                    │
                                                                                         ▼
   ┌───────────────────────────────────────────────┐                          StatusBar.swift
   │ 0d. Per-tab disk-staleness signal (diskState)  │──► tab red-dot           (ONE layout pass:
   │     (generalize EditorBuffer.hasExternalEdit)  │──► status-bar "modified  description slot +
   └───────────────────────────────────────────────┘    in red" ─────────────►modified chip + dates)

   ┌───────────────────────────────────────────────┐
   │ DocumentState.{loading,error} — ALREADY SHIPPED│  (nothing blocks on it; remaining slivers only)
   └───────────────────────────────────────────────┘

   ViewMode policy (Bug 3) ──► SQLite category-override (Bug 2) ──► SQLite UI-scale (Bug 1)
   (settle picker first)       (separate "Open as…" menu)          (orthogonal scale-plumb)

   AutomationHost + MCP tool catalog = the one command bus ──► scripting/customization, deeplinks (later)
   TerminalBackend protocol (ViewerCore, reuse ProcessRunner) ──► xterm.js frontend adapter (swappable)
```

**Coupling to flag:** TOOLTIPS (0c), DISK-STALENESS (0d), and file-stats dates all add a region to `StatusBar.swift`. Do **one** StatusBar layout pass that reserves: a hover-description slot, a "modified on disk" red chip, and Created/Modified date metrics. Two uncoordinated edits will conflict.

---

## 3. Tiered Plan

### Tier 0 — Foundations (build first; these are the one-way doors)

| # | What | Size | Key file(s) | Blocking dep |
|---|------|------|-------------|--------------|
| 0a | **ObservabilitySink** — Foundation-only core actor; flat `Sendable` `ObsEvent {tsNanos, level, subsystem, message, [String:String] fields}` + counter/gauge; bounded ring buffer; optional `os_log` fan-out; global install point. Migrate `LSPLog`, `MCPServer.logger`, `GrammarLoader`, bare `print`s onto it. | S–M | new `ViewerCore/Observability/*`; `LSPWorkspaceOverrides.swift`, `MCPServer.swift`, `GrammarLoader.swift` | none (root) |
| 0b | **SessionRuntimeState value type** — promote `SessionSnapshot` to the authoritative runtime model (reuse `TabsState`, key per-tab dicts into it); make `DocumentModel` a *projection*. Then drive **incremental/debounced (500 ms) persistence** off narrow `@Published` streams (`$tabs`, `sidebar.$rootURL`, zoom/wrap/theme) → `makeSnapshot()` → existing coalescing `enqueueSave`. Fixes crash-recovery as a side effect. | M (trigger) / L (full R1–R3 split) | `SessionState.swift:104`, `SessionsAppCoordinator.swift:193-194,319-320`, `SessionStore.swift:173-208`, `SessionSnapshot.swift` | tab-dedup fix (Tier 1) lands first |
| 0c | **Tooltip model** — `HelpInfo {title, description}` (ViewerKit, Equatable/Sendable) + `HelpSink` (separate `ObservableObject`, **not** on DocumentModel) + `.helpInfo(_:)` modifier driving native `.help(title)` + `.onHover`→sink. Also feeds a11y label/hint. | M (model S; 26-file migration is the bulk — good fan-out) | new ViewerKit type; new `ViewerUI/HelpSink.swift`; ~26 call-site files; `StatusBar.swift` | none |
| 0d | **Per-tab disk-staleness signal** — generalize `EditorBuffer.hasExternalEdit`/`hasUnknownDiskState` to all loaded tabs (baseline `(mtime,size)` already on `TextFile`); add `diskState {fresh, staleVsDisk, deleted}`; change watcher policy from silent-reload to flag-and-offer (behind a pref). | M (L if watching all background tabs) | `EditorBuffer.swift:102-138`, `DocumentModel.swift:2102-2205`, `FileWatcher.swift`, `Tab.swift` | none (reuses watcher) |

> **Already done — do NOT rebuild:** `DocumentState.{loading,error}` + `LoadingStateView`/`ErrorView` + off-main `materializeIfNeeded`/`openLargeFileOffMain` (commits `b422ee2`/`af5bef0`). Action: strike the "off-main file loading" BACKLOG item; replace with the narrow follow-up (watcher-reload + view-mode-recovery reads still sync on main).

### Tier 1 — Quick-win bugs (high trust/day, contained, mostly S)

Ordered by leverage (correctness-of-foundation first):

| # | What | Size | Key file(s) | Dep |
|---|------|------|-------------|-----|
| 1 | **Tab-dedup symlink normalization** — `openOrReveal` compares raw `URL ==`; resolve `standardizedFileURL.resolvingSymlinksInPath()` so `/var`↔`/private/var` doesn't spawn a 2nd tab. Fixes "close 1 tab, reopen shows 2". | S | `TabsState.swift:127` | — (must precede 0b) |
| 2 | **"Open in New Session" stray GoTo prompt** — drop the gate-arming branch in `openFolder(forceNew:)`; no caller needs it (`+` uses `requestNewSessionViaGoTo`). Add coordinator-level regression test. | S | `SessionsAppCoordinator.swift:109-115` | — |
| 3 | **Source mode offered for binaries** — gate `.source` out of `availableModes` for binary/unknown; fix `defaultMode` → `.hex`; remove dead `setCurrentViewMode(.source)` reload branch. | S/M | `ViewMode.swift:21-49`, `DocumentModel.swift:2585` | settle before Bug 2 picker |
| 4 | **Shoulder buttons 4/5/6 "do nothing"** — sections self-gate on empty data and discard the forced-`.shown` override; render placeholders ("Not a git repo", etc.) when `override == .shown`. | M | `GitPanelSection.swift:24`, `ClaudeTimelineSection.swift:24`, `SidebarView.swift:988` | after item 5 (shared presence-inputs) |
| 5 | **Row-count tool window can't be dismissed** — `PluginSidebarSections` mounted unconditionally; gate on `panelLayout.isVisible(.pluginSections,…)`. Lift presence-inputs into a computed prop (shared with item 4). | S | `SidebarView.swift:122-124` | — |
| 6 | **Right-click tab → Refresh** — `public refreshTab(at:)` wrapping `applyReload`, dirty-buffer prompt reuse; menu item. Clears 0d's flag. | S | `DocumentModel.swift:2149-2187`, `TabBar.swift:104` | reuses reload path |

### Tier 2 — Medium features

Ordered by leverage:

| # | What | Size | Key file(s) | Dep |
|---|------|------|-------------|-----|
| 7 | **Status-bar file stats** — Created/Modified dates (today-relative), stale-Modified-in-red. **Same StatusBar layout pass as 0c+0d.** | S (dates) / M (red, needs 0d) | `StatusBar.swift:167-191`, reuse `MetadataPanel` fmt | 0d |
| 8 | **Recently-opened tool window (global)** — add `recentlyOpened` to `SidebarPanelKind` (fresh stable `appStorageKey`), `RecentlyOpenedSection` reading `model.recents`. Per-session-filtered variant is trivial *after* 0b. | S | `SidebarPanelKind.swift`, `SidebarPanelRegistry.swift`, new section view | global: none; scoped: 0b |
| 9 | **Pin / follow-active-tab** — `sidebarFollowsActiveTab` flag + hook on selection change → `revealInSidebar` (select+expand only, no re-root). Global ships now; per-session rides 0b. | S | `DocumentModel.swift:395-438`, `SidebarView.swift:478-494` | global: none |
| 10 | **SQLite category-override + "Open as…" menu** — per-tab `categoryOverride: FileCategory?` (additive/optional in snapshot) + 16-byte magic sniff in `binaryFile` fallback. Fixes `mydb.db.bak`. Separate menu (Bug 3 removed the mode slot). | M (sniff) / L (full override + persistence) | `DocumentController.swift:94`, `Tab.swift`, `FileCategory.swift`, `ModeBar` | Bug 3 |
| 11 | **SQLite UI-scale plumbing** — thread `uiScale` through `MediaPreviewView`→`SQLiteBrowserView`→`ResultTableView`; multiply ~10 literals + column-width constants. Keep width helpers pure (param, not global). | M | `MediaPreviewView.swift:17-29`, `SQLiteBrowserView.swift`, `ContentView.swift:317-326` | — |
| 12 | **Tab UX cluster** — scroll-to-selected (S, `ScrollViewReader`), shrink-then-overflow compact mode (M, GeometryReader width budget), blue dirty dot already done (pin to literal blue if wanted), red disk dot (consumes 0d). | S–M each | `TabBar.swift`, `SessionTabBar.swift` | red dot ← 0d |
| 13 | **Move ModeBar into content pane** — relocate from outer VStack to top of center column in `bodyRow`. **Compositor-fragile**: follow the proven bottom-rail sibling pattern (fixed-height bar + `content` stays `.frame(maxWidth/Height:.infinity)`). VM-test only. | S–M | `ContentView.swift:69-73,203` | — |
| 14 | **Git file-history window** — core: `fileHistory(%H)`, `diff(from:to:path:)` (one method covers vs-current + two-commit). UI: master-detail `Table` + reuse `DiffView`; Cmd-click 2-commit selection. Decide window-vs-tab up front. | M | `GitClient.swift`, new `FileHistoryView`, reuse `DiffView`/`SettingsWindowController` | new range-diff method |
| 15 | **Folder stats slide-down** — core `repoStats(scope:)` aggregation (rev-list count, shortlog, numstat, ext histogram); inline disclosure under `filesHeader`. Off-main + cache + HEAD-invalidate; decide folder-vs-repo scope first. No charts lib. | M | `GitClient.swift`, `SidebarView.swift:388,482` | scope decision |
| 16 | **Walkthrough `flash` + `close` verbs** — additive to action engine; `flash` S; `close` S–M (destructive-verb policy: never close dirty without prompt; forbid from untrusted transports). Consider schema `v2` to avoid hard-reject on old binaries. | S each | `WalkthroughScript.swift:105-186`, `WalkthroughOverlay.swift`, `WalkthroughLoader.swift:129` | close ← verb policy |
| 17 | **Diagnostic window** — debug-build / `MDV_ENABLE_DIAGNOSTICS=1` only. Curated `diagnosticSnapshot()` (NOT auto-`Codable`), temp-files, fds (`proc_pidinfo`), live subprocesses. **NEVER** in MCP catalog; 0600 artifacts; redact content + consider redacting abs paths. | M | new window; `DiagnosticDump.swift`, `Diagnostics.swift` | 0a (state dump of 0b's value type is the portable part) |

### Tier 3 — Large + decision-gated

| # | What | Size | Key file(s) | Dep |
|---|------|------|-------------|-----|
| 18 | **Session independence (R1–R3)** — extract session-scoped clusters off `DocumentModel`; per-session `SessionState` children + per-session `PanelLayoutStore`; re-point ~40 `@ObservedObject` sites. Fold in latent fixes: `sidebarExpandedPaths`/`includeHidden`/`splitURL` hard-coded `nil`. | L | `DocumentModel.swift`, `SessionState.swift`, `SessionSnapshot.swift`, `PanelLayoutStore.swift` | 0b |
| 19 | **Open/Move file → new session** — snapshot-injection path (`openTabs:[TabSnapshot]`); "move" round-trips through persist/hydrate on Phase-1, clean only on Phase-2. | M / M–L | `SessionsAppCoordinator.swift`, `SessionSnapshot.swift`, `TabBar.swift` | clean form ← 18 |
| 20 | **Per-session panel-layout storage** — global `UserDefaults` → per-session blob. Prereq for session types to mean anything. | M | `PanelLayoutStore.swift`, `PanelEdgeAssignment.swift`, `PanelVisibilityOverrides.swift` | 18 |
| 21 | **Session TYPES** — `SessionKind` core enum w/ per-kind default panel layout + initial tabs; additive-optional `sessionType` in snapshot; seed-once (not live-override). | M (on top of 18+20) | `SessionSnapshot.swift`, `SidebarPanelKind.swift`, new `SessionType` | **hard-blocked on 18 + 20** |
| 22 | **Terminal tool window (xterm.js)** — `TerminalBackend` protocol in ViewerCore (spawn/write/output-stream/resize/kill), reuse `ProcessRunner`; xterm.js as a *frontend adapter* in ViewerUI; backend swappable for the parallel native-PTY effort. Terminal session state ∈ 0b. | L | new `ViewerCore/Terminal/TerminalBackend.swift`, `ProcessRunner.swift`, new WKWebView adapter, `JSStringEmbedding.swift` | xterm.js dep approval + bundle-budget check + threat model |

### PoC-territory (out of scope this round)

Rust core / FFI PoC; Linux port; Web UI; TUI front-end; multi-window/tear-off; native PTY terminal (separate parallel effort); walkthrough URL-scheme deeplink handler (de-scoped, keep seam dormant); compressed-as-folder VFS; live HTML rendering (both security-gated — see §4).

---

## 4. Decisions the Owner Must Make

Genuine remaining forks only (terminal/session-core/observability/diagnostic/deeplinks already settled above):

1. **Instrumentation scope — how far past logs?**
   - *Trade-off:* The sink (0a) + logs UI + `os_signpost` spans are cheap, portable, high-value. Metrics UI is M and reuses the same chassis. **Per-tab memory cannot be made honest** — WKWebView splits RSS across shared XPC helpers (WebContent/GPU/Networking); a "per-tab: 47 MB" number is fabricated and a senior user will catch it. A bespoke in-app profiler is pure over-build vs. Instruments.
   - *Recommendation:* Ship 0a + logs UI + signpost spans + metrics UI. For memory, show **App footprint (`task_info phys_footprint`) + a separate "WebKit helpers" line + a per-tab content-byte proxy with a tooltip** — never a fabricated per-tab RSS. Skip the in-app profiler.

2. **Compressed-files-as-folder — build now, and how?** (security-gated)
   - *Trade-off:* Nice feature, but the naive sidebar-trick implementation is a security hole: zip-bomb amplification, zip-slip (`../` entries), symlink entries, eager extract-to-tmp. Done right it's a *virtual filesystem* over the archive.
   - *Recommendation:* **Defer to PoC-territory.** If pulled forward: build as an `ArchiveEntrySource` protocol the sidebar tree consumes like a real dir (reuse `FileTreeService` seam), stream entries lazily (never extract to disk), and treat it as a security feature — entry-count cap, expanded-size cap, reject absolute/`..` paths, no symlink follow.

3. **HTML rendering policy** (security-gated)
   - *Trade-off:* "We already have WKWebView" makes it look free, but rendering arbitrary `.html` with JS + remote subresources + `file://` access blows through `HTMLSanitizer`/CSP and is an XSS/local-file-read surface. Permissive-then-clamp is a breaking change once users rely on local JS dashboards.
   - *Recommendation:* If built, **default-deny JS, no remote loads, no `file://` access**, route through existing `HTMLSanitizer`; JS opt-in per-tab only. Write the policy *before* shipping. Otherwise defer.

4. **Session-types scope vs. ordering**
   - *Trade-off:* Session types are presets on top of per-session panel state, which doesn't exist (panel layout is global `UserDefaults`). Building types first means building per-session panel storage first anyway.
   - *Recommendation:* **Session independence (18) → per-session panel storage (20) → types (21).** Don't ship types before independence; they're meaningless and you'd build the foundation under duress.

5. **`SessionSnapshot` zoom/wrap/theme: per-session or global?** (schema fork — resolve before R3)
   - *Trade-off:* Snapshot persists these per-session today (`SessionSnapshot.swift:56-58`), but the design doc rules them **global** (`§1.4`). Conflict must resolve before the one-way schema settles.
   - *Recommendation:* **Per-session override with global fallback** (keep the fields, add a "use-global" sentinel) — preserves the existing on-disk data and gives users the more flexible behavior. Whichever you pick, decide before per-session panel state ships, because `<uuid>.json` files accrue immediately.

6. **Git file-history: separate window or in-app tab?**
   - *Trade-off:* App is single-window today; a standalone `NSWindow` (Settings proves the pattern) means you own its lifecycle + it won't participate in session save/restore. An in-app tab (like `showCommit`) is lower-friction and session-aware.
   - *Recommendation:* **In-app tab** unless you specifically want it to float over other sessions. Retrofitting window↔tab later is annoying — pick once.

7. **Walkthrough verb schema versioning**
   - *Trade-off:* Adding `flash`/`close` to `v1` means an old binary hard-rejects the whole script (unknown `kind` fails decode). No version negotiation exists.
   - *Recommendation:* **Bump to `textview.walkthrough/v2`** and implement the doc's `UnsupportedSchemaError` + multi-version decode now, while you're adding verbs — cheaper than a migration later.

---

## 5. One-Way-Door Guardrails

Build it **this** way now so the split stays open:

1. **State definition lives in core, not SwiftUI.** A front-end may render and mutate session state; it must never *define* it. `SessionRuntimeState` is the authoritative value type; `DocumentModel` is a projection. Litmus test: a live session round-trips through the core value type with **zero loss** (close mid-session → reopen byte-identical).
2. **Observability event record is FFI-shaped from day one:** flat, value-typed, `Sendable`, primitives + `[String:String]` only — **no Foundation/AppKit types, no closures in the payload, paths as `String` not `URL`.** Changing this later = touching every emit site + the eventual RPC schema.
3. **One command bus.** Scripting, customization, deeplinks, walkthrough steps, MCP tools all funnel through `AutomationHost` + the tool catalog (the proto-RPC IDL). **Do not fork** a JS-bridge / AppleScript / bespoke-DSL surface. Push verb *semantics* down into core handlers operating on the session value type.
4. **Terminal behind `TerminalBackend` (ViewerCore), reusing `ProcessRunner`.** xterm.js is a *frontend adapter*; the PTY/process lifecycle never lives in the WKWebView coordinator. Swappability test: the parallel native-PTY effort drops in with zero changes to the xterm.js adapter.
5. **No republish amplification.** Every new subscription uses **narrow `@Published` streams + equality guard + debounce**, never `model.objectWillChange` wholesale. The observability sink and the autosave trigger are the two highest-risk spots; add a republish-count assertion (existing `*RepublishInvariantTests` pattern) proving a keystroke doesn't fire a snapshot/metric.
6. **All new persisted shapes versioned + additive-optional** (the `SessionSnapshot` discipline), and the downgrade guard preserved — old builds must truncate-not-corrupt newer files.
7. **Diagnostic state and the log buffer never cross the MCP host.** Owner-only, in-memory, never auto-persisted, content (and ideally abs paths) redacted; the MCP server still has no auth/audit/consent — do not widen the exfil surface through it.

---

## 6. Open Questions / Cut Lines

- **Truncated diagnostic-window bullet** ("DocumentModel JSON / temp files / open fds / ports"): "open ports" is underspecified and probably wrong-scoped — a *viewer* shouldn't have listening sockets, and system-wide port enumeration needs entitlements you don't want. **Cut "ports" to "fds + temp files we own"** (`proc_pidinfo PROC_PIDLISTFDS` + per-user tmpdir sweep). Confirm.
- **Background-tab disk-watching (0d):** watch *all* open tabs (N fds, M→L) or single-active-watcher + on-focus/tab-switch stat sweep (cheaper, slightly stale)? Recommend the **stat sweep** unless real-time background staleness is required.
- **Disk-staleness policy flip (0d):** stop silently auto-reloading clean tabs (flag instead) *reverses* the Phase-4 "tail-like flash on change" intent. Make it a **preference**, not a hard policy change — confirm the default (recommend: flag + offer reload, don't auto-reload).
- **Double-click session tab → "default to ~":** ambiguous — blank `Tab()`, home-rooted open, or GoTo prompt prefilled with `~`? Needs intent clarification before building (item deferred into Tier 2 tab/session work; not separately listed above).
- **Folder-stats scope (item 15):** repo-wide vs. sidebar-subdir — changes `-- <path>` threading on every core method. Decide before writing the aggregation.
- **`close` walkthrough verb on untrusted transports:** confirm it's forbidden from the file-drop channel and can never close a dirty tab without the standard prompt.
- **xterm.js (item 22):** dependency approval + a `scripts/check-bundle-size.sh` measurement against the 37 MB / 16 MB-exec caps + a terminal-specific threat model are all owed **before** any code — the embedded shell is an ACE surface inside the app's TCC context.