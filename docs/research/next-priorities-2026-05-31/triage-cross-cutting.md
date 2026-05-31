# Triage — cross-cutting

I have everything needed. Key confirmation: `Tab.isDirty` tracks **editor unsaved edits** only (set by `updateEditorText` from `buf.isDirty`), NOT disk-staleness. The watcher reloads clean tabs silently and only prompts dirty *editor* buffers — there is no "loaded copy is stale vs disk" indicator for read-only/source/rendered tabs, and the StatusBar explicitly lists git/modified as "Deferred". The disk-staleness signal the dump wants (tab red-dot + status-bar "modified in red") does not exist; only the editor-dirty accent dot does.

Now I'll write the analysis.

---

# Cross-Cutting Foundations Analysis

Verified against the code on `main` as of 2026-05-31. Module layering holds: pure logic in `ViewerCore`, `@MainActor` models in `ViewerUI`. All four foundations sit at different maturity levels — two are essentially greenfield (TOOLTIPS, DISK-STALENESS-as-signal), one is built-but-unfired (PERSISTENCE), one is already done and just needs documenting (LOADING/ERROR).

---

### TOOLTIPS — uniform (title, description) model + status-bar description sink

**Status today.** Purely ad-hoc `.help(...)` modifiers. 26 files carry them; representative sites: `Sources/ViewerUI/TabBar.swift:48,151,159,175,186`, `Sources/ViewerUI/SidebarView.swift:445,477,491,507,519`, `Sources/ViewerUI/MediaPreviewView.swift:134-167`, `Sources/ViewerUI/ContentView.swift:793,798,842`, `Sources/ViewerUI/Git/*` (every tab). Each `.help()` renders a single string as the native macOS tooltip — there is **no title/description split**, no central registry, and **no status-bar description sink**. I confirmed no centralized type exists: grep for `TooltipModel`/`StatusDescription`/`HelpProvider`/`hoverDescription`/`descriptionSink` across `Sources/ViewerUI/` returns nothing. The status bar (`Sources/ViewerUI/StatusBar.swift`) renders only path + document metrics; its own header comment (`StatusBar.swift:18`) lists everything else as "Deferred (need plumbing)". `.onHover` is used in 12 files but only for local visual state (button fade, row highlight) — never routed to a shared description.

**Root cause / gap.** No shared abstraction was ever introduced. Each call site hard-codes its help text inline, so (a) there's no single place to enforce "every interactive element has a (title, description)", (b) descriptions can't be surfaced anywhere except the OS tooltip bubble, and (c) the OS tooltip shows the *whole* string — there's no notion of a short title vs a long description.

**Fix/build sketch.**
- `ViewerKit`: a pure value type `HelpInfo { title: String; description: String }` (Foundation-only, trivially testable, Sendable).
- `ViewerUI`: a `@MainActor` `HelpSink: ObservableObject` with `@Published var hovered: HelpInfo?`, injected via `@EnvironmentObject` once at `ContentView` root. A `View.helpInfo(_:)` modifier attaches `.help(info.title)` (so the native bubble shows the **title**) **and** an `.onHover { hovering in sink.hovered = hovering ? info : nil }` to push the **description** to the sink.
- `StatusBar` gains a trailing/secondary region bound to `sink.hovered?.description`, shown when non-nil (falling back to the existing metrics when nil). The status bar already re-renders cheaply per `@Published` tick, so this is additive.
- Migration is mechanical: `.help("Sort folder contents")` → `.helpInfo(.init(title: "Sort", description: "Sort folder contents by name, date, or kind"))`. ~26 files, but each edit is independent and pattern-identical — good multi-agent fan-out candidate (one agent per file cluster).

**Size: M.** The model + sink + modifier is S (~half a day). The breadth of the call-site migration (26 files, dozens of buttons) pushes it to M. No new dependency.

**Dependencies.** None hard. Reuses the existing `StatusBar` as the description sink — but note the StatusBar interaction below.

**Risk/one-way-door.** Low. One real concern: `.onHover` fires on the SwiftUI render thread and writing `sink.hovered` republishes `StatusBar` on every hover-enter/leave across the whole UI. Per the project's own LESSONS ("republish forwarding amplifies every tick"), the sink must be a **separate** `ObservableObject` from `DocumentModel` (not a `@Published` on the god-object) and must dedupe on equal value, or hovering the sidebar will re-render unrelated views. Make `HelpInfo: Equatable` and guard the setter. Not a one-way door — the modifier indirection means the sink can be swapped later.

---

### DISK-CHANGE DETECTION — one "loaded copy is stale vs disk" signal feeding tab red-dot + status-bar "modified in red"

**Status today.** The *mechanism* substantially exists but is wired for a **different purpose** than the dump wants, and the UI signal the dump asks for does not exist.

- Single-file watcher: `Sources/ViewerCore/FileWatcher.swift` — `DispatchSource` fd watch (`.write/.extend/.rename/.delete`), debounced (`FileWatcher.swift:161`), reattach-on-atomic-rename with backoff (`reattachSoon`, `:198`), `onLost` exhaustion callback. Solid.
- Folder watcher: `Sources/ViewerCore/FolderWatcher.swift` (FSEvents, for the sidebar tree).
- Wiring: `DocumentModel.startWatchingCurrentFile()` (`DocumentModel.swift:2189`) binds **one** watcher to the **currently-selected tab's URL only** (`:2192` idempotency, `:2200` handler → `reloadCurrentFile(matching:)`).
- Staleness fingerprint exists: `EditorBuffer.hasExternalEdit(currentMTime:currentSize:)` and `hasUnknownDiskState(...)` (`Sources/ViewerCore/EditorBuffer.swift:102,129`) compare cached `(mtime, size)` against fresh stat. This is the canonical "stale vs disk" check.

**The gap.** On a watcher fire, `reloadCurrentFile(matching:)` (`DocumentModel.swift:2102`) **silently reloads** clean tabs and only raises a conflict prompt when the tab has an **unsaved editor buffer** (`:2107` gates on `tab.isDirty`). So:
1. There is **no persistent "stale" indicator** for read-only / source / rendered tabs — they just refresh.
2. `Tab.isDirty` (`Sources/ViewerCore/Tab.swift:15`) means **"editor buffer has unsaved edits"**, NOT "disk copy is stale". The TabBar accent dot (`TabBar.swift:143-153`, `.help("Unsaved changes")`) is wired to that. The dump's *red-dot = stale-vs-disk* signal is a different concept entirely and is absent.
3. The watcher only covers the **focused** tab. Background tabs get no staleness tracking at all — switching away pauses, switching back rebinds (`startWatchingCurrentFile` on every close/select).
4. StatusBar shows nothing for modified/stale (`StatusBar.swift:18` "Deferred").

**Fix/build sketch.** Introduce one staleness signal, computed from the existing fingerprint primitive, that both UIs read:
- Add a `DocumentState`-adjacent or per-tab `diskState: enum { fresh, staleVsDisk, deletedOnDisk }`. Compute it in the watcher handler using `EditorBuffer.hasExternalEdit` / `hasUnknownDiskState` logic generalized to non-editor tabs (capture `(mtime,size)` at load time for *every* loaded tab, not just editor buffers — today only `EditorBuffer` and `TextFileLoader` capture it; `TextFile` already carries `modifiedTime`/`byteCount` per `TextFileLoader.swift:185,198`, so the baseline is essentially already there).
- Change the watcher handler policy: instead of "reload clean tabs silently", set `diskState = .staleVsDisk` and let the user opt into reload (or keep auto-reload as a preference). Wire `onLost`/`.delete` → `.deletedOnDisk`.
- TabBar dot: render a **distinct red dot** for `.staleVsDisk` vs the existing accent dot for editor-dirty (they're orthogonal — a file can be both edited-by-you and changed-on-disk).
- StatusBar: a `.foregroundStyle(.red)` "Modified on disk" chip when `diskState == .staleVsDisk`. Same `@Published` channel both read.
- To cover **background tabs**, either keep per-tab watchers (fd cost — there's already an `O_CLOEXEC` fd-leak fix at `FileWatcher.swift:113`, so multiplying watchers multiplies fds) or piggyback on the existing FSEvents `FolderWatcher` for tabs under the open root and fall back to per-tab `FileWatcher` for out-of-tree tabs.

**Size: M.** The fingerprint primitive and watcher exist; the work is (a) generalizing the baseline capture to all loaded tabs, (b) the `diskState` enum + republish plumbing, (c) two small UI renderers, (d) the policy decision on auto-reload-vs-flag. The background-tab coverage decision can push it to L if you want every tab watched.

**Dependencies.** Reuses `EditorBuffer.hasExternalEdit`/`hasUnknownDiskState` (don't reimplement). The TabBar red-dot is purely additive to the existing dot. The StatusBar "modified in red" chip **depends on the StatusBar staying the description/metrics surface** — coordinate with TOOLTIPS, which also wants to add a region there.

**Risk/one-way-door.** Medium-low. The behavioral change "stop silently reloading clean tabs, flag instead" is user-visible and reverses Phase-4's "tail-like change flash" design intent (DESIGN.md §4 wanted live flash-on-change). Decide whether stale-flag *replaces* or *coexists with* auto-reload — make it a preference rather than a hard policy flip (one-way-door avoidance). Per-tab watcher fan-out is a resource concern (fds, reattach timers) but reversible.

---

### STATE PERSISTENCE MODEL — incremental/debounced save vs on-quit (crash-recovery + session independence)

**Status today.** The debounced-write *engine* is fully built and battle-tested, but **nothing fires it during a live session** — capture happens only on session-switch and on quit.

- Engine: `Sources/ViewerCore/Sessions/SessionStore.swift` — a single serial `writeQueue` (`:35`) with **per-URL coalescing** (`enqueueSave`/`enqueueSaveIndex`, `:151,173`; coalescing map `:50`), atomic writes via `JSONFileStore`, and `flushSync()` (`:189`) that drains to a fixpoint for terminate. The doc comment (`SessionStore.swift:14`) explicitly calls `enqueueSave` "debounces by URL". This is exactly the incremental-save substrate the dump wants.
- Snapshot capture: `SessionState.makeSnapshot()` (`Sources/ViewerUI/Sessions/SessionState.swift:104`) serializes tabs/sidebar root/selected index/zoom/wrap/theme.
- **The gap, verified by grep:** the only callers of `makeSnapshot()` + `replaceSnapshot()` are `LifecycleBridge.detach` (`SessionsAppCoordinator.swift:319`, on session switch) and `flushForTermination()` (`:191,193`, wired to `applicationWillTerminate` in `Sources/MarkdownViewer/main.swift:390-396`). There is **no** `objectWillChange` subscription, no `Timer`, no debounce timer, no per-mutation capture. `SessionState` *deliberately does not* forward `model.objectWillChange` (`SessionState.swift:62-78`, REPUB-1) — for good perf reasons, but the side effect is that **a live session's edits never reach disk until you switch away or quit cleanly.**

So a crash, a `SIGKILL`, or a force-quit between `bootstrap()` and `applicationWillTerminate` loses the entire session's tab/sidebar/zoom state — it restores from the bootstrap-time snapshot. That is the crash-recovery bug's root cause. The coalescing queue that would make incremental save cheap is sitting there unused for the live path.

**Fix/build sketch.** Feed the existing `enqueueSave` from live state changes, debounced:
- Add a debounced capture trigger in `SessionsAppCoordinator` (or a small dedicated `SessionAutosaveCoordinator`): subscribe — *with an equality guard and a debounce* — to the **specific** session-relevant publishers (tab list changes, selected index, sidebar root, zoom/wrap/theme), NOT the firehose `model.objectWillChange` (which fires per keystroke/git-poll/highlight-ready and would defeat the REPUB-1 decision). On a relevant change, `enqueueSave(active.makeSnapshot())`. Coalescing in `SessionStore` already collapses bursts to one disk write per URL.
- Because `enqueueSave` already coalesces and runs on a `.utility` serial queue off-main, the only new cost is `makeSnapshot()` (cheap — it reads tab URLs + scalars) plus a debounce timer. `flushSync()` on quit still guarantees the final write.
- This simultaneously gives **session independence**: each session's snapshot is its own `<uuid>.json` (already the case in `SessionStore.fileURL(for:)`), so incremental save means switching/closing a session never loses the other's in-flight state (today `detach` already captures, but a crash mid-session-A while session-B is detached loses A).

**Size: M.** The store, snapshot, atomic-write, and flush are all done. The work is the *trigger*: a debounced, equality-guarded subscription to the right subset of publishers — and the discipline to NOT just `sink` on `objectWillChange`. Designing the publisher subset to avoid the REPUB-1 amplification is the careful part; the mechanics are small.

**Dependencies.** None new — `SessionStore.enqueueSave` exists. Tests are the gating dependency: the project's `*RepublishInvariantTests` pattern (DESIGN.md, CLAUDE.md) must be extended so the autosave subscription doesn't reintroduce the very republish storm REPUB-1 killed. Add a republish-count assertion around a keystroke to prove autosave doesn't fire per-character.

**Risk/one-way-door.** Medium. The trap is subscribing too broadly: a naive `model.objectWillChange.sink { enqueueSave(...) }` would call `makeSnapshot()` on every keystroke and every git poll, which is both wasteful and the exact anti-pattern the codebase documents against. Not a one-way door (you can narrow the subscription later), but getting it wrong reintroduces a perf regression the team already paid to fix. Also: writing the live snapshot more often slightly raises the chance of persisting a *transiently bad* state (e.g. mid-folder-switch) — the existing `detach`/`switchSessionFaçade` ordering (`SessionsAppCoordinator.swift:250-279`) must be respected so autosave doesn't capture a half-swapped session.

---

### LOADING / ERROR STATES — shared `.loading`/`.error` DocumentState for perf + every async open

**Status today. This one is already built and uniformly applied** — it's the most mature of the four.

- `Sources/ViewerCore/DocumentController.swift:4` — `enum DocumentState { empty, loaded, binary, error(LoadFailure), preview, loading(URL) }`. `LoadFailure` carries `url` + `message` (`:21`). Equatable is case+identity, deliberately not deep (`:37`, perf).
- Async open already routes through `.loading`: `DocumentModel.materializeIfNeeded(at:)` (`DocumentModel.swift:2471`) and `appendLazyTab`/`openLazyTab` (`:2396,2002`) put the tab in `.loading(url)`, read off-main on a detached Task, and transition to `.loaded`/`.binary`/`.error` only if the tab is **still** `.loading` for the **same** URL (`:2038` identity guard — prevents a slow read clobbering a tab the user re-pointed). This is the staleness-guarded async pattern done right.
- UI renders all states uniformly: `ContentView.content` (`ContentView.swift:298-327`) switches on `model.currentState` → `EmptyStateView` / `LoadingStateView` / `loadedView` / `HexView` / `ErrorView` / preview. `LoadingStateView` (`:894`) even has the 100 ms spinner-delay-to-avoid-flash polish. `ErrorView` (`:946`) shows message + Reload + Reveal-in-Finder.
- The message mapping is centralized: `DocumentController.message(for:)` (`:122`) maps every `FileLoadError` case (not-found, not-readable, decoding, too-large with byte math, binary) to user copy.

**Root cause / gap.** Essentially none for the core contract — the shared enum + uniform rendering + async-open integration all exist. Minor gaps if you want more:
- `.error` has no retry/backoff or transient-vs-permanent distinction (it's a flat message + manual Reload button).
- `.loading` carries only the URL, no progress fraction (fine for current file sizes; would matter for a streaming/large-file future).
- `StatusBar.currentMetrics` returns `nil` for `.empty/.error/.loading` (`StatusBar.swift:132`) — correct, but means the status bar goes blank during load rather than showing "Loading…". Worth a one-line affordance if you're touching the StatusBar for the other two foundations anyway.

**Fix/build sketch.** No foundational build needed — it's done. If extending: thread a progress value into `.loading(URL, Progress?)` and a structured `LoadFailure.kind` for retry policy. Both are additive to the existing enum and would not disturb the rendering switch.

**Size: S** (already built; only optional polish remains).

**Dependencies.** It is itself the dependency the dump names: "used by perf + every async open" — and indeed `materializeIfNeeded`, `appendLazyTab`, `openLazyTab`, and `reload` all already consume it. Nothing downstream is blocked here; it's the foundation others can assume exists.

**Risk/one-way-door.** None. The Equatable-by-identity decision (`DocumentState.swift:37`, `Tab.swift:57`) is load-bearing for SwiftUI diff perf — any future change to `.loading`/`.error` payloads must preserve case-only/identity equality or it'll O(N)-compare file bytes on every tab diff. That's a constraint to respect, not a blocker.

---

## Dependency map — which foundations the four UI items share

```
                        ┌─────────────────────────────┐
                        │  StatusBar.swift (one view) │ ◀── shared sink/surface
                        └──────────┬─────────┬────────┘
                                   │         │
   TOOLTIPS ──────────────────────┘         └────────────────── DISK-STALENESS
   (description sink lives here)              (─ "modified in red" chip lives here)
        │                                              │
        │ HelpInfo (ViewerKit)                         │ EditorBuffer.hasExternalEdit /
        │ HelpSink (ViewerUI, separate OO)             │ hasUnknownDiskState (ViewerCore) ──┐
        ▼                                              ▼                                    │
   every .help() call site                    TabBar red-dot (≠ editor-dirty dot)          │
   (26 files)                                  + FileWatcher (single-file watch)            │
                                                                                            │
   PERSISTENCE ◀────────── SessionStore.enqueueSave coalescing queue (built, unfired) ◀────┘
   (incremental save)        │                          shares the (mtime,size) fingerprint
        │                    └── debounced subscription to session-relevant publishers
        ▼                        (NOT model.objectWillChange — REPUB-1)
   crash-recovery  +  session independence  (same trigger feeds both)

   LOADING/ERROR ── DocumentState enum (ViewerCore) ── ALREADY consumed by every async open
   (foundation other items assume; nothing blocks on it)
```

**Shared-foundation table:**

| Foundation | Shared primitive (exists?) | Downstream items it unblocks |
|---|---|---|
| TOOLTIPS | `HelpInfo` + `HelpSink` (must build) | Every button's tooltip; the status-bar description line; a11y label consistency |
| DISK-STALENESS | `EditorBuffer.hasExternalEdit`/`hasUnknownDiskState` + `FileWatcher` (built); `diskState` signal (build) | Tab red-dot **and** status-bar "modified in red" — **one signal feeds both** |
| PERSISTENCE | `SessionStore.enqueueSave` coalescing queue (built, **unfired** on live path) | Crash-recovery **and** session independence — **one debounced trigger feeds both** |
| LOADING/ERROR | `DocumentState.{loading,error}` (built + uniformly rendered) | Perf lazy-open, every async `materialize`/`appendLazyTab`/`reload` — **already wired** |

**Two cross-foundation couplings to note:**
1. **TOOLTIPS and DISK-STALENESS both want to add a region to `StatusBar.swift`.** Build them aware of each other — one StatusBar layout pass that reserves a description slot (tooltips) and a modified-state chip (staleness), rather than two conflicting edits. (Echoes the codebase's "MARK: feature-X (agent)" coexistence convention for overlapping files.)
2. **DISK-STALENESS and PERSISTENCE share the `(mtime, size)` fingerprint concept** (`EditorBuffer` / `TextFile.modifiedTime`). Capturing that baseline for all loaded tabs (needed for staleness) is also what lets a restored session detect "the file changed while we were quit" — so building staleness first makes the persistence-restore path more honest about stale tabs.

**Build-order recommendation:** LOADING/ERROR is already done (document it, don't rebuild). PERSISTENCE incremental-save is the highest-value one-time build (fixes a real data-loss bug, engine already exists, just needs a careful trigger). DISK-STALENESS is next (mechanism exists, needs the signal + UI). TOOLTIPS is the broadest mechanical change but lowest risk — good parallel/fan-out work that can land independently.