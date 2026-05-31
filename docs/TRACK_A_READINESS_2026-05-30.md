> Provenance: track-a-readiness workflow wf_72fc1cf6-c0c (15 read-only agents — 7 findings-verification + 7 Track-A planning + synth) on 2026-05-30. Verifies the 172 pre-launch audit findings against live code on audit/pre-launch and plans the hardening-report Track A. Status: verification + plan, no code changed.

# Pre-Launch Audit — Verification, Status & Track-A Roadmap

**Branch:** `audit/pre-launch` (HEAD `954a8f9`) · **Audit:** `docs/PRELAUNCH_AUDIT_2026-05-30.md` (172 findings) · **Verification discipline:** read-only, file:line-cited, verified-from-code vs inferred distinguished.

> **Read this first.** Every fix discussed below lives on `audit/pre-launch`, **not on `main`**. `main` @ `e05b966` carries the 2026-05-29 next-steps fanout (the branch that *introduced* the `lsp.json` RCE vector, SEC-001/002). Until `audit/pre-launch` lands on `main`, **production main has zero of these fixes and still ships the RCE-class exposure.** This is the single highest-leverage fact in the document.

---

## 1. Pre-launch findings status

### 1.1 Verified findings table

Findings below were individually verified against code on `audit/pre-launch`. The 172-finding corpus is dominated by S2/S3 items fixed in bulk across G9–G13; the rows here are every finding that was *independently re-verified* this pass (the S0/S1 spine + the audited S2/S3 sample + every surfaced item). Status legend: **FIXED** (complete + tested), **PARTIAL** (capability present, not fully wired or scoped narrower than the finding), **SURFACED** (correctly not auto-fixed, awaiting decision), **REGRESSED** (claimed fixed but a later change undid it).

| id | sev | location | status | evidence |
|----|-----|----------|--------|----------|
| SEC-001 | S0 | `LSPLanguage.swift:312-449`, `LSPDiscovery.swift:122-136` | **PARTIAL** | Interim hardening present + tested: `isOverrideCommandTrusted` requires binary in non-group/world-writable dir **and** path resolved OUTSIDE workspace subtree (symlink-resolved, component-wise). In-repo-binary RCE genuinely closed. PARTIAL **by design** (audit line 109): real fix is a consent trust-UI; a malicious `lsp.json` pointing at a trusted system path is still honoured verbatim with attacker `args` (`:343-348`). |
| SEC-002 | S1 | `LSPClient.swift:144-146`, `LSPLanguage.swift:338-340,431-449,207-264` | **PARTIAL** | Override path scrubbed (`scrubbedLaunchEnvironment` base, tested). **But the default-discovery path is NOT scrubbed**: every default launcher passes `environment: nil`; `LSPClient.init` only sets `p.environment` when non-nil (`:144-146`), so normally-discovered `sourcekit-lsp`/`pyright`/`tsserver` still inherit full parent env incl. `*_TOKEN`/`AWS_*`/`ANTHROPIC_API_KEY`. **The audit's SEC-002 statement is still literally true for the common no-`lsp.json` case.** |
| SEC-003 | S1 | `TextDisplayView.swift:1060-1071,1096-1104,919-922`; `RegexComplexityGuard.swift:54-111` | **FIXED** | Compile-time `RegexComplexityGuard.reject` (negative-cached) + 250 ms `boundedMatches` deadline, live-wired into find-bar keystroke path. Stronger than the finding asked. |
| LSP-lifecycle | S1 | `LSPPool.swift:148-192,708-720`; `main.swift:66,408-414` | **FIXED** | Reaper started at launch; `closeAll()` bridged into `applicationWillTerminate` with 2 s bounded wait. Both halves closed + fake-server tested. |
| RC-1 | S1 | `LSPClient.swift:833-844` | **FIXED** | `deinit` detaches stderr handler, `terminate()`, closes stdin. SIGTERM-only (no SIGKILL) acceptable — deinit can't await. |
| CR-02 | S1 | `LSPClient.swift:770-818` | **FIXED** | `shutdown()` escalates graceful→SIGTERM→poll→SIGKILL→reap-once, `didReap`-guarded. Mirrors `PluginSubprocessHost`. |
| PARSE-01 | S1 | `LSPFraming.swift:23,31,90-130`; `LSPClient.swift:218-243` | **FIXED** | 32 MiB body cap + 16 KiB header cap rejected before allocation; O(n²) header-scan fixed via resume cursor. Bundles MAGIC-001. |
| CORR-1 | S1 | `TabsState.swift:127-151`; `EditorCoordinator.swift:501-522` | **FIXED** | `openOrReveal` preserves `isDirty`; close-prompt gates on it. Complete. |
| UDC-2 | S1 | `DocumentModel.swift:1904-1942`; `TabCoordinator.swift:451-458` | **FIXED** | `applyReload` rebases a **clean** editor buffer from reloaded file; dirty buffers gated upstream. Stale-buffer→overwrite-newer-disk vector closed. |
| EDIT-drift | S1 | `codemirror.html:116-157,826,853`; `CodeMirrorEditorView.swift:508-516`; `CodeMirrorBridge.swift:544` | **FIXED** | Drift recovery dispatches `.flushChanges`→`flushChangesForced`→`emitChange(true)`, bypassing the `lastEmittedText` guard. The exact no-op that was the bug. *(Cleanliness wart: stale `window.flushChanges` shim at `codemirror.html:1178` — dead, not a regression.)* |
| EDIT-attrs | S1 | `EditorBuffer.swift:218-392`; `EditorBufferTests.swift:277-339` | **FIXED** | Atomic save fd-snapshots + replays mode/owner/xattrs before rename. 0600/+x/xattr tests pass. APFS ACLs ride along as xattrs. |
| EDIT-nil-fp | S1 | helper `EditorBuffer.swift:129-138`; call site `DocumentModel.swift:1857-1877` | **PARTIAL** | `hasUnknownDiskState` implemented + tested but **has zero non-test callers**. `reloadCurrentFile(matching:)` still only checks `hasExternalEdit` (`:1866`); unknown-disk-state reload over a dirty editor falls through **without a prompt**. Unsaved bytes saved by a separate backstop (cached buffer + `!existing.isDirty` guard) — silent clobber mitigated, **but the specified fix is not wired**. |
| RWC-1 | S1 | `HighlightCacheActor.swift:147-168`; `ContentView.swift:550-554`; `DocumentModel.swift:1625-1627`; `TextFileLoader.swift:107,120` | **FIXED** | `modifiedTime` in `HighlightCacheKey`, plumbed end-to-end. Same-byte-length rewrite now produces cache miss. *(Pre-existing benign TOCTOU: mtime stat'd before read at `:107`.)* |
| SCALE-1 / MAGIC-002 | S1 | `TextFileLoader.swift:62-100` | **FIXED** | Cap raised 32 MB→**64 MB**, re-architected as the widest funnel cap (≥ CM6's 50 MB). *(Note: also separately changed on `fix/large-file-readonly` — not inspected; reporting `audit/pre-launch` only.)* |
| SCALE-2 | S1 | `ProcessRunner.swift:205-374`; `GitClient.swift:573-587` | **FIXED** | `maxOutputBytes` combined-stream cap, SIGTERM→SIGKILL on overflow, `Result.truncated`. Git=512 MB, JQ=256 MB. Fully wired. |
| FW-1 | S1 | `FileWatcher.swift:14-224`; `DocumentModel.swift:1955` | **PARTIAL** | Core `onLost` infra complete + fires once on exhaustion. **But the single app call site never passes `onLost:`** → an exhausted watcher silently zombies. Exact FW-1 symptom; production behavior unchanged. |
| FW-2 | S1 | `FolderWatcher.swift:80-341` | **FIXED** | `kFSEventStreamCreateFlagWatchRoot` + `RootChanged` scan + `onRootChanged` closure, wired into event path. (SidebarModel consumption out of finding scope.) |
| SQL-01 / PARSE-02 | S1 | `SQLiteBrowserView.swift:122-288`; `SQLiteReader.swift:60-227` | **FIXED** | User SQL off `@MainActor` on serial `dbQueue`; `sqlite3_progress_handler` interrupt every 50 k ops; live Cancel button; monotonic `runToken`. Bonus SQL-02 authorizer + readonly. |
| PERSIST-01 | S1 | `SessionState.swift:142-189` | **FIXED** | `hydrate()` resolves target by **path**, skips missing tabs, re-finds in compacted list — never applies stale index. *(Audit-cited range `140-161` slightly off.)* |
| PERSIST-04 | S1 | `SessionsCoordinator.swift:52-378`; `SessionStore.swift:94-132` | **FIXED** | `.newerSchema` sets `indexWriteBlocked`, non-destructive banner; per-session `SchemaProbe`. **STALE CITED PATH:** owner moved to `Sources/ViewerCore/Sessions/`. |
| REPUB-1 | S1 | `SessionState.swift:62-78` | **FIXED** | Banned full-`DocumentModel` `objectWillChange` forward entirely removed; only an explanatory comment remains. Invariant test pins zero republishes with negative control. |
| SCALE-3 | S1 | `SidebarModel.swift:317-422` | **FIXED** | Per-entry `resolvingSymlinksInPath` syscall eliminated (lexical `repoRelativePath`); root resolved once; FNV-1a token replaces O(N) dict walk. **STALE CITED PATH:** audit said `:286-303`. |
| OBS-1 | S1 | `Diagnostics.swift:28-63`; `DiagnosticDump.swift:30,181`; `main.swift:283` | **FIXED** | SIGUSR1 trap gated behind `diagnosticsTrapEnabled` (DEBUG \|\| `MDV_ENABLE_DIAGNOSTICS=1`); release never installs handler. Content redacted to `<redacted>` in release. |
| OBS-2 | S1 | `Diagnostics.swift:95-267` | **FIXED** | `writeDataPrivate` `open(...,0o600)`+`fchmod` (defeats umask race); PNG tightened; stale-artifact sweep on launch. |
| CR-06 | S2 | `DiagnosticDump.swift:66-89` | **FIXED** | `responds(to:)`-guarded `recursiveDescription` — future-AppKit-safe. |
| OBS-3 | S1 | `PluginSubprocessHost.swift:416-488` | **FIXED** | Audit log `0o600` + dir `0o700`, re-chmod on first write. |
| OBS-6 | S2 | `PluginSubprocessHost.swift:200-463` | **FIXED** | Byte-free / path-free error descriptors; audit log records basename only. |
| SEC-007 | S1 | `PluginSubprocessHost.swift:157-318` | **FIXED** | Symlink-resolved bin containment; sibling-prefix trap closed (`/a/plugins` ≠ `/a/plugins-evil`). |
| CORR-10 | S2 | `main.swift:249-279` | **FIXED** | Opens every argv path; one bad path doesn't skip the rest. |
| WV-4 | S2 | `MarkdownRenderedView.swift:179-665` | **FIXED** | Post-load nav-policy guard cancels top-level `.other` nav to `file:`/`data:` after first load; pure testable `decide()` kernel. |
| RC-6 | S2 | `MarkdownRenderedView.swift:232-252` | **FIXED** | `dismantleNSView` teardown — stops load, nils delegate, clears scripts. |
| WV-7 | S3 | `MarkdownRenderedView.swift:117-289` | **FIXED** | Sole-owner user-script invariant asserts (empty→exactly-N→zero). |
| RWC-4 | S2 | `TreeSitterEngine+Folds.swift:319-394` | **FIXED** | Fold cache now per-language bounded LRU keyed on `contentHash` (max 8). |
| SCALE-7 | S2 | `HexView.swift:47-241` | **FIXED** | 50 k match cap + "N+ matches" label; pure host-testable `HexMatchCap`. |
| PARSE-05 | S2 | `BinaryFileLoader.swift:40-106` | **FIXED** | Resolved-path `.typeRegular` guard (fifo/dir/socket rejected); read-derived truncation (no TOCTOU pre-stat). |
| A11Y-03 | S2 | `HexView.swift:134-720` | **FIXED** | Hex-dump truncation a11y label + chevron labels. |
| UDC-1 | S1 | `DropRouter.swift:48-149` | **FIXED** | Existence filter moved into shared prod router (`Box.fire`), injectable `fileExists`. Prod + test now exercise the same path. |
| UDC-9 | S1 | `DropRouter.swift:31,73-141` | **FIXED** | 5 s provider deadline; `onResolved` fires exactly once (all-resolved \|\| deadline). Forward-progress guarantee. |
| UDC-7 | S1 | `TabBar.swift:23-91` | **FIXED** | Tab drag encodes stable UUID, resolves to live indices at drop time, bails if either tab closed mid-drag. |
| SIGN-01 | S1 | `sign-and-notarize.sh:94-209` | **FIXED** | Stale-bundle path eliminated; single fresh `TextView.app` signed+notarized; SIGN-14 pre-submit timestamp guard. |
| SIGN-02 | S1 | `build-app.sh:180-185`; `sign-and-notarize.sh:117-127` | **PARTIAL** | Notarize path gives each grammar dylib a derived id; **but the reverted local-dev `--deep` pass stamps every dylib with the app bundle id** — verified live in dist bundle (`libTreeSitterRustLazy.dylib` Identifier=`com.markdownviewer.MarkdownViewer`). Shared-id behavior persists in the build most builds use. |
| SIGN-03 | S1 | `Info.plist:27-28`; `verify-app.sh:49-61` | **FIXED** | `LSMinimumSystemVersion=15.0` + a guard deriving the floor from `Package.swift`. |
| DEP-001 | S1 | `gen-third-party-notices.sh`; `build-app.sh` (missing copy); dist `Resources/` | **PARTIAL** | Generator + root file + CI content test all correct. **But `build-app.sh` never copies the file into `Contents/Resources/`** (grep finds no reference; dist bundle lacks it) despite the generator's own comments claiming it does. Shipped `.app` lacks bundled attribution. One-line `cp` fix remains. |
| TC-01 | S1 | `.github/workflows/pr.yml:14-23` | **FIXED** | CI `runs-on: macos-15` + pinned Xcode 16. |
| G14-REVERT | — | `build-app.sh:171-185`; `check-bundle-size.sh:41`; commits `663c6a1`,`b8d3c66` | **FIXED (but see SIGN-02)** | Inside-out signing revert confirmed: clean single `--deep` pass; exec sub-cap 16→**18**. The derived-id logic survives **only** in `sign-and-notarize.sh` — that asymmetry *is* the SIGN-02 partial. *(Stale doc: `check-bundle-size.sh:3-5` header still says "16 MB".)* |

**Surfaced (verified NOT auto-fixed, correct per audit intent):** WV-3 (`codemirror.html:9` meta-CSP retained; no `WKURLSchemeHandler` in `Sources/`), CR-03/OBS-4 (no MetricKit/crash hooks anywhere) — plus the full §2 list below.

### 1.2 Counts & headline

| status | count (verified spine) | notes |
|--------|----|-------|
| **FIXED** | 33 | complete + tested |
| **PARTIAL** | 5 | SEC-001, SEC-002, EDIT-nil-fp, FW-1, SIGN-02, DEP-001 → *(6; SEC-001 is partial-by-design)* |
| **SURFACED** | 31 | §2 — correctly deferred, decision-gated |
| **REGRESSED** | 0 | see G14 note below |
| **CANNOT-VERIFY** | 2 | the "~196 strings" l10n count; Phase-9 signing end-state (needs a real build+notarize run, out of read-only scope) |

**Headline answer — "how many of the 172 are already fixed, and where?"**

- The audit declares **141 fixed across 15 groups (G1–G15)** and **31 surfaced**. This pass re-verified the S0/S1 spine + an S2/S3 sample + all 31 surfaced. **Of the re-verified spine: 33 fully fixed, 6 partial, 0 regressed.** The bulk S2/S3 fixes (G9–G13) spot-checked clean — none stubbed, none regressed.
- **WHERE: all of it is on `audit/pre-launch` (HEAD `954a8f9`). NONE is on `main` (`e05b966`).** `main` is the branch where the `lsp.json` RCE *landed* (2026-05-29 fanout) and where it remains **unmitigated**. Shipping `main` today ships every S0/S1 finding unfixed.
- The **6 partials are the real residual risk** even after consolidation, ranked:
  1. **SEC-002** (S1, *most important nuance*) — env-scrub closed only on the attacker-controlled override path; the **common default-discovery path still leaks `AWS_*`/`*_TOKEN`/`ANTHROPIC_API_KEY` to every LSP child**. A compromised legit LSP server (supply chain) harvests creds. **One-line fix:** scrub at `LSPClient.init` for the `nil` case, or have default launchers pass `scrubbedLaunchEnvironment()`.
  2. **EDIT-nil-fp** (S1) — `hasUnknownDiskState` written but never called; unknown-disk-state reload over a dirty buffer shows no conflict prompt. Bytes mitigated by a backstop; the *specified* fix isn't wired. **Fix:** call it in the `DocumentModel.swift:1862` guard.
  3. **FW-1** (S1) — `onLost` capability added to core but not wired at the one app call site (`DocumentModel.swift:1955`); exhausted watcher zombies silently. **Fix:** pass an `onLost:` closure surfacing a "live updates stopped" hint.
  4. **SIGN-02** (S1) — local-dev `--deep` build still shared-id's all grammar dylibs (notarize path is fine). Intentional post-revert tradeoff; tracked Phase-9.
  5. **DEP-001** (S1) — attribution file generated but never copied into the `.app`. Redistribution obligation unmet until a one-line `cp` lands.
  6. **SEC-001** (S0) — partial **by design**; interim hardening real, full trust-UI surfaced (§2).

**On the claimed "G14 signing episode" / regressions:** No finding is *claimed-fixed-but-regressed* in the strict sense. The G14 story is a **deliberate revert, not a silent regression**: the inside-out (no-`--deep`) signing attempt broke `.bundle` codesign under `--options runtime` and was reverted (`663c6a1`), restoring `--deep`. The consequence — local builds shared-id their dylibs — is captured as **SIGN-02 PARTIAL**, and the derived-id logic correctly survives in the notarize path. **Flag loudly anyway:** this is the one place where "the fix" means two different things on two different paths (notarize vs local-dev), and anyone reading "SIGN-02 fixed" without the path qualifier will be wrong about the day-to-day build.

---

## 2. The 31 surfaced findings

All 31 verified genuinely NOT auto-fixed by direct code inspection. Four decision-categories:

### (a) Decision-then-fixable — scoped code lands once an owner answers a product/legal/policy question

| id | sev | location | decision awaited |
|----|-----|----------|-----------------|
| SEC-001 trust-model UX | S0 | `LSPLanguage.swift:278-358` (interim only; zero `WorkspaceTrust`/`allowlist` hits) | One-time prompt vs persisted per-workspace allowlist; where persistence lives. |
| DEP-002 app LICENSE | S1 | repo root (no `LICENSE`; `Package.swift` no license field) | Proprietary vs OSS. Distribution blocker. |
| PERSIST-05 v1→v2 migration | S2 | `SessionsAppCoordinator.swift:76-89`; `SessionState.swift:8` (v1 reader deliberately retired) | Did any pre-launch build with the v1 `Workspaces/_last.json` shape reach real users? If yes, re-add a one-shot migration. |
| bundle-id / name rename | S1/S2 | `Info.plist:8,10,12,16,83` (display `TextView`, exec/id `MarkdownViewer`) | Keep TCC-stable id + accept the name split, or coordinated rename that resets all TCC grants (one-way for installed users). |
| BR-01 worktree cleanup | S2 | `.claude/worktrees` = **124 GB / 60 dirs** (larger than the cited 89 GB) | Confirm worktrees merged/abandoned, then prune. Destructive — needs explicit confirmation. |

### (b) Deferred-feature / architecture — one-way doors, "do NOT start pre-launch"

| id | sev | location | decision awaited |
|----|-----|----------|-----------------|
| RC-01..08 reusable-core epic | S1 | `DocumentModel.swift` (~2451 LOC `@MainActor`); `docs/CORE_DESIGN_HARDENING_2026-05-30.md` | §2 product-identity (macOS app vs reusable core?) + a committed second front-end. |
| PROTO-1..5 protocol boundary | S1 | `MCPServer.swift:117-122,248-257`; `main.swift:38-47` (notifications dropped; `--mcp-stdio` not headless; MainActor choke; no per-req budget/cancel) | Option C in-process push channel + headless-core extraction commitment. |
| API-01/02/09 NSColor in core public API | S1 | `SyntaxTheme.swift:15-114`; `FileTreeRecency.swift:84-121` | `ThemeColor` abstraction decision (one-way published-API break). |
| WV-3 header-CSP via `WKURLSchemeHandler` | S2 | `HTMLRenderer.swift:47`; `codemirror.html:9` (meta-CSP; zero scheme-handler hits) | Adopt custom scheme handler (changes base-URL/relative-image semantics) vs keep meta-CSP interim. |
| SCALE-4/SCALE-11 mmap pager | S1/S2 | `TextFileLoader.swift:62-86` (full-read, 64 MB ceiling; zero `mmap`/`MmapPager` hits) | Build a paged multi-GB viewer, **or** downgrade the DESIGN.md "GB via Source" claim to the real 64 MB ceiling. |

### (c) Phase-9 distribution — deferred by design until public ship

| id | sev | location | decision awaited |
|----|-----|----------|-----------------|
| SIGN-08 `--deep` removal / inside-out signing | S1 | `sign-and-notarize.sh:131,160,170`; `build-app.sh` (reverted `663c6a1`) | A real build+notarize run to safely migrate off `--deep` (FinderInfo/runtime issue). |
| SIGN-09 DMG packaging | S1 | `scripts/` (no `hdiutil`/`create-dmg`) | Public-ship distribution format (DMG vs zip vs pkg). |
| SIGN-10 Sparkle auto-update | S1 | absent in `Sources/`+`scripts/` | Ship auto-update? Sparkle dependency approval + appcast/feed-signing. |
| SIGN-11 Developer-ID + clean spctl | S1 | `sign-and-notarize.sh:64-213` (expects spctl-fail pre-notarization) | Public-ship go: obtain Developer ID cert, run notarization end-to-end. |

### (d) Policy

| id | sev | location | decision awaited |
|----|-----|----------|-----------------|
| I18N-03 Trojan-Source bidi | S2 | absent (zero bidi-control detection) | Strip vs visualize vs warn on bidi-override chars. |
| I18N-06 localization | S2 | absent (zero `NSLocalizedString`/`.strings`/`.xcstrings`; ~196 hardcoded strings, **count unverified**) | Ship English-only vs invest in a l10n pass. |
| CR-03/OBS-4 MetricKit/crash telemetry | S1 | absent (zero MetricKit/crash hooks) | Telemetry policy: add at all? opt-in vs opt-out? what/where? (currently zero egress) |
| UX-11 security-scoped bookmarks | S2 | absent; app non-sandboxed (TCC entitlements only) | Adopt App Sandbox? (then bookmarks required) — one-way-door-ish file-access model change. |
| UIRESP-12 clickable timeline | S2 | `WalkthroughPlayerView.swift:170-201` (dropdown `stepsMenu`, no scrubber) | UX sign-off on a clickable walkthrough scrubber (additive hover was auto-fixed G12). |

---

## 3. Track A plan

Five Track-A items. Each has a **read-only deliverable available now** and **code gated behind a decision + branch consolidation**. Track A = the *no-regret* core-hardening prerequisites the reusable-core effort wants — adoptable **post-launch** without committing to the Track-B one-way door, **except** where noted.

### A1 — De-`@MainActor` the core (steps 1–7 no-regret; step 8 = Track-B)

| field | detail |
|-------|--------|
| **Scope** | Remove the hard `@MainActor` binding from ViewerCore so orchestration types can run off-main, without re-introducing the data races the annotation papers over. |
| **Corrected fact** | The "18 files" figure is the raw grep count and is **wrong**. **11** ViewerCore files carry *live* `@MainActor`; 7 grep hits are comment-only (`FileTreeRecency:137`, `FolderWatcher:19,70`, `FoldRegion:11`, `LSPClient:120`, `LSPPositionConverter:213`, `LSPProtocol:192`, `SQLiteReader:297`). The design doc (`CORE_DESIGN_HARDENING:26,135,147`) needs this 11-vs-18 correction. |
| **Key insight** | Most core `@MainActor` types are **not** suppressing internal races — they already self-protect (`PluginGrantStore`=NSLock, `LSPClient`/`LSPPool`=actors, `FolderWatcher`/`PluginSubprocessHost`=`@unchecked Sendable`+locks). The annotation provides *implicit serialization with DocumentModel/SwiftUI*. The genuine race exposure is concentrated in **(a)** the two LSP stores' `@Published` dicts (mutated off-actor via `LSPClient.onDiagnostics` → `DocumentModel.bootstrapLSP` `Task{@MainActor}` at `:198-208`), and **(b)** the plugin registries' plain `var` arrays/dicts. |
| **Files** | `SessionsCoordinator.swift:31,38,44-50` (only core Combine importer), `LSPDiagnosticsStore.swift:15,18`, `LSPNavigationStore.swift:11,45-54`, `PluginRegistry.swift:23,30,65`, `SidebarSectionRegistry.swift:15,43,52,64`, `PluginsBootstrap.swift:14`, `RowCounterPlugin.swift:33,50`, `AutomationHost.swift:14`, `MCPToolCatalog.swift:11`, `MCPServer.swift:189-268`, `WalkthroughEngine.swift:19,166`; keystone `DocumentModel.swift:14` + 3 coordinators. |
| **Sequenced steps** | 0. branch consolidation (prereq). 1. **Decide the isolation target** (gate). 2. stateless types (`MCPToolCatalog`/`PluginsBootstrap`/`RowCounterPlugin`). 3. `AutomationHost`+`MCPServer` (generalize the existing `runOnMainActor` off-main→main template). 4. **the two LSP stores** (highest race risk — replace `@Published` + give a serial executor *before* dropping `@MainActor`). 5. plugin registries (lock/actor + R21 per-session isolation). 6. `SessionsCoordinator` (de-`@MainActor` **and** de-Combine together). 7. `WalkthroughEngine`. 8. **extract DocumentModel orchestration into headless core** (Track-B; months). 9. CI `-strict-concurrency=complete` + TSan on the LSP-callback + plugin-load seams. |
| **Blast radius** | Wide but shallow per-file. `DocumentModel` is the convergence point. The two LSP stores are `@ObservedObject`-bound in SwiftUI (`LSPProblemsPanel:17`, `LSPNavigationPanel:24`) **and** off-actor-mutated — touching isolation changes a UI-binding contract **and** a concurrency contract at once. `@Published`/`ObservableObject` is itself main-actor-coupled, so de-`@MainActor` and de-ObservableObject are **entangled** for the 3 store/coordinator types. `SidebarSectionRegistry.Entry.provider`'s `@MainActor` closure type is public plugin API. |
| **Risks** | **Silent data race** (the core hazard): drop `@MainActor` on the LSP stores without a replacement serial executor → unsynchronized `Dictionary` write under concurrent read = heap corruption, not a clean error. 4 core types use `@unchecked Sendable`/`nonisolated(unsafe)` escape hatches the Swift-6 compiler **won't** flag — only TSan catches a regression. Tier-B plugin providers do a synchronous subprocess wait inside the `@MainActor` closure. Branch-soup (R28). |
| **Dependencies** | Branch consolidation; de-Combine (entangled); in-process push channel (provides the off-main state-delivery to replace `@Published`); worker-pool/per-doc-serialization design; Core↔UI boundary shape (Option C) for step 8. |
| **Effort** | Steps 1–3: ~3–5 d (low risk, mechanical). Steps 4–7: ~2–4 wk (race work + `@Published` replacement). Step 8: genuine months (Track-B). No-regret core-side (1–7): ~1 month assuming isolation decided + branches consolidated. |
| **Deliverable now** | Corrected 11-file inventory w/ file:line; per-type race classification (races vs race-free/stateless vs already-self-safe); the single load-bearing race seam cited; 9-step sequence; 2 stale-fact corrections for the design log. **Gated:** all annotation/`@Published`→AsyncStream/executor edits + the DocumentModel extraction. |

### A2 — Purge NSColor/NSRange/NSAttributedString from core value types → portable Codable forms

| field | detail |
|-------|--------|
| **Scope** | Make ViewerCore value types Foundation-only + Codable; push AppKit conversion to the ViewerUI edge. |
| **Verified surface** | **NSColor: only 2 files** — `SyntaxTheme.swift` (fields `:15-19`, `color(for:)` `:21`, `hex` `:104`, `resolved(forAppearance:)` `:98`, the smelly `@retroactive @unchecked Sendable` ext `:111-114`) and `FileTreeRecency.swift:94-124` (the *only* genuinely appearance-dynamic color). **NSRange carriers (2):** `FindMatch.range` (`FindEngine.swift:30`, MCP-serialized at `MCPToolCatalog.swift:167-168`) and `HighlightRun.range` (`HighlightRun.swift:7`). All other NSRange is internal-algorithm-only (stays). **NSAttributedString: none in core** as a value type — the build lives in ViewerUI `TextDisplayView.swift:1010-1034`. **13 error enums** lack `Codable` (most trivial; non-trivial = `String.Encoding` payloads in `EditorWriteError`/`TextFileLoader.DecodeResult`). |
| **New types** | `RGBAColor{r,g,b,a: Double}` + `OffsetRange{location,length: Int}`, both `Codable+Hashable+Sendable`, in **ViewerKit** (the no-AppKit base). |
| **Files / 4 edge seams** | The only conversion seams: `TextDisplayView.swift:1021-1030` (theme color + run range), `FindMatchMinimapView.swift:71` (gutter bg), `SidebarView.swift:853` (recency stripe + appearance pick), `DocumentModel.swift:1592` (theme appearance resolution). `MCPToolCatalog.swift:167-168` needs **no change** (field names match). |
| **Blast radius** | MEDIUM, well-contained. **No persisted-data migration** — only `SyntaxTheme.Name` (enum rawValue) is in `SessionState`; the color/range carriers are never serialized to disk. One behavioral subtlety: `FileTreeRecency`'s dynamic-provider NSColor auto-re-resolves on appearance change; moving the light/dark pick to SwiftUI relies on `body` re-eval on `colorScheme` change (correct, but **VM-verify**). |
| **Steps** | 1. land `RGBAColor`+`OffsetRange` in ViewerKit. 2. add edge-conversion exts in one `AppKitBridging.swift`. 3. migrate `HighlightRun.range`. 4. migrate `FindMatch.range`. 5. migrate `SyntaxTheme` (delete the retroactive Sendable ext; move `resolved(forAppearance:)` out to the edge as name-based selector). 6. migrate `FileTreeRecency.color` (return per-tier light/dark pair; pick in `SidebarView`). 7. error-enum `Codable` in waves (trivial → `String.Encoding`-rawValue → process enums). 8. confirm `import AppKit` gone from both files; host build + ViewerCoreTests. |
| **Risks** | **Color-space shift**: `SyntaxTheme` uses `srgbRed:` but `FileTreeRecency` uses `calibratedRed:`/`calibratedWhite:` — round-tripping calibrated through flat sRGB **shifts** rendered colors. Decision: standardize sRGB (accept tiny stripe shift) vs carry a colorspace tag. **UTF-16 vs UTF-8**: brief asks UTF-8 byte offsets, but *every* current consumer (NSAttributedString, NSTextView, SwiftTreeSitter, LSPPositionConverter) is UTF-16 — **strong recommendation: keep `OffsetRange` UTF-16 now**, defer UTF-8 to a separate tracked change (contradicts the literal brief). Merge conflicts on high-traffic files if done pre-consolidation. |
| **Dependencies** | Branch consolidation (it's a reusable-core prereq, shouldn't race 3 branches editing `SyntaxTheme`/`DocumentModel`). Sibling to A1 (`@MainActor` purge) — **this value-type purge can land FIRST** (independent, lower risk). Owner decision on RGBAColor/OffsetRange home (ViewerKit recommended). |
| **Effort** | Code ~1.5–2 d. The error-enum Codable is mechanical; color-space + appearance-resolution relocation are the only thought-heavy parts. |
| **Decision gates** | (1) OffsetRange unit — UTF-16 (recommended) vs UTF-8. (2) RGBAColor color space — flat sRGB (recommended) vs colorspace tag. |
| **Deliverable now** | Full occurrence inventory (carrier-vs-internal classified); replacement-type spec; the 4-seam edge map; 13-enum Codable checklist; 8-step sequence. **Gated:** type creation + field swaps + edge wiring. |

### A3 — Core unit-of-content String → (bytes, encoding, EOL); fix save-path byte-image corruption

| field | detail |
|-------|--------|
| **Scope** | Make the editor save path byte-faithful for the encodings/EOLs the loader already accepts (UTF-8±BOM, UTF-16 LE/BE±BOM, CP1252, Latin-1; LF/CRLF/CR). Open→edit→save = clean byte-image diff on the edited region only. |
| **Two verified corruptions** | **(1) BOM loss:** `TextDecoder.decodeViaBOM` strips BOM on load (`TextFileLoader.swift:262,268,274`), the encoding carries no "had-BOM" bit, and `EditorWriter.save` does `text.data(using:)` — `.utf8` emits no BOM, `.utf16` emits **native-endian** BOM. A UTF-8-BOM file silently loses its BOM; a UTF-16 file can flip endianness. **(2) EOL normalization:** CM6 sets no `lineSeparator` facet (`codemirror.html:798-801`), so `doc.toString()` always serializes `\n`. Any CRLF/CR file after one edit saves as all-LF — a whole-file diff. |
| **Recommended model** | `String + EncodingProfile{encoding, hadBOM, eol}` captured at load, re-materialized to bytes **only at the save boundary**. **Not** raw Data in-memory (every consumer needs a String; CM6 owns the live doc). **Not** CM6-`lineSeparator`-CRLF (would make every UTF-16 offset consumer see `\r\n` as 2 units — huge blast radius across Find/LSP/CMEditApplier). |
| **Out of scope (verified display-only):** | `CSVParser:144-279`, `FindEngine:76-114`, `DiffHighlighter:19-36` read the decoded String and never write — **no change needed** (corrects the premise they're in the blast radius). |
| **Files** | `TextFileLoader.swift:11-279` (add `eol`+`hadBOM`, thread through), `EditorBuffer.swift:24-303` (carry profile; rewrite serialize step), `EditorCoordinator.swift:350-444` (pass profile; fix post-save `byteCount` at `:411-412` to use serialized bytes), `StatusBar.swift:147-224` (EOL/BOM readout), `EditorBufferTests.swift:121+` (byte-image round-trip matrix). |
| **Blast radius** | Contained to ViewerCore + 2 ViewerUI touch points. **No new deps. No `@MainActor`/NSColor/Combine entanglement** (TextFile/EditorBuffer already Sendable). Critical ripple: `byteCount` must equal real on-disk size everywhere (BOM+CRLF) or the external-edit fingerprint + RWC-1 cache keys mis-fire. |
| **Risks** | **EDIT-drift interaction** — a byte-faithful save built on a buffer that diverged from the CM6 doc still saves wrong bytes faithfully; the corruption story is incomplete until both land (EDIT-drift is FIXED on this branch, §1). **UTF-16 auto-BOM trap** — must encode via `.utf16LittleEndian`/`.utf16BigEndian` (no auto-BOM) and prepend BOM manually. Mixed-EOL files collapse to dominant (documented behavior choice). |
| **Dependencies** | Branch consolidation — touches `EditorBuffer`/`EditorCoordinator`, also edited by unmerged `fix/large-file-readonly`, `fix/modebar-republish-and-panel-toggles`, and the G4 group. Must preserve the EDIT-attrs metadata-replay (composes — operates on final bytes). |
| **Effort** | ~2–3 d, mostly the test matrix + UTF-16 endianness edge cases. |
| **Decision gate** | In-memory EOL policy: **normalized-LF + re-apply at save** (recommended) vs CM6 `lineSeparator` preserve-CRLF-live (much larger blast). |
| **Deliverable now** | Two-bug root-cause w/ file:line; the display-only correction; recommended model + 2 rejected alternatives; 9-step sequence + risk register. **Gated:** the serialize rewrite. |

### A4 — R5 state-field classification (DOMAIN / CLIENT-VIEW / SHARED-VIEW-INTENT)

| field | detail |
|-------|--------|
| **Scope** | Per-field classification of `SessionSnapshot`, `AutomationState`, `TabDescriptor`, and the DocumentModel state crossing the AutomationHost boundary — surfacing the falsifying cases the naive "Core=domain, Client=view" split breaks on. |
| **The 4 falsifiers (verified)** | **(1) Core persists pure view state:** `selectedTabIndex`/`sidebarExpandedPaths`/`sidebarIncludeHidden`/`splitURL`/`themeOverride` in `SessionSnapshot`. **(2) Double-owned prefs:** `zoom`/`wordWrap` live in BOTH `PreferencesStore` (UserDefaults, app-global) AND `SessionSnapshot` (per-session) — genuine ownership conflict (`SessionState.swift:169-170` restore overwrites the global pref). **(3) Client drives view INTO model:** `automationGotoLine`/`SetViewMode`/`SelectTab` are write-commands, not reads. **(4) Lossy flattening:** `AutomationState.viewMode` is ONE scalar over a per-tab concept (`Tab.swift:8`) — a latent correctness bug today; `FindMatch.range` is non-Codable NSRange. |
| **Recommendation** | Move `selectedTabIndex`+`sidebarExpandedPaths`+`sidebarIncludeHidden`+`splitURL`+`themeOverride` into a nested **`SessionViewState`** sub-record (additive/optional, no v3 bump if possible); **REMOVE** `zoom`/`wordWrap`/`showInvisibleChars` from `SessionSnapshot` (let `PreferencesStore` be sole owner); keep `viewMode` per-tab; fix `AutomationState.viewMode` to be explicitly selected-tab-only. |
| **Blast radius (if implemented)** | `SessionSnapshot` is on-disk schema (`currentSchema=2`) — re-homing fields must stay additive/optional or bump v3 w/ v2 reader. `AutomationState` is the MCP `current_state` wire shape — reshape = external-API change. `FindMatch.range`→Codable touches every find consumer. |
| **Decision gate** | Single-source-of-truth for the double-owned `zoom`/`wordWrap`/`showInvisibleChars` (this is a **behavior-flip** — restoring a session today silently overwrites the global pref; either way some users see a change). |
| **Dependencies** | Reusable-core go/no-go (the classification *feeds* that decision); branch consolidation (authoritative R5 wording lives on `docs/reusable-core`); the Codable-FindMatch prereq (shared w/ A2). |
| **Effort** | Classification artifact: **done** (read-only). Gated implementation ~1 wk, post-launch. |
| **Deliverable now** | **The complete classification table** (fully delivered, read-only) for all four carriers, file:line-cited, with the 4 falsifying patterns explicit + the sub-record/de-dup recommendation. **Gated:** schema change, sub-record extraction, FindMatch reshape, AutomationState fix. |

### A5 — Spec-only items (no decision gate on the artifact)

Three spec deliverables — **fully producible now, read-only**, the implementation gated on branch consolidation + the push channel:

| item | scope | deliverable now | gated |
|------|-------|-----------------|-------|
| **A5a — Contract envelope reserved fields** | Reserve `clientSeq`/`docVersion`/`payloadVersion`/`siteId`/`correlationId`/`causationId` on every future wire envelope (holds open data-loss/multi-window/collab/observability doors at near-zero cost). | The full reserved-field table (type, semantics, today's-value, door-held-open, precedent file:line each), dedupe/staleness rules, tier-1 cost contract (O(1)/no-compute-on-miss, ~100µs assertion — anti-precedent `DocumentModel.displayedText:1515,1537`), COW-snapshot mandate (precedent `EditorBuffer:21-23`, `Tab:50-56`), open wire envelope w/ `unknown()` fallback (precedent `CodeMirrorBridge:16-37,142-149,469-472`), minimal version+capability handshake (anti-precedent `MCPServer:248-257` hardcoded version never read). **(none — `blocked_by_decision: none`)** | Turning the spec into Swift envelope types, the dedupe high-water tracker, the handshake round-trip. |
| **A5b — In-process MCP push channel** | Design the server→client notification subsystem (current server drops all notifications `MCPServer:117-122`; single-reader semaphore park `:188-206`, no pool). | Gap confirmation w/ citations; notification wire-format + `subscribe`/`unsubscribe` verb schemas; topic catalog split state(coalescing 1-slot) vs stream(bounded FIFO + `lostEvents`); the pure `deliver(prior,incoming)→(next,[deliveries])` function spec; `AutomationScheduler`/`AutomationClock` port sketches; correlation-ID scheme; ring-buffer event-log = audit log + test oracle; reader/pool/multiplexer refactor diagram preserving the no-wedge + ordered-reply invariants (`MCPServerWedgeTests`); 10-step plan. | Pool refactor (highest risk — must not regress wedge tests), `@Published` change-feed wiring, ~4–7 d impl. **Note:** `@MainActor` is the true bottleneck — the "pool" is an intake/ordering device, not real parallelism. |
| **A5c — Collapse 3 drifted serialization surfaces** | One generated source-of-truth verb catalog + CI drift check across MCP tool catalog (10 tools, snake_case), ScriptRunner DSL (~40 verbs, kebab-case, reaches past AutomationHost into DocumentModel), CM6 bridge (`{v,type}`, camelCase, own version negotiation). | The 3-surface drift matrix (vocabulary/casing/encoding/coverage/consumer, file:line); the `VerbDescriptor` catalog shape; the CI drift-check spec (host-runnable ViewerCoreTests); **the authz reconciliation memo** — keep `PluginManifest.Capability` namespace FROZEN (on-disk-compat-sensitive: `PluginGrantStore` persists rawValue strings, re-prompts on set change), give `declare(caps)` a **disjoint advisory namespace**, add a fail-closed server-side authz check at `MCPServer.swift:281` modeled on `PluginRegistry.loadOne`. | All .swift edits — blocked on (1) catalog scope (wire-only vs include VM-test-only ScriptRunner verbs) and (2) declare(caps) reconciliation, plus the FindMatch-Codable prereq. Recommended substrate: **Swift-table-as-truth** (no new dependency). |

---

## 4. Sequenced roadmap

The linear-trunk rule forces a strict order: **you cannot start any invasive Track-A code over a dozen open branches** (R28 — a core-wide isolation change rebases against every in-flight branch perpetually). So consolidation is step zero, and it is a **decision the owner must make**, not a mechanical merge.

```
 PHASE 0  Branch consolidation  ── DECISION ─────────────────────────────────┐
    │  Branches in flight, none on main:                                     │
    │    audit/pre-launch    = main + 141 audit fixes (15 groups)            │
    │    docs/reusable-core   = the 5 architecture docs                      │
    │    fix/large-file-readonly                                             │
    │    fix/modebar-republish-and-panel-toggles                            │
    │    feature/focused-multi-repo-git                                      │
    │    integration/session-ui                                              │
    │  main @ e05b966 = baseline + lsp.json RCE (UNFIXED on main)           │
    └────────────────────────────────────────────────────────────────────────┘
            │
            ▼
 PHASE 1  Land the 141 residual to main  (audit/pre-launch → main)
            │  + close the 6 partials (SEC-002, EDIT-nil-fp, FW-1, DEP-001 are
            │    one-to-few-line fixes; SIGN-02 Phase-9; SEC-001 trust-UI = §2)
            ▼
 PHASE 2  Track-A no-regret core hardening, in dependency order:
            A2 (value-type purge — independent, lowest risk)  ──first──┐
            A1 steps 1-7 (de-@MainActor) ◄── needs A2 + isolation decision
            A3 (bytes/encoding/EOL) ◄── independent, but same save-path files
            A4 + A5a/b/c specs ◄── feed the boundary, no code gate on artifacts
            ▼
 PHASE 3  (BLOCKED on §2 product-identity + committed 2nd front-end)
            A1 step 8 (headless DocumentModel extraction) + RC/PROTO epic
```

### DO-NOW — unblocked, read-only, shippable today

These need **no decision and no consolidation** — they are pure analysis/spec artifacts:

| deliverable | from |
|-------------|------|
| Corrected 11-vs-18 `@MainActor` inventory + per-type race classification + the single race seam | A1 |
| NSColor/NSRange occurrence inventory + replacement-type spec + 4-seam edge map + 13-enum Codable checklist | A2 |
| Save-path two-bug root-cause + recommended `(bytes,encoding,EOL)` model + display-only correction | A3 |
| The complete R5 DOMAIN/CLIENT-VIEW/SHARED-VIEW-INTENT classification table | A4 |
| Contract-envelope reserved-field spec (**A5a — explicitly `blocked_by_decision: none`**) | A5a |
| MCP push-channel design spec (gap + wire-format + `deliver()` + refactor diagram) | A5b |
| 3-surface drift matrix + VerbDescriptor shape + drift-check spec + **authz reconciliation memo** | A5c |
| The 6 one-to-few-line partial fixes, *specified* (SEC-002 scrub-at-init, EDIT-nil-fp call site, FW-1 `onLost` closure, DEP-001 `cp` line) | §1 |

### BLOCKED-BY-DECISION — invasive code, gated

| gated work | gated on |
|------------|----------|
| Landing 141 to main + closing partials in code | **Branch consolidation decision** (Phase 0) |
| A1 steps 1–7 annotation/`@Published`/executor edits | Isolation-model decision + consolidation |
| A2 type creation + field swaps + edge wiring | OffsetRange-unit + color-space decisions + consolidation |
| A3 serialize rewrite | In-memory-EOL-policy decision + consolidation (G4 + 2 editor branches) |
| A4 sub-record extraction + zoom/wordWrap de-dup + FindMatch reshape | Double-owned-pref ownership decision + reusable-core go/no-go |
| A5a/b/c → Swift code (envelope types, push channel, verb catalog) | Consolidation + push channel + (A5c) catalog-scope + declare(caps) decisions |
| **A1 step 8** (headless DocumentModel) + RC-01..08 + PROTO-1..5 + API-01/02/09 + SCALE-4/11 | **§2 product-identity one-way door + committed 2nd front-end** (macOS-ship-first call) |
| WV-3 scheme-handler, SIGN-08..11, UX-11 sandbox | Phase-9 / sandboxing decisions (§2 list) |

---

## 5. Decisions required from the owner

The minimal gate set, each a crisp question. The first three unblock everything; the rest are independent product/policy/legal calls.

**Consolidation & trunk**
1. **Branch consolidation:** Merge `audit/pre-launch` (141 fixes) + `docs/reusable-core` (5 docs) to `main` now, and freeze/land the 4 unmerged feature branches (`fix/large-file-readonly`, `fix/modebar-republish-and-panel-toggles`, `feature/focused-multi-repo-git`, `integration/session-ui`) — **before** any Track-A code? (Yes = unblocks Phases 1–2. This is the single highest-leverage decision: `main` ships the RCE-class exposure unfixed until this happens.)

**Product identity (the one-way door)**
2. **§2 product identity:** Is the macOS app *the product*, or is the reusable headless core the product? Is a second front-end actually committed? (Gates A1 step 8 + the entire RC/PROTO/API/SCALE epic. **macOS-ship-first** = these stay surfaced, only Track-A no-regret prerequisites proceed.)

**Track-A isolation & representation (each blocks one A-item's code, not the artifact)**
3. **A1 isolation model:** Post-`@MainActor` isolation for ViewerCore — (a) one global `@CoreActor`, (b) per-document serial executor / worker pool, or (c) plain Sendable + explicit locks? (Wrong default re-derives a global RW lock later — R20.)
4. **A2 OffsetRange unit & color space:** UTF-16 (recommended) vs UTF-8 offsets; flat sRGB (recommended) vs colorspace-tagged RGBAColor?
5. **A3 in-memory EOL policy:** Normalized-LF + re-apply at save (recommended), or CM6 preserve-CRLF-live (much larger blast)?
6. **A4 double-owned prefs:** Single source of truth for `zoom`/`wordWrap`/`showInvisibleChars` — app-global pref (recommended, remove from session snapshot) or per-session? (Behavior flip either way.)
7. **A5c catalog scope + declare(caps):** Does the unified verb catalog cover only wire-eligible verbs or also VM-test-only ScriptRunner verbs? Is `declare(caps)` the *same* authority as `PluginGrantStore` (must be server-enforced + persisted-consent, fail-closed) or a *strictly-advisory* negotiation layer that grants nothing?

**Legal / distribution / policy (independent)**
8. **DEP-002 LICENSE:** Proprietary or OSS? (Distribution blocker; trivial once chosen.)
9. **Bundle-id/name:** Keep TCC-stable `com.markdownviewer.MarkdownViewer` + accept the `TextView`/`MarkdownViewer` split, or coordinated rename that resets all installed-user TCC grants?
10. **PERSIST-05:** Did any pre-launch build with the v1 `Workspaces/_last.json` shape reach real users? (If yes, re-add a one-shot migration before launch.)
11. **SCALE-4/11 mmap:** Build a paged multi-GB viewer, or downgrade the DESIGN.md "GB via Source" claim to the real 64 MB ceiling?
12. **Policy batch:** Telemetry (CR-03/OBS-4 — add at all? opt-in/out?), App Sandbox (UX-11 — adopt? forces security-scoped bookmarks), localization (I18N-06 — English-only at launch?), Trojan-Source bidi (I18N-03 — strip/visualize/warn), WV-3 header-CSP scheme-handler.
13. **BR-01:** Confirm `.claude/worktrees` (**124 GB / 60 dirs**) is fully merged/abandoned so it can be pruned? (Destructive — needs explicit OK.)

---

### Honest verification caveats

- **Not built, not run.** All verification is from source + git history per the read-only discipline. Dynamic behavior (the Phase-9 signing end-state, the `FileTreeRecency` dark-mode re-pick, the byte-image round-trips) is *not* confirmed — flagged inline where it matters.
- **Two cannot-verifies:** the "~196 hardcoded strings" l10n count (absence of l10n infra *is* verified; the count is not) and the Phase-9 notarization end-state (needs a real `build-app.sh` + notary run).
- **`fix/large-file-readonly` not inspected** — SCALE-1 is reported as it exists on `audit/pre-launch` (64 MB cap); that branch may differ.
- **Stale cited paths corrected:** PERSIST-04 (now `Sources/ViewerCore/Sessions/`), SCALE-3 (`SidebarModel.swift:317-422`, not `:286-303`), PERSIST-01 (`:142-189`), UDC-2 (fix in `applyReload` `:1919-1942`, not the cited opening path). The audit index drifted from code in these four spots; code is authoritative.