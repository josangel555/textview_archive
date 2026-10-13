# Triage — feat:walkthrough-statusbar-perf

Confirmed: no `WalkthroughCatalog`, `WalkthroughStore`, `WalkthroughHistory`, or completed-log persistence exists — `accepted/`/`rejected/` are only mentioned in comments, never implemented. And `markdownviewer://walkthrough` is NOT handled (the URL handler only has `open`/`search`). I have everything. Compiling the report.

# Walkthrough

### Walkthrough — step actions (flash / highlight / scroll / open / close)

**Status today.** A full action engine exists and is wired into a working UI player. The action verb set is defined as a tagged union in `Sources/ViewerCore/Walkthrough/WalkthroughScript.swift:105-186` — 12 verbs: `openFile`, `revealLine`, `highlightRange`, `showPopover`, `setView`, `splitFile`, `runDiff`, `awaitUser`, `addBookmark`, `revealInSidebar`, `openGitPanel`, `narrateOnly`. The engine (`WalkthroughEngine.swift:66-156`) walks steps and dispatches each action through a delegate; `WalkthroughPlayerImpl.swift:65-199` translates every verb into existing `DocumentModel` calls. Visual rendering (highlight stripe + popover) is in `WalkthroughOverlay.swift:66-101,114-256`.

Mapping the task's named actions to what's actually built:
- **scroll** → `revealLine` (`WalkthroughPlayerImpl.swift:80-85`, calls `model.scrollSource(toLine:)`). Built.
- **highlight** → `highlightRange` (`:87-104`, routes to `walkthroughBridge.requestHighlight`, rendered as a translucent stripe in `WalkthroughOverlay.swift:66-101`). Built; 4 styles (`focus/warn/info/agent`).
- **open** → `openFile` (`:71-78`, dedups to a tab-switch via `selectTab(forURL:)`). Built.
- **flash** → **does not exist.** No transient pulse/flash verb; the closest is the static `highlightRange` stripe, which persists until the next step's `willApplyStep` clears it (`WalkthroughPlayerImpl.swift:53-63`).
- **close** → **does not exist.** No verb closes a tab/panel/split. Steps clear their *own* transient overlays (popover/highlight) on the next step, but there is no `closeFile`/`closePanel`/`collapseSplit` action.

**Root cause / gap.** The verb taxonomy was frozen at 12 (BACKLOG.md:101-102 "step taxonomy (12 verbs)") and deliberately kept narrow ("Keep the surface narrow" — `WalkthroughScript.swift:190`). `flash` and `close` were simply never in scope. Adding them is additive within schema `v1` only if you accept that older app builds reject newer scripts (unknown `kind` hard-fails the whole script at decode — `WalkthroughScript.swift:149-154`).

**Fix/build sketch.**
- `flash`: add `case flash(FlashPayload)` (path?/line range/durationMs/style). Engine dispatch is unchanged. In `WalkthroughBridge` add a `flashNonce` + payload; in `WalkthroughOverlay` drive an opacity pulse keyed on the nonce with a `withAnimation` + auto-clear `Task.sleep`. Reuse the existing gutter line-math at `WalkthroughOverlay.swift:74-77`.
- `close`: add `case closeFile(path?)` / `closeSplit`. Map to existing model ops — there is already a close path (`confirmCloseIfDirty` at `EditorCoordinator.swift:501` and tab-close in `DocumentModel`). **Risk:** `close` is a destructive verb on a channel an external agent drives; gate it so it can never close a *dirty* tab without the standard prompt, and consider forbidding it entirely from the file-drop (untrusted) transport.

Every new verb must also be added to `WalkthroughLoader.pathsIn(_:)` (`WalkthroughLoader.swift:129-146`) — that switch is exhaustive, so the compiler forces it, which is the intended safety net.

**Size.** **S** per verb (flash ≈ S, close ≈ S–M because of the dirty-tab/destructive-verb policy decision). The dispatch/loader/encode/decode plumbing is boilerplate the existing switches force you through.

**Dependencies.** None new for `flash`. `close` depends on deciding the destructive-verb policy (see Walkthrough deeplink section — same threat surface).

**Risk/one-way-door.** Adding verbs to schema `v1` is *not* a clean one-way door: there's no version negotiation, so a `v1` script using `flash` silently fails to load on an older binary (whole-script reject). If verb churn is expected, bump to `textview.walkthrough/v2` and have the loader accept both — but the loader currently only knows `.v1` (`WalkthroughScript.swift:39-41`) and the design doc's promised `UnsupportedSchemaError` (WALKTHROUGH_DESIGN_v2.md:380) is **not implemented**.

---

### Walkthrough — versioning + management (catalog, history, saving, finding, discovery)

**Status today.** Almost nothing exists here. What's present:
- Schema discriminator: `WalkthroughScript.schema` with a single case `.v1` (`WalkthroughScript.swift:39-41`). Decoding enforces it via `Codable`. The design doc's migration policy + `UnsupportedSchemaError` (WALKTHROUGH_DESIGN_v2.md:377-380) is **unimplemented** — there's no `allCases` match, no unknown-version error, no migration path.
- A `WalkthroughDropTransport` (`WalkthroughDropTransport.swift`) that watches `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Walkthroughs/drop/` via FSEvents and delivers parsed scripts to a delegate.
- Script identity fields exist but are unused for management: `id`, `createdAt`, `author`, `estimatedDurationSec` (`WalkthroughScript.swift:19-28`). The doc comment claims `id` is "used for resume + completion log" (`:18`) — neither exists.

What does **not** exist (verified by grep — no symbols found):
- **No catalog / list:** no `WalkthroughCatalog`, `WalkthroughStore`, or `walkthrough.list()`. BACKLOG.md:102 claims "persistence (in-progress/completed log via store)" but there is **no such store in the source tree.** This BACKLOG line appears aspirational/stale.
- **No history / completion log:** nothing records that a walkthrough ran or finished.
- **No saving:** `accepted/`/`rejected/` dirs are referenced only in *comments* (`WalkthroughDropTransport.swift:14,296`; `WalkthroughLoader.swift:19-20`); the transport is explicitly "pure-read" and never moves files. The original JSON is never persisted by the app.
- **No discovery / finding UI:** the player has a per-script "Steps" menu (`WalkthroughPlayerView.swift:170-201`) but there is no "Walkthroughs" menu, no library picker, no list of available scripts. The only launch paths are the `--walkthrough PATH` CLI flag (`main.swift:294-320`) and the drop transport.
- **Critically, the drop transport is NOT wired into the app.** Grep for `WalkthroughDropTransport` in `Sources/MarkdownViewer` and `Sources/ViewerUI` returns nothing — it is constructed only in tests. So in the shipping app, the *only* way to start a walkthrough is the dev CLI flag. BACKLOG.md:567 corroborates: "Menus, NSServices, walkthrough wiring, MCP startup are all still [pending]".

**Root cause / gap.** v1 shipped the *engine + transport + player primitives* and stopped before the management layer. The transport was built and tested but never instantiated at launch (likely deliberately — it's an unauthenticated automation channel, see security note below). The `appendSteps`/`replaceFrom` mutation model and MCP tools (`walkthrough.list/publish/start`) are designed (WALKTHROUGH_DESIGN_v2.md:443-456, 572) but unbuilt.

**Fix/build sketch.**
1. **Catalog store** (ViewerCore): a `WalkthroughCatalog` backed by a `JSONFileStore` (the project already has `JSONFileStore`/`WorkspaceStore` patterns) writing under `…/Walkthroughs/library/<id>.json` + an index. On accept, *copy* the script in (atomic write to a new path — honor the user's "never clobber, write new versions" rule; `id` collision → suffix, don't overwrite).
2. **History/completion log:** append-only JSONL `…/Walkthroughs/history.jsonl` of `{id, startedAt, finishedAt, lastStepReached}`; write from `WalkthroughPlayerController.exit()`/`done` (`WalkthroughPlayerView.swift:284-291,345-347`).
3. **Discovery UI:** a `File ▸ Walkthroughs` menu (per WALKTHROUGH_DESIGN_v2.md:931) listing catalog entries → `controller.start(script)`.
4. **Versioning:** implement the doc's `UnsupportedSchemaError` + multi-version `SchemaVersion.allCases` decode in `WalkthroughLoader` so future schema bumps degrade gracefully instead of opaque decode failures.

**Size.** **L** as a whole. Breakdown: catalog store + history **M**; discovery menu **S**; wiring the drop transport into launch **S** (but blocked on a security decision); versioning/migration **S–M**.

**Dependencies.** Catalog/history depend on nothing new (reuse `JSONFileStore`). Discovery depends on the catalog. Wiring the drop transport depends on the env-gate security decision (below). Zero new external deps (design mandates this — WALKTHROUGH_DESIGN_v2.md:25).

**Risk/one-way-door.** The on-disk catalog/history schema is a persistence format — versioning it from day one avoids a migration later. Not a hard one-way door, but the file layout under `…/Walkthroughs/` is user-visible and worth getting right once.

---

### Walkthrough — deeplinks to launch walkthroughs (+ security surface)

**Status today.** A custom URL scheme **already exists and is registered**, but it does **not** handle walkthroughs:
- `Info.plist` declares scheme `markdownviewer` (`scripts/Info.plist:79-89`).
- `application(_:open:)` (`main.swift:327-342`) routes `markdownviewer://` URLs to `handleCustomURLScheme` (`:359-384`), which handles exactly two hosts: `open` (open a file) and `search`. There is **no `walkthrough` host.** The design doc explicitly planned `markdownviewer://walkthrough?id=...` (WALKTHROUGH_DESIGN_v2.md:931) — unbuilt.
- There is **no file-open association** for walkthrough JSON (no UTI in `CFBundleDocumentTypes`, `scripts/Info.plist:90-157`); a `.json` would just open as a source file.

The existing URL-scheme security model is solid and reusable: every path from the scheme is funneled through `URLSchemePolicy.containedPath` (`Sources/ViewerCore/Security/URLSchemePolicy.swift:33-61`), which expands `~`, standardizes, and rejects anything outside `$HOME` or the per-user temp dir — explicitly to defeat `markdownviewer://open?path=/etc/passwd` (documented threat model at `:3-32`, `main.swift:350-358`). The fallthrough also requires `isFileURL` to block `https://…/etc/passwd` (`main.swift:331-340`).

**Root cause / gap.** The deeplink-to-walkthrough verb was deferred with the rest of the management layer. The plumbing to add it is trivial; the *security* design is the real work.

**Fix/build sketch.** Add a `case "walkthrough":` arm in `handleCustomURLScheme` (`main.swift:366-383`). Two sub-shapes:
- `markdownviewer://walkthrough?path=…` → run `path` through `URLSchemePolicy.containedPath` (same as `open`), then `WalkthroughLoader.load(fileAt:requireRootHint: true)`, then `walkthroughController.start(...)`.
- `markdownviewer://walkthrough?id=…` → look up in the catalog (depends on the catalog existing — see management section).

**Size.** **S** for the URL parsing arm itself; **M** once you account for the security hardening it forces (see below). Depends on the catalog for the `?id=` form.

**Dependencies.** `?id=` form depends on the Walkthrough catalog store (management section). `?path=` form depends on nothing new.

**Risk/one-way-door — this is the dangerous one.** A walkthrough script is a *program*: it drives `openFile`, `addBookmark`, `splitFile`, `revealInSidebar`, `showGitLog`, etc. against the user's filesystem. A `markdownviewer://walkthrough?path=…` link is invokable from **any web page** via `<a href>` and **any local process** — the same RCE-class surface the URL-scheme threat model already calls out (`URLSchemePolicy.swift:6-13`). The existing mitigations are necessary but **not sufficient** for walkthroughs:
- `URLSchemePolicy.containedPath` only constrains *where the script file lives* — it does nothing about *what the script does once parsed.* A script located in `~` can still `openFile` arbitrary in-home paths and surface their contents (then reachable via MCP tools).
- The loader's `requireRootHint: true` + path-escape check (`WalkthroughLoader.swift:49-51,96-121`) is the right control, but it only confines step paths *under `rootHint`* — a malicious link could set `rootHint` to `~/.ssh` and the script would happily `openFile` private keys, all "contained."
- The drop transport defends this with an **explicit env-gate** (`TV_WALKTHROUGH_DROP`, default off — `WalkthroughDropTransport.swift:39-54,93-109`) precisely because it's "an unauthenticated automation channel." A URL-scheme launch is *even more exposed* (web-reachable) and currently has **no equivalent gate or user-confirmation step.**

Recommendation before shipping any `walkthrough` deeplink: require an interactive confirmation sheet ("Run walkthrough X from <source>? It will open files and modify bookmarks") on the URL-scheme path, and/or gate it behind the same env opt-in. Do **not** make the deeplink a silent auto-run. This is a security-review-gated, hard-to-walk-back decision.

---

# Status bar

### Status bar — file stats (Created / Modified dates, today-relative, stale-Modified in red)

**Status today.** The status bar (`Sources/ViewerUI/StatusBar.swift`) shows path, Ln/Col, Lines, Chars, Size, Indent, EOL, Encoding (`:37-65`) — but **no Created or Modified dates.** The class doc explicitly lists "file age" as deferred to "Phase 7 git module" (`:18-21`). Metrics come from the in-memory `TextFile` only (`:109-135`); there's no filesystem-date read on this path.

The data needed already exists nearby:
- `TextFile.modifiedTime: Date?` is captured at load (`TextFileLoader.swift:33`, `:185`) — this is the **loaded copy's** mtime baseline.
- `MetadataPanel.filesystemRows` already reads + formats `.modificationDate` and `.creationDate` (`MetadataPanel.swift:62-87`) with a `medium`/`short` `DateFormatter`. Reusable.

The **stale-Modified-in-red** requirement: the underlying disk-change primitive exists but is **not surfaced visually**. `EditorBuffer.hasExternalEdit(currentMTime:currentSize:)` (`EditorBuffer.swift:102`) detects divergence, but only for *dirty editor buffers*, and only to drive the conflict prompt (`DocumentModel.swift:2111-2118`). For read-only tabs, the file watcher reloads **silently** (`reloadCurrentFile(matching:)` → `applyReload` at `DocumentModel.swift:2102-2187`), so the loaded copy is never *stale* for long — but there is no indicator during the window, and no general "loaded mtime ≠ disk mtime" check for non-editor tabs.

**Important correction to the task's premise:** the "tab red-dot disk-change detection" it refers to **does not exist.** The tab dot at `TabBar.swift:143-153` is `tab.isDirty` filled with `Color.accentColor` (an *unsaved-edits* dot, blue/accent, not red, not disk-stale). There is no disk-stale indicator anywhere to "overlap" with — this would be net-new.

**Root cause / gap.** Dates were deferred; the stale-detection logic was built narrowly for the editor save-conflict flow and never generalized into a passive "your view is behind disk" signal.

**Fix/build sketch.**
1. **Created/Modified in the status bar:** add two metrics. Modified = `TextFile.modifiedTime` (already in memory, zero syscall). Created has no in-memory home — needs a `.creationDate` stat. To stay off the body hot path, do what `StatusBar` already does for preview size: a `(url, mtime)`-keyed cache with a short TTL (mirror `cachedFileSize`/`previewSizeCache` at `:167-191`). Format with a today-relative formatter (time-only when `Calendar.isDateInToday`, else date+time) — small helper, can reuse `MetadataPanel.dateFmt` style.
2. **Stale "Modified" in red:** compare `TextFile.modifiedTime` (loaded baseline) against a fresh stat of the disk mtime. If they differ and the in-memory copy is older → render the Modified value red. Generalize `EditorBuffer.hasExternalEdit` into a tab-agnostic check. To avoid a stat per body re-eval (which fires on every keystroke/scroll/selection — `:103-108`), drive it from the existing `FileWatcher` tick (`DocumentModel.swift:2200-2202`): set a published `@Published var currentFileDiskStale: Bool` when the watcher fires for a tab whose loaded copy won't be auto-reloaded, and clear it on reload. Do **not** poll from `body`.

**Size.** **S** for Created/Modified display (data is mostly in hand, caching pattern exists). **M** for the stale-red signal done correctly — it needs a model-level `diskStale` flag fed by the watcher, careful interaction with the silent-reload path (for clean read-only tabs the file reloads before it's ever "stale", so the red state is mostly relevant for dirty editor tabs and during the reload window), and a perf-safe wiring that keeps stats off the `body` path.

**Dependencies.** Created/Modified: none. Stale-red: depends on a small model addition (`diskStale` published state) wired into `startWatchingCurrentFile`/`reloadCurrentFile` (`DocumentModel.swift:2102-2202`). Reuses `EditorBuffer.hasExternalEdit` semantics.

**Risk/one-way-door.** None — purely additive display + a published bool. The only real trap is performance: a naive `attributesOfItem` call inside `StatusBar.body` would stat the file on every keystroke and scroll tick. Must be cache/watcher-driven, matching the existing `currentMetrics` memoization rationale (`StatusBar.swift:103-108`).

---

# Perf / loading

### Perf — move file-loading off the main thread + proper loading/error states

**Status today — this is largely already DONE; the BACKLOG note is stale.** The BACKLOG entry calling this "the highest-leverage remaining UX win" (BACKLOG.md:273-277) describes work that has since landed:
- `DocumentState.loading(URL)` case **exists** (`DocumentController.swift:14-19`, with Equatable support at `:52-53`), landed in commit `b422ee2` ("perf: materializeIfNeeded off-main with .loading placeholder").
- **Lazy-tab selection** is off-main: `materializeIfNeeded(at:)` (`DocumentModel.swift:2471-2521`) flips the tab to `.loading(url)`, reads on a `Task.detached(priority: .userInitiated)`, and swaps to the final state only after re-finding the tab by id and confirming it's still `.loading` for the same URL (cancellation + identity guard at `:2487-2507`).
- **Eager open** is off-main too: `openResolved` checks `shouldDeferOpenOffMain` (`:1988-1999`, stats size vs `loader.softWarnBytes`, skips native-preview categories) and routes large text files through `openLargeFileOffMain` (`:2007-2056`) with the same `.loading` + identity-guard pattern (landed in commit `af5bef0`).
- **Loading UI state** exists: `ContentView.content` switches on `.loading(let url)` → `LoadingStateView(url:)` (`ContentView.swift:303-304`), which shows a spinner *after a 100 ms grace delay* so small files don't flash a spinner (`ContentView.swift:891-916`). Good UX detail.
- **Error UI state** exists: `.error(let failure)` → `ErrorView(failure:model:)` (`ContentView.swift:315-316`), backed by `DocumentState.LoadFailure` (`DocumentController.swift:21-29`) and a real `FileLoadError` taxonomy including `.tooLarge(bytes:ceiling:)` (`TextFileLoader.swift:3-15`).

**Root cause / gap — the remaining slivers.** The "freeze on large files" headline is solved. What's left is narrower:
1. **The read is still synchronous *within* the detached Task** (`controller.open(url:)` at `:2486`, `:2028`). It's off the main thread, so no beachball — but it's not cancellable mid-read (the code acknowledges this: cooperative cancellation only checks `Task.isCancelled` *after* the read returns — `:2479-2487`). Rapid tab-switching across several huge files spins up multiple full reads that run to completion before being discarded.
2. **`reloadCurrentFile`/`applyReload` is still synchronous on the main actor** (`DocumentModel.swift:2165` calls `controller.open(url:)` directly, no off-main hop). A watcher-triggered reload of a large file *will* stall the main thread — the off-main treatment was applied to open/select but not to watcher reload.
3. **`setCurrentViewMode` recovery paths** call `controller.open(url:)` synchronously on the main actor (e.g. `DocumentModel.swift:2583` for the HEX→media restore). Edge cases, large media excluded, but technically on-main.
4. **No determinate progress / no error state surfaced from the off-main path on partial failure** — the loading view is a bare spinner with no byte progress (acceptable; `controller.open` is one synchronous slurp, not a streaming read, so there's no progress to report without re-architecting the loader).

**Fix/build sketch.**
- Gaps are mostly closed; if pursued: (2) is the meaningful one — give `reloadCurrentFile`/`applyReload` the same `shouldDeferOpenOffMain` + `.loading` treatment used by `openLargeFileOffMain` so a large watched file reloading doesn't stall. (3) same treatment for the view-mode recovery reads. (1) is minor; true mid-read cancellation would require chunked reads in `TextFileLoader`.
- **Action for the user:** update BACKLOG.md:273-277 — strike the "off-main" item (done in `b422ee2`/`af5bef0`) and replace it with the narrower "watcher reload + view-mode recovery reads still sync on main" follow-up.

**Size.** The headline work is **already shipped (zero).** Remaining: reload-off-main **S–M** (mechanical reuse of the existing `openLargeFileOffMain` pattern, plus the dirty-buffer/editor-rebase interaction at `:2170-2185` needs care across the async hop); view-mode recovery off-main **S**; chunked/cancellable reads **L** (not worth it — the identity guard already discards stale results).

**Dependencies.** None — `.loading(URL)`, `LoadingStateView`, the identity-guard pattern, and `shouldDeferOpenOffMain` all already exist to copy from.

**Risk/one-way-door.** None structural. The one real correctness hazard (already handled in the open path, must be replicated if you make reload async) is the stale-write-into-wrong-tab race: any off-main read must re-find the tab by id and re-verify `.loading`+URL before mutating — see the documented `CORR-5`/`CR-04` guards (`DocumentModel.swift:2493-2507`, `:2627-2654`). The reload path additionally must not clobber a dirty editor buffer across the async hop (the sync version's invariant at `:2170-2185`).