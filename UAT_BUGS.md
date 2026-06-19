# UAT Bug List — Unfixed / Staged Issues

Maintainable inventory of UNFIXED and staged issues surfaced by the UAT smoke
sweeps. Append new findings; do not clobber. Resolved items should be struck
through or moved to a "Closed" section with the landing commit, not deleted, so
the audit trail survives.

**Legend**
- **Severity:** S1 (data loss / crash / security) · S2 (broken core behavior) ·
  S3 (degraded behavior / desync / harness blind spot) · S4 (cosmetic / scope
  note / observation).
- **Kind:** `bug` · `quality` · `inconsistency` · `discrepancy` · `ux-oddity`.
- **Status:** `OPEN` (real, unfixed product bug) · `HARNESS` (T4/--script
  observability limitation, needs VM to confirm/repro) · `DOC` (catalog vs
  implementation mismatch — fix the doc or the code) · `NON-BUG` (investigated,
  correctly self-classified non-defect) · `STAGED` (fix in flight on a branch).

> Cross-cutting harness caveat that recurs below: the `--script` runner's
> `delay SECS` verb ignores its argument and always sleeps a fixed 300ms
> (`Sources/MarkdownViewer/ScriptRunner.swift:43-46`,
> `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:197`). This caps the
> max expressible async-settle window for every T4 smoke; a future >300ms
> async-settle race would be structurally invisible. Tracked as its own entry
> (S3, harness) below.

---

## S2 — broken core behavior

### BUG-001 · Dirty dot never appears on edit in Editor mode
- **Severity:** S2 · **Kind:** bug · **Status:** OPEN
- **Area:** cm6-editor (edit / save / dirty / close) — group 4/12 · **Smoke:** cm6-1
- **Repro:** Open a `.txt` → switch to Editor → edit the buffer (`editor-set-text`,
  the same entry point the CM6 debounced-change JS bridge fires). Inspect the tab.
- **Expected:** Per cm6-1 step 2: within ~200ms the tab shows the accent dirty
  dot (`mdv.tab.dirtyDot`) and File > Save enables.
- **Actual:** The tab shows only the close ×, no dirty dot. The model's
  `Tab.isDirty` IS true (proven: a subsequent `close-tab` does not hang on the
  unsaved-buffer modal only because a prior `editor-save` cleared it; without the
  save the modal fires). The dot just never re-renders.
- **Root cause:** `EditorCoordinator.onReplaceTab = { tc.replace(at:with:) }`
  (`DocumentModel.swift:300`) fires only `tabCoordinator.objectWillChange`; PERF #1
  severed `tabCoordinator → DocumentModel` forwarding, and the 61c1aef LOADBUG fix
  re-published only at the async load completions, not the editor edit/save replace
  path. `TabBar` (`TabBar.swift:5`) observes only `@ObservedObject DocumentModel`,
  so it never re-bodies. The dot is rendered on `tab.isDirty` at `TabBar.swift:265`.
- **Caveat:** Live human typing moves the cursor → `onCursorMirrorToStatusBar`
  publishes `DocumentModel.sourceSelection`, which may incidentally mask this;
  programmatic `editor-set-text` exposes it cleanly. Needs VM live-typing
  confirmation.
- **Why not fixed:** Surfaced as a finding; no fix landed.
- **Evidence:** `/tmp/cm6uat/mdv-step-08.png`, `/tmp/cm6uat/tab_crop.png`;
  `DocumentModel.swift:300`; `TabBar.swift:265`, `TabBar.swift:5`.

### BUG-002 · Source view shows "No problems detected." for a broken Swift file
- **Severity:** S2 · **Kind:** ux-oddity · **Status:** OPEN (expected-current per catalog, reads as a bug)
- **Area:** lsp (hover / go-to-def / outline / refs / diagnostics) — group 8/12 · **Smoke:** LSP-01
- **Repro:** Open a `.swift` file containing `let badType: Int = "not an int"`
  under a SwiftPM/`Package.swift` root with sourcekit-lsp PATH-discoverable, in
  Source view, sidebar rooted at the project. Observe the sidebar PROBLEMS section.
- **Expected:** Either the type error appears in PROBLEMS as a row with a red
  count pill (LSP-01 step 5), or — if Source view genuinely has no diagnostic
  path — the panel should not present a falsely-reassuring green "No problems
  detected." for a broken file.
- **Actual:** PROBLEMS reads "No problems detected." while the open file has an
  unmistakable type error. Corroborates the catalog's documented trap: inbound
  `publishDiagnostics` notifications are dropped; diagnostics flow only via the
  CM6 editor push/pull path, which Source view never exercises.
- **Why not fixed:** Documented expected-current behavior per the catalog, but
  reads as a bug to a user (a syntactically-broken file shows zero problems). No
  fix landed.
- **Evidence:** `docs/uat/evidence/LSP-01_swift-source-open.png`.

### BUG-003 · TCC-protected root is NOT refused: session-open-folder creates AND persists the session
- **Severity:** S2 · **Kind:** discrepancy · **Status:** OPEN
- **Area:** Sessions (tabs-within-tabs / nested workspaces) — group 7/12 · **Smoke:** SESS-01 / cross-cutting (TCC-safe)
- **Repro:** Launch `dist/TextView.app` with `--script` containing
  `session-open-folder $HOME/Documents` (occluded, `MDV_BACKGROUND=1`,
  `MDV_SKIP_WORKSPACE_RESTORE=1`). Inspect the per-step dump's `model.sessions`
  and `~/Library/Application Support/MarkdownViewer/Sessions/index.json`.
- **Expected:** Per `docs/uat/smokes/sessions.md` (lines 56-59, 494) the
  coordinator "deliberately refuses to re-root or persist" TCC-protected roots via
  `isUnderTCCProtectedRoot`; the open should silently no-op (no pill, nothing
  written to disk).
- **Actual:** A new "Documents" session pill was created (`model.sessions` grew to
  3) AND persisted to the real `index.json` with `rootPath:/Users/me/Documents`.
- **Root cause:** The only `isUnderTCCProtectedRoot` guard is in
  `SessionsAppCoordinator.bootstrap()`'s `initialRoot` seeding
  (`SessionsAppCoordinator.swift:141`); neither `SessionsCoordinator.openFolder`
  (`SessionsCoordinator.swift:185`) nor `SessionsAppCoordinator.openFolder`
  (line 160) guards it.
- **Why not fixed:** Recommendation logged (add the guard to
  `SessionsCoordinator.openFolder` to match the documented contract); not yet done.
- **Evidence:** `~/Library/Application Support/MarkdownViewer/Sessions/index.json`
  after probe contained `{displayName:Documents, rootPath:/Users/me/Documents}`;
  grep shows the sole TCC guard at `SessionsAppCoordinator.swift:141`.

### BUG-004 · MCP --mcp-stdio process never exits on stdin EOF / shutdown (orphaned process; misleading log)
- **Severity:** S2 · **Kind:** bug · **Status:** OPEN
- **Area:** plugins-and-mcp-automation — group 9/12 · **Smoke:** SMOKE-PMA-01 (also PMA-02 oversize-frame, PMA-03 relaunch)
- **Repro:** Spawn `dist/TextView.app/Contents/MacOS/MarkdownViewer --mcp-stdio`;
  send `shutdown` (or close stdin, or send a `Content-Length: 20000000` oversize
  frame). Observe the process after several seconds.
- **Expected:** Per PMA-01 step 11 / PMA-02 step 11 the read loop stops and the
  process exits cleanly (stderr may log `stdin EOF; server exiting`).
- **Actual:** The read loop returns and stderr logs `mcp: stdin EOF; server
  exiting`, but the process keeps running indefinitely — `app.run()`
  (NSApplication) is never terminated, so the headless server has no exit path.
  Verified: spawn → close stdin → still alive after 4s with stderr already showing
  "server exiting". An agent that opens a session per task leaks one
  MarkdownViewer process every disconnect; the log line is actively misleading.
- **Root cause:** `main.swift` `applicationDidFinishLaunching` calls
  `startMCPServer()` and returns; nothing wires the read-loop end (EOF / `stop()` /
  framing-error close) to `NSApp.terminate(_:)`.
- **Fix sketch:** On `runLoop()` return and in `MCPServer.stop()`, hop to the main
  actor and `NSApp.terminate(nil)` / `exit(0)`.
- **Why not fixed:** Finding logged; no fix landed.
- **Evidence:** Probe stderr `mcp: server ready on stdio\nmcp: stdin EOF; server
  exiting\n` while the process lingered after 4s. `Sources/MarkdownViewer/main.swift:1724`
  (`startMCPServer`), `:1770`; `Sources/ViewerCore/Automation/MCPServer.swift:79-96`
  (`runLoop`) + `:65-70` (`stop`).

### BUG-005 · Large image opens at 100% (overflowing), not fit-to-window
- **Severity:** S2 · **Kind:** bug · **Status:** OPEN
- **Area:** Previews (image / audio / video / pdf / sqlite / csv) — group 10/12 · **Smoke:** PV-01
- **Repro:** Open an image larger than the viewport (e.g. 800×600 `a.png` in a
  ~290–536px-wide content pane) in `dist/TextView.app`. Reproduces in BOTH
  foreground and `MDV_BACKGROUND` launches. Verified by driving the bundle via
  `--script` with a persistent `MDV_ARTIFACT_DIR` and inspecting the dump + window
  PNG; a resize step does not fix it.
- **Expected:** Image is fit-to-window on first paint (the `didFit` guard scales
  it down so the whole image is visible, centered on both axes). For an 800×600
  image in a ~290px-wide viewport the fit scale is ~36% and the percent HUD should
  read ~36%.
- **Actual:** The percent HUD reads 100%, `documentView_frame` stays 800×600, and
  the image overflows the viewport (only the top-left quadrant visible, clipped
  right and bottom). The fit is computed and momentarily applied, then immediately
  reverted.
- **Root cause:** `MediaPreviewView.swift` `fitToWindow()` sets `@State
  magnification=0`; `ImageScrollHost.updateNSView` `applyFit()` (~line 392) sets
  `scroll.magnification = fitScale(...)` (math correct, ~0.36) but never writes the
  fit value back into the `magnification` binding (`ImagePreview.swift:159` HUD
  binds to it). The next `updateNSView` pass sees `magnification` back at its 1.0
  default and the else-if branch (`MediaPreviewView.swift:369`,
  `abs(scroll.magnification - magnification) > 0.001`) snaps the scroll back to 1.0.
  `onLoad` did fire (the "800 × 600" dimension readout, gated on `pixelSize>0`, is
  present).
- **Fix sketch:** Push the computed fit back into the `magnification` binding so
  SwiftUI state and the NSScrollView agree.
- **Why not fixed:** Finding logged; no fix landed.
- **Evidence:** `mdv-step-03.png` (background, HUD=100% clipped), `mdv-step-05.png`
  (foreground, HUD=100% clipped); dump `nsScrollView.contentSize=536.5x601.0` with
  `documentView_frame=800x600` + HUD 100% even after resize.

### BUG-006 · Walkthrough player transport strip never mounts in the realized view tree (occluded T4)
- **Severity:** S2 · **Kind:** bug · **Status:** HARNESS (needs VM confirmation) / OPEN
- **Area:** walkthrough-and-code-review — group 12/12 · **Smoke:** WCR-01
- **Repro:** Spawn `dist/TextView.app` with `--walkthrough tour.json --script
  <delay-steps>` under `MDV_BACKGROUND=1`. Capture a DiagnosticDump per step. Diff
  the full `contentView` tree of a walkthrough-active run vs a no-walkthrough run
  with identical argv.
- **Expected:** With a walkthrough active, ContentView's
  `if walkthrough.isActive { WalkthroughPlayerView(controller:) }`
  (`Sources/ViewerUI/ContentView.swift:239-244`) should insert the docked-bottom
  transport strip into the realized NSView tree.
- **Actual:** The realized trees are BYTE-IDENTICAL (151 nodes, zero class-count
  diffs) whether or not a walkthrough is active — the strip is absent — even though
  the engine is demonstrably active (the tour's verbs land on the live
  DocumentModel and the `highlightRange` overlay stripe renders the line-4 focus
  stripe). The overlay updates because it is an always-present
  `.overlay(WalkthroughOverlay)` reading `model.walkthroughBridge`
  (`@ObservedObject` on DocumentModel); the strip's structural insertion is gated
  on `walkthrough.isActive`, a `@Published` on the `@StateObject`
  `WalkthroughPlayerController`, whose change is not re-bodying/committing
  ContentView in this path.
- **Root cause:** Same republish/forwarding class as the matrix smoke's PERF #1
  `objectWillChange` sever.
- **Why not fixed:** UNRESOLVED whether the strip mounts in a foreground VM
  session; if it does not, the entire transport UI (prev/play-pause/next/speed/
  steps/note/exit) is invisible and a running tour cannot be controlled or exited.
  Needs VM confirmation before fixing.
- **Evidence:** Live walkthrough render PNG (Source `main.swift`, line-4 stripe, no
  bottom strip); tree diff total nodes 151 vs 151 delta 0. Logged as F-WCR-STRIP in
  `docs/uat/UAT_RUN_undated.md`.

---

## S3 — degraded behavior / desync / harness blind spots

### BUG-007 · Carry-mode HEX leaks onto native-preview types — ModeBar picker↔pane desync
- **Severity:** S3 · **Kind:** bug · **Status:** OPEN
- **Area:** tabs-and-window-chrome · **Smoke:** SC-CHROME-02
- **Repro:** Open any native-preview file (image/sqlite/pdf/audio/video)
  immediately after a HEX-mode file with no intervening source tab. Driven live:
  argv-open `raw.bin` (HEX), then `open after.png`
  (`test_SC_CHROME_02_carryModeHexOntoPreview_DESYNC`).
- **Expected:** ModeBar view-mode picker should track the rendered pane: the native
  Preview lens is what draws, so the picker should read "Preview" (or at least not
  contradict the pane).
- **Actual:** `model.currentViewMode=hex` while `model.currentStateKind=preview`.
  Realized tree confirms it: subtree is `ZoomableImageScrollView` →
  `CenteredImageView` → `_NSImageViewSimpleImageView` with NO `Hex*` view present —
  the picker highlights HEX over a pane that is unmistakably the native image lens.
  Self-heals on any explicit re-pick or Open-As → Auto.
- **Root cause:** `DocumentModel.openResolved` carry-mode carries `.hex` because
  `.hex ∈ availableModes` of preview types (`[.preview,.hex]`); the loader returns
  `.preview` and the HEX-load block is correctly skipped, leaving the picker
  selecting a mode the pane isn't in. Same defect family as BUG-019.
- **Why not fixed:** Finding logged; fires as a tracked `XCTExpectFailure`
  (hex != preview). No fix landed.
- **Evidence:** `docs/uat/evidence/SC-CHROME-02_carry-hex-onto-preview_desync.json`.

### BUG-008 · session-open-new does not re-root the live sidebar under the script harness
- **Severity:** S3 · **Kind:** discrepancy · **Status:** HARNESS (not a confirmed product bug)
- **Area:** sidebar-filetree-and-bookmarks · **Smoke:** SFB-10
- **Repro:** Live `dist/TextView.app`, occluded, `MDV_SKIP_WORKSPACE_RESTORE=1`.
  Script: `sidebar-set-root <repo>`; `session-open-new <repo>/subdir`; capture
  dumps over ~1.2s.
- **Expected:** SFB-10 step 2: "a new session pill appears rooted at that
  subfolder" — the active sidebar root follows the newly-created+activated session
  to `<repo>/subdir`.
- **Actual:** The session IS created and marked active (`activeSessionID` set,
  `sidebarRootPath=subdir` in the coordinator list), but the live `sidebar.rootURL`
  stays on `<repo>/` deterministically across all 5 post-create dumps.
- **Root cause:** `MDV_SKIP_WORKSPACE_RESTORE=1` skips `sessions.bootstrap()`
  (`main.swift:215-216`), so `core.setLifecycle(bridge)` is never wired;
  `core.openFolder(forceNew:true)`'s `lifecycle?.mount(snap)` is a nil no-op, so
  `SessionState.hydrate -> model.sidebar.setRoot(subdir)`
  (`SessionState.swift:242`) never runs.
- **Why not fixed:** HARNESS observability limitation, NOT a confirmed production
  bug — corrects the prior run's "capture-timing BUG-WATCH" framing. Production
  re-root must be checked on the VM lane with real bootstrap.
- **Evidence:** Traced via `main.swift:215-216`,
  `SessionsAppCoordinator.swift` (`LifecycleBridge.mount` + `switchSessionFacade`),
  `SessionState.swift:239-244`; dumps `mdv-step-04..08` all show
  `activeRoot=...gitrepo/` with the subdir session active.

### BUG-009 · Script-runner `delay SECS` verb ignores its argument — always sleeps a fixed 300ms
- **Severity:** S3 · **Kind:** quality · **Status:** HARNESS
- **Area:** sidebar-filetree-and-bookmarks / harness (cross-cutting) · **Smoke:** SFB-01, harness, ViewModes
- **Repro:** Any T4 smoke line such as `delay 0.9` / `delay 0.6`. See
  `Sources/MarkdownViewer/ScriptRunner.swift:43-46` (fixed `Task.sleep
  300_000_000` per step) and `ScriptVerbDispatch.swift:197` (delay is a pure no-op).
- **Expected:** Per the runner doc-comment (`ScriptRunner.swift:30` —
  `delay SECS  pause without action`), a `delay 0.9` step pauses ~0.9s so
  FSEvents / the accordion / a git re-list / a WKWebView mount / a HEX swap / a
  Preview restore can settle.
- **Actual:** The arg is discarded; every step (delay or not) sleeps exactly 300ms.
  Nothing flakes today (model assertions settle in <300ms), but this silently caps
  the max expressible settle window, so a future async-settle race needing >300ms
  would be structurally invisible to these T4 smokes. (The originally-authored
  ViewModesUATTests produced 28 spurious failures, incl. a FALSE "Bug C / Hex stuck
  under Preview", because completions land after 300ms and the test asserted on the
  mid-flight dump; reworking the suite to assert on the settled per-(url,mode) dump
  fixed it — now 13/13, 0 unexpected.)
- **Why not fixed:** Recommendation logged (parse the arg as seconds in the
  runner); not yet done.
- **Evidence:** `Sources/MarkdownViewer/ScriptRunner.swift:43-46`,
  `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:197-199`.

### BUG-010 · setCurrentViewMode/toggleViewMode accept an off-menu mode → picker shows no selected segment while pane stays in the real mode
- **Severity:** S3 · **Kind:** bug · **Status:** OPEN
- **Area:** view-modes (source / editor / hex / rendered / preview / formatted) · **Smoke:** VM-06var / PROBE
- **Repro:** Open a plain `.py` (Source default). Drive `toggle-view` (⇧⌘R) OR
  `editor-set-mode rendered` against the model. `currentViewMode` flips to
  `rendered` even though Python's `availableModes` are Source|Editor|HEX (no
  Rendered). Reproduced live with multi-delay settle; persists across steps.
- **Expected:** Per the catalog (VM-06var: "⇧⌘R should be a NO-OP on a `.py`") and
  `ViewModeOptions.availableModes`, forcing a mode not in the file type's
  `availableModes` should be clamped to a valid default or be a no-op, so the
  ModeBar picker never reads a mode the type doesn't offer.
- **Actual:** `DocumentModel.setCurrentViewMode` (`DocumentModel.swift:3157`)
  assigns `t.viewMode = mode` unconditionally (only guard is the 50MB editor cap).
  The picker reads off-menu `rendered` for a `.py`. Visible symptom: ModeBar
  renders Source|Editor|HEX with NO segment highlighted, while the pane + status
  bar are fully in Source (NSTextView 15 glyphs, Ln 3 Col 1 / Lines 2 / Chars 15;
  NO WKWebView mounted). The picker's selection indicator lies about what is
  displayed. Content does NOT break (graceful Source fallback, no crash/blank/
  Hex-leak).
- **Mitigating:** The live ⇧⌘R menu item is DISABLED for non-markdown via
  `AppDelegate.validateMenuItem` (`main.swift:1435` returns
  `model.supportsViewModeToggle`), so a user cannot reach it via menu/keyboard —
  only un-gated callers (`toggle-view`/`editor-set-mode` script verbs, MCP
  `set_view_mode`, future call sites) hit it. The validity gate lives in the menu
  layer, not in the model method; `setCurrentViewMode` should self-guard.
- **Why not fixed:** Captured as `XCTExpectFailure` (`strict:false`) —
  green while the gap persists, flips to "unexpectedly passed" once the model
  self-guards. No fix landed. Same defect family as BUG-007, BUG-019.
- **Evidence:** `docs/uat/evidence/VM-PROBE_editorsetmode-rendered-python-desync.png`
  + `.json`; `docs/uat/evidence/VM-06var_toggleview-python-offmenu-rendered.json`;
  `Tests/ViewerUITests/uat/ViewModesUATTests.swift`
  (`test_PROBE_forceUnavailableModeRenderedOnPython`,
  `test_VM_06var_toggleViewNoopOnPlainSource`).

### BUG-011 · Status-bar Lines/Chars/Size stale in Editor mode (never reflect the live buffer; don't refresh after editor-save)
- **Severity:** S3 · **Kind:** bug · **Status:** OPEN
- **Area:** cm6-editor (edit / save / dirty / close) — group 4/12 · **Smoke:** cm6-1
- **Repro:** Open `uat_edit.txt` (`alpha\nbravo\ncharlie\n` = 20B, 3 lines) →
  Editor → `editor-set-text` to a 42-byte single line → `editor-save`. Read the
  status bar in Editor mode, then switch to Source.
- **Expected:** Per cm6-1 step 2: status bar Chars/Lines/Size update live as the
  buffer changes; after save they reflect the saved content (42B, 1 line).
- **Actual:** In Editor mode the status bar shows Lines 3 / Chars 20 / Size 20B at
  BOTH the dirty step (08) AND the post-save step (10) — the on-disk-at-open
  values, never the live or saved buffer. Switching to Source corrects it to
  Lines 1 / Chars 42 / Size 42B, so the save DID propagate to `tab.state` — the
  editor-mode StatusBar just never re-bodies. No data loss (disk is correct).
- **Root cause:** `StatusBar` (`StatusBar.swift:223`) computes metrics from
  `tab.state`'s `TextFile` contents and observes `DocumentModel` +
  `SourceViewChannel`, not the editor buffer; the editor save's `tab.state` rewrite
  goes through `tabCoordinator.replace`, which doesn't republish `DocumentModel`
  (same severed path as BUG-001). Higher-confidence live bug than BUG-001:
  `editor-save` never moves the cursor, so even live-typed edits won't get the
  incidental cursor-mirror republish on the save path.
- **Why not fixed:** Finding logged; no fix landed.
- **Evidence:** `/tmp/cm6uat/mdv-step-10.png` (post-save editor: Lines 3 / Chars 20
  / Size 20B); `/tmp/cm6uat2/mdv-step-13.png` (after switch to Source: Lines 1 /
  Chars 42 / Size 42B); `StatusBar.swift:220-246`; `DocumentModel.swift:300`.

### BUG-012 · Rendered find bar renders a `.*` regex toggle the catalog says must be absent — a dead control bound to a constant
- **Severity:** S3 · **Kind:** bug · **Status:** OPEN (one-line fix)
- **Area:** search (find-bar / cross-file / unified panel / jq / css / xpath) — group 5/12 · **Smoke:** SMK-SEARCH-01
- **Repro:** Open any markdown file (defaults to Rendered). Press Cmd+F (or drive
  `show-find`). Observe the find bar's right-hand controls. Live-confirmed occluded
  via `dist/TextView.app` with `MDV_BACKGROUND=1`; screenshot `mdv-step-04.png`.
- **Expected:** Per `docs/uat/smokes/search.md` SMK-SEARCH-01 step 1 and the scope
  table: the rendered find bar offers ONLY a Match-case (Aa) toggle and NO regex
  (`.*`) toggle, because WKWebView find cannot do regex.
- **Actual:** The rendered find bar shows BOTH the `Aa` case toggle AND a `.*`
  regex toggle. The toggle (a) contradicts the documented behavior and (b) is a
  dead control: bound to a constant, clicking it does nothing and it can never
  reflect an on-state.
- **Root cause:** The shared `FindBar` SwiftUI view renders the `.*` Toggle
  UNCONDITIONALLY (`Sources/ViewerUI/MarkdownFindBar.swift:80-89`); the rendered
  bar passes `isRegex: .constant(false)` (line 160) with a stale comment claiming
  the toggle "is hidden visually but state is unused" — but no code hides it.
- **Fix sketch:** One-line conditional to omit the regex toggle for the rendered bar.
- **Why not fixed:** Finding logged; no fix landed.
- **Evidence:** `mdv-step-04.png`; `Sources/ViewerUI/MarkdownFindBar.swift:80-89`
  and `:160`; `Tests/ViewerUITests/uat/SearchSurfacesUATTests.swift`
  (`test_SMK_SEARCH_01_renderedFindBarMountDismiss` doc).

### BUG-013 · Per-session façade (tab swap, sidebar re-root, watcher pause) never runs in a scripted T4 run
- **Severity:** S3 · **Kind:** quality · **Status:** HARNESS (not a product bug)
- **Area:** Sessions (tabs-within-tabs / nested workspaces) — group 7/12 · **Smoke:** SESS-01 steps 5-6, SESS-05/06/08/09
- **Repro:** Launch with `--script`: `session-open-folder projA`; `open a1.md`;
  `open a2.txt`; `session-open-folder projB`; `session-activate 1`. Observe
  `model.tabCount` / `selectedTabIndex` / `currentURL` / `sidebar.rootURL` across
  steps. Pinned by `test_SESS01_tabAndSidebar_doNotSwitch_probe` so a future
  bridge-under-flag fix trips it.
- **Expected:** Switching to projB resets the per-file tab strip (projB has no
  tabs); switching back to projA restores projA's 2 tabs with `a2.txt` selected;
  the sidebar re-roots to the active session's folder (SESS-01 headline #184
  regression guard).
- **Actual:** Only the value layer updates: `model.sessions` list +
  `activeSessionID` flip correctly, but `tabCount` stays at projA's count with
  projA's tab still selected through the projB switch, and is unchanged when
  switching back (no restore). `sidebar.rootURL` stays pinned at the argv file's
  parent (temp scratch dir) the entire run.
- **Root cause:** The lifecycle bridge is wired ONLY in
  `SessionsAppCoordinator.bootstrap()`, which `main.swift:215` gates behind
  `MDV_SKIP_WORKSPACE_RESTORE != 1` — and `AppLauncher.runScript` ALWAYS sets
  `MDV_SKIP_WORKSPACE_RESTORE=1`, so `lifecycle==nil` and
  `openFolder`/`activate`'s `lifecycle?.mount(snap)` is a no-op.
- **Why not fixed:** HARNESS blind spot, not a product bug — the LIVE foreground
  app (restore enabled) DOES run the façade swap. But it makes ~half the catalog
  (SESS-01 core/05/06/08/09 + relaunch halves 03/07/10) un-gateable from the
  CI/merge lane.
- **Evidence:** 3 independent probes (`tmp.vamDu56VjI`, `tmp.EcJDsiBlBy`) show
  `tabCount` unchanged across session switch + `sidebar.rootURL` never moving off
  the argv parent; `main.swift:215` is the sole gate on `bootstrap()`. Documented
  as F-SESS-1 in `docs/uat/UAT_RUN_undated.md`.

### BUG-014 · OUTLINE and REFERENCES sidebar sections do not appear for a live, supported (.swift) file under a root
- **Severity:** S3 · **Kind:** discrepancy · **Status:** HARNESS (needs VM confirmation) / OPEN
- **Area:** lsp — group 8/12 · **Smoke:** LSP-01
- **Repro:** Open a `.swift` file under a SwiftPM root with sourcekit-lsp
  available; root the sidebar at the project; dwell. Inspect the sidebar accordion.
- **Expected:** Per `SidebarDataPresence` (`Sources/ViewerCore/SidebarDataPresence.swift:57-59`),
  `.lspOutline` is present when `hasRoot && hasLSPLanguage` (both true) and
  `.lspNavigation` whenever `hasRoot` (true) — so OUTLINE and REFERENCES should be
  visible (OUTLINE populated with symbols + a count chip per LSP-01 step 3).
- **Actual:** Only the bookmarks-area, SEARCH, and PROBLEMS sections render;
  OUTLINE and REFERENCES are absent. This is the realized-tree side of the F-LSP-1
  spawn non-determinism: `LSPOutlineWrapper`'s `isSupported`/`refresh` gate
  (`.onAppear`/`.onChange`) races the bounded accordion's section realization in
  the occluded/scripted window.
- **Why not fixed:** Needs a foreground VM session to confirm whether it reproduces
  in a real GUI session; if it does, Outline is silently missing for a supported
  language. No fix landed.
- **Evidence:** `docs/uat/evidence/LSP-01_swift-source-open.png`.

### BUG-015 · sourcekit-lsp child spawn on .swift open is non-deterministic in the occluded/scripted run
- **Severity:** S3 · **Kind:** bug · **Status:** HARNESS (may be foreground-deterministic) / OPEN
- **Area:** lsp — group 8/12 · **Smoke:** LSP-01
- **Repro:** Run identical scripts 3×: launch `dist/TextView.app --script` with
  `sidebar-set-root <swiftpm-proj>` then `open <proj>/Sources/Demo/main.swift`,
  polling `pgrep -x sourcekit-lsp` for ~8s after open. Host probe.
- **Expected:** Opening a `.swift` file under a SwiftPM root with a discoverable
  server deterministically spawns sourcekit-lsp every time.
- **Actual:** Server child spawned in only 1 of 3 identical runs. The spawn is
  driven by `LSPOutlineWrapper.refresh()` (`.onAppear`/`.onChange(of:currentURL)`
  → `LSPOutlineModel.setFile` → `LSPPool.documentSymbol`), which only fires once the
  lower accordion sections are realized — and the occluded window does not reliably
  realize them. Same republish-ordering class as BUG-016 (F-GIT-1).
- **Why not fixed:** May be deterministic in a foreground GUI session (untested);
  flagged for the VM lane. No fix landed.
- **Evidence:** Host probe poll (1/3 runs spawned); root cause traced to
  `Sources/ViewerUI/SidebarView.swift:1269-1282` (`LSPOutlineWrapper.refresh` on
  `.onAppear`/`.onChange`).

### BUG-016 · GIT accordion section never mounts in the scripted/occluded run despite being rooted inside a tracked repo
- **Severity:** S2 · **Kind:** bug · **Status:** HARNESS (foreground unconfirmed) / OPEN
- **Area:** git-panel · **Smoke:** GP-01
- **Repro:** Build `dist/TextView.app`. Launch occluded (`MDV_BACKGROUND=1`) with a
  file inside a git repo as argv; script: `sidebar-set-root <repo>`; wait 2-3s;
  optionally `open <repo>/another-file` or `sidebar-select-next`; `snapshot`.
  Reproduced across 4 independent probe runs (settle up to 2.5s+3s+1.5s). Also runs
  as the non-fatal probe `test_GP_01_gitSectionMountWhenRootedInRepo`. Blocks
  automated verification of GP-01..08 and GP-11.
- **Expected:** Per `docs/uat/smokes/git-panel.md` GP-01 step 1, the GIT accordion
  section appears in the sidebar (between SEARCH and PROBLEMS) once the focused root
  resolves to a tracked repo, showing the branch + 6-tab strip.
- **Actual:** No GIT accordion section renders at all, even though the sidebar is
  firmly rooted at `gitrepo/`, two tabs are open inside the repo, and the FILES
  tree is fully git-aware (green repo-folder icon + a `?` untracked badge prove
  `TrackedReposChannel` is populated). `recursiveDescription` carries zero
  git-section/tab-label text.
- **Caveat:** Could NOT confirm whether this reproduces in a normal FOREGROUND GUI
  session — may be specific to the occluded `MDV_BACKGROUND` launch.
- **Best-guess root cause:** `GitPanelSection` self-gates on `panel.repoRoot != nil`
  (`GitPanelSection.swift:32`) set via `syncRepo()->followFocus(repoFocus.focusedRoot,...)`;
  `RepoFocusTracker.recompute()` sets `focusedRoot` only AFTER `handoffMirror()`'s
  channel version tick inside the same async Task, so the section's
  `.onChange(of: trackedRepos.version)` can read a still-nil `focusedRoot` with no
  later tick to re-trigger.
- **Why not fixed:** Needs foreground VM confirmation; no fix landed. (Severity S2
  per the source data — the entire tabbed git panel is unreachable via the only
  available automation path.)
- **Evidence:** Probe PNG `mdv-step-06.png` (cleaned; reproducible via the probe);
  test log `[UAT git-panel F-GIT-1] GIT accordion section NOT observed...`;
  `Sources/ViewerUI/Git/GitPanelSection.swift:32` +
  `Sources/ViewerUI/Git/RepoFocusTracker.swift:135-186`.

### BUG-017 · Entire LSP feature surface is un-automatable from the --script harness (no verbs, no dump signal)
- **Severity:** S3 · **Kind:** quality · **Status:** HARNESS
- **Area:** lsp — group 8/12 · **Smoke:** LSP-02
- **Repro:** Inspect `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` (verb
  vocabulary) and `ScriptVerb.modelStateDump`; inspect a DiagnosticDump JSON for any
  LSP key or `mdv.lsp*` a11y id.
- **Expected:** Some scriptable / dump-observable hook for hover, go-to-definition,
  outline, references, problems-filter, or the diagnostics window so the catalog's
  LSP-01..04 can be regression-gated.
- **Actual:** Zero LSP script verbs; `ScriptVerb.modelStateDump` carries no LSP
  state (no outline symbols, problems rows, references rows, per-server
  live/dead/crash/Reqs, or hover payload); SwiftUI `.accessibilityIdentifier`
  (`mdv.lspOutline`/`mdv.problems`/`mdv.lspNav`) does not propagate to NSView, and
  the accordion sections render as generic `HostingScrollView` hosts whose label
  text is absent from `recursiveDescription`. Consequence: LSP-02/03 are entirely
  MANUAL/VM; LSP-01/04 only partially covered.
- **Why not fixed:** Recommendation logged (expose an `lsp` sub-dict in
  `modelStateDump`: outline symbol count, problems counts by severity, nav-row
  count, pool server states); not yet done.
- **Evidence:** `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` (no LSP
  verbs), `ScriptVerb.modelStateDump` (no LSP keys),
  `Tests/ViewerUITests/uat/LSPUATTests.swift`.

### BUG-018 · Plugin subprocess audit log leaks the absolute plugin path for a missing/typo'd bin (OBS-6 violation)
- **Severity:** S3 · **Kind:** bug · **Status:** OPEN
- **Area:** plugins-and-mcp-automation — group 9/12 · **Smoke:** SMOKE-PMA-06
- **Repro:** Call `PluginSubprocessHost.call(...)` with a `bin` that does not exist
  inside the plugin folder; inspect the resulting JSONL line in the audit log.
- **Expected:** Per PMA-06 step 5 / OBS-6: spawn failures record `bin_basename` and
  a stable errno-style descriptor with NO absolute filesystem path in the log.
- **Actual:** The missing-bin preflight (`PluginSubprocessHost.swift:148`) builds
  `.spawnFailed("bin not found: \(executable.path)")` — embedding the absolute
  plugin path — which `writeAudit` (line 457: `line["error"] = msg`) writes
  verbatim into the `0o600` audit log's `error` field. Only the
  `process.run()`-failure branch (line 207) uses the byte-free
  `stableSpawnErrorDescriptor`; the comment at lines 453-457 even claims `msg` is
  "already byte-free", but the missing-bin path predates that. A user with a
  typo'd / not-yet-built plugin bin leaks their absolute plugin path into a
  path-free log.
- **Why not fixed:** The existing unit test
  `test_spawnFailed_audit_records_bin_basename` only asserts `bin_basename`, so this
  gap is currently unguarded. No fix landed.
- **Evidence:** F-PMA-OBS6 from `test_PMA06_subprocessFailureTaxonomy`:
  `bin not found: /var/folders/.../plugin-fixture/does-not-exist-here.sh`;
  `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift:148` (and `:153`
  "bin not executable" same shape) + `:451-458`.

### BUG-019 · toggle-view / ⇧⌘R sets an invalid .rendered mode on non-toggleable types, desyncing the ModeBar picker from the drawn pane
- **Severity:** S3 · **Kind:** bug · **Status:** OPEN
- **Area:** settings-and-menus-and-shortcuts · **Smoke:** SC-MENU-01
- **Repro:** Open any plain-text / source / JSON file (e.g. `note.txt`), then
  invoke `toggle-view` (the ⇧⌘R "Show Rendered/Source" action) via `--script
  toggle-view`, MCP `set_view_mode`, or any programmatic caller. Captured by
  `test_SC_MENU_01var_viewModeToggleScopeDESYNC` and a direct dump probe.
- **Expected:** A no-op. ⇧⌘R is scoped to markdown/mermaid
  (`supportsViewModeToggle` is false for every other type), so the view mode should
  stay `.source` and the ModeBar picker should keep showing Source.
- **Actual:** `model.currentViewMode` flips to `.rendered`, but plainText's
  `availableModes` is `[.source, .editor, .hex]` — there is no Rendered view. The
  pane correctly keeps drawing the source NSTextView (probe: `currentStateKind ==
  loaded`, 1 NSTextView, 0 WKWebView), so the ModeBar picker LIES: it shows
  "Rendered" while a Source pane is on screen. A second invoke self-heals
  (rendered?source:rendered swap is symmetric), but a single invoke leaves the
  picker mislabeled.
- **Root cause:** `DocumentModel.toggleViewMode()` is unconditional (no
  `supportsViewModeToggle` guard) and `setCurrentViewMode(_:)` does not reject a
  mode absent from `ViewModeOptions.availableModes(for:)`. In the live menu bar the
  ⇧⌘R item is greyed for non-markdown (`validateMenuItem` reads
  `supportsViewModeToggle`), capping the blast radius — but the underlying model
  action is unguarded, so MCP/script/programmatic callers still trip it. Same
  defect family as BUG-007, BUG-010.
- **Fix sketch:** Guard `toggleViewMode()` on `supportsViewModeToggle` and/or reject
  a mode not in the tab's `availableModes` inside `setCurrentViewMode`.
- **Why not fixed:** Captured as a green `XCTExpectFailure`; no fix landed.
- **Evidence:** `Tests/ViewerUITests/uat/SettingsMenusAndShortcutsUATTests.swift`
  (`test_SC_MENU_01var_viewModeToggleScopeDESYNC`); probe dump
  `currentViewMode=rendered`, `currentStateKind=loaded`, 1 NSTextView / 0 WKWebView;
  `Sources/ViewerUI/DocumentModel.swift:3054` (`toggleViewMode`) + `:3059`
  (`setCurrentViewMode`); `Sources/ViewerKit/ViewMode.swift:27`.

### BUG-020 · CLI-launched walkthrough auto-advance fires exactly once (stalls) in the occluded launch
- **Severity:** S3 · **Kind:** ux-oddity · **Status:** HARNESS (likely occlusion-only) / OPEN
- **Area:** walkthrough-and-code-review — group 12/12 · **Smoke:** WCR-01
- **Repro:** Launch `dist/TextView.app` with `--walkthrough tour.json` (any
  dwellSec) under `MDV_BACKGROUND=1` + `--script` delay steps; observe
  `currentURL`/tab progression across step dumps. Probed deterministically with a
  3-step zero-dwell openFile chain (main→helper→README).
- **Expected:** A multi-step tour with `dwellSec` set should auto-advance through
  every step on its dwell schedule.
- **Actual:** Auto-advance progresses by EXACTLY ONE step from the initial
  `WalkthroughPlayerController.start()`: `start()` lands step 1 and fires one
  `scheduleAdvanceIfNeeded()`; the auto-advance Task calls `engine.next()` DIRECTLY
  (`WalkthroughAutoAdvance.swift:119`) which does NOT re-schedule — only the
  controller's `next()` does (`WalkthroughPlayerView.swift:295-299`). The
  SwiftUI-strip lifecycle callbacks that would re-arm the scheduler don't fire while
  the window is occluded/non-foreground. A `dwellSec:1.0` tour stalls on step 1; a
  zero-dwell chain reaches step 2 only.
- **Why not fixed:** Likely an occlusion-only artifact (the foreground VM strip
  `onChange`/`onAppear` probably re-arms it), but the `engine.next()`-doesn't-
  reschedule design means the re-arm is entirely strip-lifecycle-driven, which is
  fragile. No fix landed.
- **Evidence:** 3-step zero-dwell chain lands on `helper.swift` (step 2), not
  `README.md` (step 3). Logged as F-WCR-AUTOADV in `docs/uat/UAT_RUN_undated.md`.

---

## S4 — cosmetic / scope notes / observations

### BUG-021 · Dirty-close NSAlert deadlocks --script automation
- **Severity:** S4 · **Kind:** quality · **Status:** HARNESS
- **Area:** tabs-and-window-chrome · **Smoke:** SC-CHROME-01
- **Repro:** Make a tab editor-dirty (`editor-set-mode editor` + `editor-set-text`),
  then `close-tab` it under `--script` in an occluded/headless run.
- **Expected:** The dirty-close prompt's Save/Don't-Save/Cancel branch +
  right-neighbor selection (SC-CHROME-01 step 6) should be automatable.
- **Actual:** `close-tab` on a dirty tab calls
  `EditorCoordinator.confirmCloseIfDirty → NSAlert.runModal()`, which blocks the
  main thread forever (no one clicks); the script Task can't advance and the app
  must be SIGKILLed at timeout. An unused test hook (`dirtyClosePromptOverride`)
  exists but is wired to no script verb. Worked around by `editor-save` before close.
- **Why not fixed:** Recommendation logged (a `confirm-dirty-close
  <save|discard|cancel>` verb routed through the existing override hook); not yet done.
- **Evidence:** `TabsAndWindowChromeUATTests.swift`
  `test_SC_CHROME_01_multiTabLifecycle` comment (s9 editor-save workaround);
  `ScriptVerbDispatch.swift` has no close-confirm verb.

### BUG-022 · `set-open-as hex` is a silent no-op (no `hex` FileCategory)
- **Severity:** S4 · **Kind:** inconsistency · **Status:** DOC / OPEN
- **Area:** tabs-and-window-chrome · **Smoke:** SC-CHROME-02
- **Repro:** Run `set-open-as hex` on any tab.
- **Expected:** Either force the byte grid, or surface an error for an invalid
  category arg.
- **Actual:** `FileCategory(rawValue:"hex") == nil`, so the verb silently does
  nothing. The byte-grid (HEX) lens is actually the `binary` FileCategory — forcing
  HEX via Open-As requires `set-open-as binary`.
- **Why not fixed:** Doc note logged so future smokes don't pass the wrong arg; no
  fix landed.
- **Evidence:** `ScriptVerbDispatch.swift` `set-open-as` case
  (`FileCategory(rawValue:)` guard); confirmed via
  `test_SC_CHROME_02_previewRoutingAndOpenAs` using `set-open-as binary`.

### BUG-023 · `resize 360x300` is clamped to a realized 600x360 by the window contentMinSize
- **Severity:** S4 · **Kind:** ux-oddity · **Status:** NON-BUG (scope note)
- **Area:** tabs-and-window-chrome · **Smoke:** SC-CHROME-05
- **Repro:** Drive `resize 360x300` via `--script` and inspect the resulting
  contentView frame in the DiagnosticDump.
- **Expected:** (Scope note, not a defect.) Be aware the chrome-pin invariant is
  exercised at the window MINIMUM size, not below it.
- **Actual:** The realized contentView is 600×360 — the window cannot be driven
  below its `contentMinSize` (correct real-world behavior; a user can't drag
  smaller). The test comment says "360x300" which is the requested, not realized,
  geometry. Chrome-pin verified at the minimum: ModeBar SystemSegmentedControl
  stays fixed 314×24, center WKWebView shrinks 802.5×621 → 302.5×249, no bar
  blanks/zero-sizes. Sub-minimum behavior is not script-reachable; left to MANUAL/VM.
- **Why not fixed:** Not a defect.
- **Evidence:** Fresh probe dump: `resize 360x300` → root contentView frame
  (0,0 600×360); WKWebView never zeroSize.

### BUG-024 · One zero-sized HostingScrollView accordion host in the sidebar subtree (collapsed panel unidentifiable from the dump)
- **Severity:** S4 · **Kind:** ux-oddity · **Status:** HARNESS (needs pixel lane) / OPEN
- **Area:** sidebar-filetree-and-bookmarks · **Smoke:** SFB-05
- **Repro:** Root a tree, select rows, folder-stats on; inspect the contentView
  tree of the DiagnosticDump.
- **Expected:** Every mounted accordion scroll host has a non-zero size, or a
  zero-sized host is clearly an off-screen overflow region.
- **Actual:** Tree carries 6 `HostingScrollView` + 6 `DocumentView` hosts; one
  `HostingScrollView` and 3 of 4 NSScrollers report zeroSize. The suite's
  `assertSidebarSubtreeMounted` tolerates this (requires only ≥1 non-zero host).
  Likely a collapsed/empty accordion panel envelope, but no a11y id / label text in
  the dump lets us identify WHICH panel — so a latent "collapsed panel draws a
  0-height envelope" glitch vs benign overflow host cannot be settled from JSON.
- **Why not fixed:** Needs the VM pixel lane to settle. No fix landed.
- **Evidence:** Live dump `mdv-step-06.json` view-tree walk: class
  `HostingScrollView` count=6, one with `zeroSize=true`.

### BUG-025 · Status bar shows Ln/Col in Rendered mode (catalog says Ln/Col should be hidden in rendered)
- **Severity:** S4 · **Kind:** discrepancy · **Status:** DOC / OPEN
- **Area:** view-modes · **Smoke:** VM-01
- **Repro:** Open a `.md` (Rendered default). Observe the status bar with
  `currentViewMode=rendered` (confirmed via dump).
- **Expected:** VM-01 step 1 spec: "Status bar shows path; Ln/Col hidden
  (rendered)." There is no caret in the rendered WKWebView, so a line/column
  readout is meaningless.
- **Actual:** Status bar in rendered mode still shows `Ln 1, Col 1 / Lines 11 /
  Chars 146` (source-mode counters). Either the status bar should drop line/col
  positioning in rendered mode, or the catalog is stale. Cosmetic.
- **Why not fixed:** Cosmetic; no fix landed.
- **Evidence:** `docs/uat/evidence/VM-01_markdown-rendered-happy-path.png` (status
  bar bottom: "Ln 1, Col 1  Lines 11  Chars 146") + `.json`.

### BUG-026 · openFileHistory opens a hosted (empty) history view for an UNTRACKED in-repo file (isTracked gate is menu-only)
- **Severity:** S4 · **Kind:** inconsistency · **Status:** DOC / OPEN
- **Area:** git-panel · **Smoke:** GP-10
- **Repro:** Run `test_GP_10_untrackedInRepoOpensEmptyHistory`, or: open a git repo,
  then fire `file-history <repo>/untracked.txt` where `untracked.txt` is inside the
  repo but never `git add`ed.
- **Expected:** Per the `openFileHistory` doc-comment ("No-op when the file isn't in
  a repo / isn't tracked") and GP-10 step 3 (File History menu item disabled for
  untracked files), an untracked file should not produce a history view.
- **Actual:** `openFileHistory` opens a hosted history tab anyway
  (`currentStateKind=hostedView`, `windowTitle='History: untracked.txt'`,
  NSSplitView mounts) showing the graceful "No history for this file." empty state.
  `openFileHistory`'s guard is only `discoverRoot && rel && !rel.isEmpty`
  (`DocumentModel.swift:1183-1186`) — it does NOT check `isTracked`; that check
  lives only in `canShowFileHistory` which gates the MENU item enable-state, not the
  verb. Live-UI menu gating is therefore correct; only the underlying API is looser
  than its comment claims.
- **Why not fixed:** Low severity — graceful empty state, no crash, menu-gated
  correctly in the live app. The doc-comment overstates the API's own guard. No fix
  landed.
- **Evidence:** DiagnosticDump for `file-history` on `untracked.txt`:
  `state=hostedView title='History: untracked.txt'`;
  `Sources/ViewerUI/DocumentModel.swift:1168-1194`.

### BUG-027 · T4 session smokes pollute the user's real Sessions store (persist fires even under the clean-room flag)
- **Severity:** S4 · **Kind:** quality · **Status:** FIXED (2026-06-19, TSK-1024, `0e5645e8`) — AppLauncher now sets `MDV_SESSIONS_DIR=<artifacts>/SessionsScratch` on both spawn paths (the `SessionStore.defaultDirectory` override was already on main); `defaultDirectory` made injectable + 3 host tests. So T4 session smokes write to per-run scratch, never the user's real store.
- **Area:** Sessions — group 7/12 · **Smoke:** cross-cutting (test scratch / persistence)
- **Repro:** Run any `session-open-folder` scripted scenario, then inspect
  `~/Library/Application Support/MarkdownViewer/Sessions/index.json` and the
  per-session `*.json` files.
- **Expected:** Test scratch must never leak into the user's real session store;
  `MDV_SKIP_WORKSPACE_RESTORE=1` implies clean-room isolation.
- **Actual:** `openFolder → persist()` enqueues real index + per-session writes
  regardless of the skip flag (the flag only suppresses RESTORE, not PERSIST). The
  SessionStore directory is hardcoded (`SessionStore.swift:53-69`) with no env
  override, so each scripted-session run appends scratch pills
  (`/var/folders/.../SessionsUAT-*`) that survive in `index.json`; prior UAT groups
  left similar `SidebarBookmarksUAT-*` and `/tmp/*` entries. A real relaunch (no
  skip flag) would surface these as stale pills.
- **Why not fixed:** Recommendation logged (an `MDV_SESSIONS_DIR` /
  `MDV_APP_SUPPORT` env override so T4 session smokes can redirect the store to
  per-run scratch); not yet done.
- **Evidence:** `index.json` after the suite run listed 2 `SessionsUAT-*`
  tmp-rooted pills; the store also held pre-existing `SidebarBookmarksUAT-*`/`tmp.*`
  entries; my own probe's `~/Documents` session was manually removed.

### BUG-028 · set-cross-query script verb does not present the cross-search panel (contradicts catalog "implies show+run")
- **Severity:** S4 · **Kind:** discrepancy · **Status:** DOC / OPEN
- **Area:** plugins-and-mcp-automation — group 9/12 · **Smoke:** SMOKE-PMA-04
- **Repro:** Run a `--script` with `sidebar-set-root <folder>` then
  `set-cross-query NEEDLE` (no prior `show-cross-search`); inspect the per-step
  DiagnosticDump's `isCrossSearchPresented`.
- **Expected:** Catalog PMA-04 step 8 states `set-cross-query NEEDLE (implies
  show+run)` and expects `isCrossSearchPresented == true`.
- **Actual:** The verb only does `model.crossSearchQuery = arg;
  model.runCrossSearch()` (`ScriptVerbDispatch.swift:116`).
  `DocumentModel.runCrossSearch` (`DocumentModel.swift:959`) runs the grep but never
  sets `isCrossSearchPresented`. So a script that omits an explicit
  `show-cross-search` runs the search with the panel closed.
- **Why not fixed:** Test was adjusted to call `show-cross-search` first. Either
  update the catalog or have `set-cross-query` imply `showCrossSearch()`. No fix
  landed.
- **Evidence:** Initial PMA-04 run failed "[PMA04] set-cross-query never presented
  cross-search"; `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:116`;
  `Sources/ViewerUI/DocumentModel.swift:959-984` vs `:928-938` (`showCrossSearch`
  sets it).

### BUG-029 · Media/binary tabs show "Lines 0  Chars 0" in the status bar
- **Severity:** S4 · **Kind:** ux-oddity · **Status:** OPEN
- **Area:** Previews — group 10/12 · **Smoke:** PV-08
- **Repro:** Open an image / audio / pdf / sqlite file and read the bottom status
  bar in `dist/TextView.app`.
- **Expected:** Per catalog PV-08, line metrics do not apply to a media tab — Ln/Col
  is hidden (line==0 sentinel). The text/CSV tab correctly shows "Ln 1, Col 1 |
  Lines 353 | Chars 353".
- **Actual:** Ln/Col IS correctly hidden, but the status bar still renders "Lines 0"
  and "Chars 0" for image/audio/pdf/sqlite tabs. Showing "Lines 0 / Chars 0" for a
  binary/media file is mildly misleading (reads as an empty 0-line document).
  Cosmetic; the literal "Ln/Col hidden" claim is honored.
- **Why not fixed:** Cosmetic. Suggestion logged (hide the Lines/Chars chips, not
  just Ln/Col, for non-text categories); no fix landed.
- **Evidence:** Screenshots `mdv-step-03.png` (image), `mdv-step-07.png` (audio),
  `mdv-step-15.png` (pdf), `mdv-step-19.png` (sqlite) all show "Lines 0  Chars 0";
  `mdv-step-23.png` (CSV, text-backed) correctly shows full line metrics.

### BUG-030 · PDFView content appears blank in same-process cacheDisplay capture (capture-fidelity limit, NOT a render bug)
- **Severity:** S4 · **Kind:** discrepancy · **Status:** NON-BUG (capture limit) / needs pixel lane
- **Area:** Previews — group 10/12 · **Smoke:** PV-03
- **Repro:** Open a multi-page `.pdf` in `dist/TextView.app` and capture the window
  via `DiagnosticDump.captureWindowToPNG` (the `--script` harness path).
- **Expected:** The screenshot shows the rendered PDF page in the center pane.
- **Actual:** The center pane is blank/white in the captured PNG even though the
  dump confirms PDFView is mounted non-zero-sized and the MetadataPanel shows
  correct Pages/Title/Author. Almost certainly because `cacheDisplay` does not
  reliably capture PDFKit's layer-hosted/Metal-backed page content — NOT evidence of
  a real blank pane.
- **Why not fixed:** Flagged so a reviewer does not mistake the screenshot for a
  render bug; a foreground VM pixel test (real WindowServer composite) is needed to
  confirm the page actually paints. Side note: opening the PDF emitted a macOS
  Vision OCR log line `addTextFromVisionDocument: numWordQuads = 5` (PDFKit runs
  on-device OCR — benign, but relevant to perf on large PDFs).
- **Evidence:** Screenshot `mdv-step-15.png`: blank center pane + correct PDF
  metadata panel (Pages 3, Title "UAT Preview Doc", Author "PreviewsUAT"); dump
  confirms PDFView present and laid out non-zero.

### BUG-031 · Smoke catalog claims `flash` is a v2-only verb a v1 reader rejects; the shipped decoder accepts `flash` under /v1
- **Severity:** S4 · **Kind:** discrepancy · **Status:** DOC
- **Area:** walkthrough-and-code-review — group 12/12 · **Smoke:** WCR-03
- **Repro:** Read `Sources/ViewerCore/Walkthrough/WalkthroughScript.swift`
  `Action.init(from:)` — `flash` is in the always-decoded known-kind switch,
  schema-agnostic. Confirmed by
  `WalkthroughSchemaErrorTests.test_flashVerb_underV1Schema_decodesSuccessfully`.
- **Expected:** Per `walkthrough-and-code-review.md` WCR-03 (and lines 22/28), a
  `/v1`-schema script carrying the v2-only `flash` verb should be rejected wholesale
  (`UnsupportedSchemaError`).
- **Actual:** `flash` decodes successfully under BOTH /v1 and /v2 — the decoder is
  schema-agnostic for known kinds. The genuine strict-reject is the unknown SCHEMA
  STRING (`UnsupportedSchemaError`) or an unknown VERB KIND (`dataCorrupted`), not a
  v1-vs-v2 verb gate. The catalog's "flash is v2-only at the wire level" framing is
  inaccurate vs the implementation.
- **Why not fixed:** Catalog/doc mismatch. The T4 suite drives the real reject via
  an unknown verb kind (`teleport`), which correctly rejects the whole load with no
  partial play and no crash. No code change warranted; fix the catalog.
- **Evidence:** `WalkthroughScript.swift` `Action.init(from:)` case `"flash"`;
  `WalkthroughSchemaErrorTests` green. Logged as D-WCR-FLASH in
  `docs/uat/UAT_RUN_undated.md`.

### BUG-032 · Lazy-materialized tab shows a transient .empty in per-step dumps before settling to .loaded
- **Severity:** S4 · **Kind:** ux-oddity · **Status:** NON-BUG (observation note) · **Branch:** `worktree-wf_7f6adec6-3ab-72` (no change; worktree clean)
- **Area:** plugins-and-mcp-automation — group 9/12 · **Smoke:** SMOKE-PMA-04
- **Repro:** Script: `open-lazy b.txt` then `select-tab 2`; capture per-step
  DiagnosticDumps.
- **Expected:** `select-tab` on a lazy tab materializes it to `.loaded`.
- **Actual (as originally observed):** The DiagnosticDump captures ~300ms after each
  verb, so the first 1-2 dumps after `select-tab 2` appeared to show
  `currentStateKind == "empty"` while `materializeIfNeeded`'s async completion was
  in flight; it then settled to `loaded`. A test asserting on the FIRST `b.txt` dump
  rather than the settled state would false-fail.
- **Investigation result (why not a bug):** `materializeIfNeeded`
  (`Sources/ViewerUI/DocumentModel.swift:2969-3040`) flips the lazy tab
  `.empty -> .loading(url)` SYNCHRONOUSLY at line 2980, in the same main-actor turn
  as `selectTab`'s `tabCoordinator.select`, before the detached file read. The dump
  reads live tab state (`DocumentModel.currentState -> tabs.selected?.state`, no
  lagging published copy). So a SELECTED lazy tab transits `.loading` (transient)
  then `.loaded` (settled) and can never appear `.empty` once selected; the
  "transient .empty" in the original evidence is stale, predating that synchronous
  `.loading` flip. The model-republish load-bug fix (commit 61c1aef) is intact
  (`updateDerived()` in the materialize completion, line 3022); the tab settles to
  `.loaded` and never lands in `.error`. The referenced test
  `test_PMA04_scriptVerbDispatch` already asserts on the SETTLED last dump
  (`bDumps.last`), so it does not false-fail.
- **Why not fixed:** No product bug to fix — correctly self-classified non-bug
  observation. No code change made; worktree is clean.
- **Scope note:** The entire `Tests/ViewerUITests/uat/` suite and `docs/uat/` (this
  smoke + run log) are UNTRACKED scratch files in the shared checkout, absent from
  the worktree branch and any commit; the test is also T4 `LiveAppTestCase`
  (VM-only) that self-skips on the host and is not part of the headless gate.
- **Evidence:** Live dump progression (test_PMA04 observation run): step04/05
  appeared `state=empty`, step06-11 `state=loaded` and stable; logged in
  `docs/uat/UAT_RUN_undated.md` PMA-04 section.
- **Gate note:** Headless gate tier enforcement passed ("no heavy-tier test ran").
  Two reported host-only failures are documented pre-existing non-regressions (both
  green on CI/VM) and touch nothing in `materializeIfNeeded` / tab state / the dump
  path: `#201 MarkdownLinkPolicyTests.test_decide_sameDocFragment_isAllowed`
  (Foundation URL-fragment parser regression on macOS 26 / Darwin 25.x;
  `BACKLOG.md:638`, `LESSONS.md:1459`) and
  `FoldBenchTests.testCold10KLineJSONUnder250ms` perf jitter (250.78ms vs 250.0ms
  threshold).
