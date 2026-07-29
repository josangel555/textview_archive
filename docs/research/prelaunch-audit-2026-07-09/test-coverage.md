# Pre-launch Audit — Test Coverage & Testing Gaps

**Dimension:** Test coverage, missing edge cases, per-surface real-render matrix gaps, untested error paths.
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Date:** 2026-07-09
**Reviewer lens:** Which subsystems/paths have NO tests, weak guards, or untested error paths — verified against real code, not vibes.

---

## Executive summary

The project is, on the whole, **exceptionally well tested** — ~178K LOC of tests against ~380K LOC of source, with disciplined behavior-level coverage. The Rust core carries dedicated proptest + fuzz lanes; the agent-facing MCP tool catalog is dispatch-tested end-to-end; data-safety flows (disk conflict, save-copy, file resurrection) each have named behavior suites; and there is a codified negative-control mechanism (`MDVNegativeControl`) proving pixel tests can actually go red. This is not a codebase with a coverage problem in the ordinary sense.

The genuine gaps are **narrow and concentrated in one tier: the real-render (pixel / WebView / live-app) layer** — exactly the tier the project's own institutional history (the terminal-tab-strip miss that recurred four times) says is the most dangerous. Specifically:

1. **4 of 8 content lenses have no real-render test.** `formatted`, `table` (CSV), `diff`, and `hex` are carried as *exemptions* in the surface-coverage matrix, not real-render suites. `diff`'s only "render" test uses `ImageRenderer`, which the project's own `CLAUDE.md` classifies as a **false green** for compositor occlusion. `hex` has zero pixel coverage. A blank-render / occlusion / dark-mode regression in these user-visible surfaces would pass every automated gate.
2. **The surface-matrix guard has no teeth beyond file existence.** It asserts the named evidence file *exists on disk* — not that it renders the surface, has assertions, or isn't permanently skipped.
3. **The entire render tier is VM/nightly-gated.** The PR/merge gate proves *zero* on-screen behavior; all pixel teeth live behind a self-hosted macOS VM runner. If that runner is offline (and the local render cron is noted STOPPED in `CLAUDE.md`), render coverage goes stale silently on green PRs.
4. **The matrix can't discover surfaces.** Real content surfaces absent from its two hard-coded dictionaries (notebook, LSP diagnostics, review, git graph/worktrees/history, markdown overview, package explorer, …) escape the "every surface needs a render guard" mandate entirely.

Everything below is independently verifiable at the cited `file:line`.

---

## Methodology

What I examined, and how:

- **Structural census.** Counted source vs test files per target: `Sources/ViewerCore` (509 files) / `Tests/ViewerCoreTests` (637); `Sources/ViewerUI` (288) / `Tests/ViewerUITests` (495); Rust `rust-core/crates/*` src-LOC vs in-file `#[test]` counts.
- **Reference cross-check.** For every top-level source file in `ViewerCore` and `ViewerUI` (and each subdir), checked whether its type basename is referenced anywhere under `Tests/`. Treated the result as a *lead*, not a verdict — `DocumentModel+*` extensions and split-out model tests defeat pure basename matching, so every apparent gap was hand-verified by grepping for the underlying behavior suite.
- **Render-matrix audit.** Read `Tests/ViewerUITests/SurfaceCoverageMatrixTests.swift` in full (the TSK-1539 MANDATE-1 guard), traced each evidence suite, and inspected `SourceViewVisualRegressionTests.swift` / `DiffViewSelectionRenderTests.swift` for teeth vs stubs vs ImageRenderer.
- **CI gate analysis.** Read `.github/workflows/{pr,nightly-vm,coverage}.yml` to establish what actually executes on the merge gate vs the nightly VM lane.
- **Skip census.** Counted `XCTSkip` across the test tree (90 files) and inspected the highest-count skip sites (visual-regression suites, LSP smoke).
- **Error-path spot-checks.** Inspected the `Audit_*` regression-test family (20 files), the Rust `ffi` buffer/handle unsafe boundary (`buf.rs`, `handle.rs`), and the MCP dispatch completeness test.
- **Targeted greps only — no full `swift test`** (per constraints; the render tier is VM-only regardless).

Coverage of the review itself: I read the matrix guard, one representative visual-regression suite, the MCP catalog + its tests, several `Audit_*` files, the three relevant CI workflows, and the ffi unsafe primitives directly. I did **not** execute any suite; findings are from static analysis + the suites' own skip/assert structure.

---

## Findings

### F1 — Diff and Hex content surfaces have NO real-render pixel test (diff's is a known false-green)
- **Severity:** P1
- **File:** `Tests/ViewerUITests/SurfaceCoverageMatrixTests.swift:30-35`; `Tests/ViewerUITests/DiffViewSelectionRenderTests.swift:77-80`
- **Evidence:** The matrix carries four lenses as `.exempt(ticket: "TSK-1551")` instead of a real-render suite: `.formatted`, `.table` (CSV), `.diff`, `.hex`. The inline comment on `.diff` concedes `DiffViewSelectionRenderTests is ImageRenderer (not real-render)`. Confirmed at `DiffViewSelectionRenderTests.swift:77` — `let renderer = ImageRenderer(content:…)`. `CLAUDE.md` (compositor-occlusion section) explicitly states `ImageRenderer … give a FALSE GREEN for this class` and that the *only* authority is stage-④ WindowServer pixels. Hex has an extensive *model* suite (`HexLayoutTests`, `HexCaretMapTests`, `HexDumpBuilderTests`, `HexFixedGridFrameTests`, …) but **no** T5/pixel suite.
- **Impact:** Diff and hex are primary data-*viewing* surfaces. A compositor occlusion (the exact terminal-tab-strip bug class that recurred 4×), a dark-mode paint failure, a zero-size collapse, or a color-blend-into-background regression in these two lenses would be caught by **no** automated test — model tests pass while the screen is blank. This is the highest-consequence coverage hole because it sits precisely on the failure class the project has been burned by repeatedly.
- **Suggested fix:** Add a real-render suite for `hex` and `diff` on the pattern of `SourceViewVisualRegressionTests` (spawn app + `screencapture -l<windowID>` + per-region pixel-variance assert + an `MDVNegativeControl` broken switch for teeth). Replace the two matrix exemptions with `.suite(...)`.
- **Fix size:** L
- **Fix risk:** safe (additive test only)

### F2 — Two more content lenses (formatted, CSV table) also lack real-render coverage
- **Severity:** P2
- **File:** `Tests/ViewerUITests/SurfaceCoverageMatrixTests.swift:30-31`
- **Evidence:** `.formatted: .exempt(ticket: "TSK-1551")` and `.table: .exempt(ticket: "TSK-1551")` (CSV lens — the comment notes xlsx is covered by `SpreadsheetViewHostingTests`, but the CSV table lens is not). Half the `ViewMode` lens set (4 of 8) is therefore uncovered at the pixel tier.
- **Impact:** Lower than F1 (formatted/CSV are less occlusion-prone than the WebView-hosting diff/hex surfaces), but still user-visible render surfaces with only model-layer guards. The `exemptCount ≤ 4` cap (line 82) means the project is at its self-imposed ceiling — any *new* surface must ship a real suite, but these four remain open debt.
- **Suggested fix:** Extend the same real-render suite pattern to the CSV table and formatted lenses; drive the exemption count down toward 0.
- **Fix size:** M
- **Fix risk:** safe

### F3 — Surface-matrix guard only verifies file existence, not that the evidence suite has teeth
- **Severity:** P2
- **File:** `Tests/ViewerUITests/SurfaceCoverageMatrixTests.swift:62-85`
- **Evidence:** `test_everyEvidenceSuite_existsOnDisk_…` asserts `FileManager.default.fileExists(atPath: path)` for each mapped suite filename. There is **no** check that the file contains a render assertion, isn't entirely `XCTSkip`-guarded, or actually exercises the mapped surface. A suite could be gutted to a no-op, renamed-in-place to a stub, or permanently self-skip, and the matrix would stay green.
- **Impact:** The guard advertises "every surface has a real-render guard" but proves only "a file with this name exists." Given F4 (all these suites self-skip on the host gate), the matrix is a **name registry**, not a behavior guarantee. It gives false confidence that the render tier is covered.
- **Suggested fix:** Strengthen the guard to parse each evidence suite for ≥1 non-skipped pixel assertion (e.g. require a `screencapture`/`PixelTestCase` reference and an `MDVNegativeControl` teeth switch), or — better — have the nightly VM lane emit a per-suite executed/asserted receipt the host guard cross-checks.
- **Fix size:** M
- **Fix risk:** safe

### F4 — Entire render tier is VM/nightly-gated; the merge gate proves zero on-screen behavior
- **Severity:** P2
- **File:** `.github/workflows/pr.yml:107-108`; `.github/workflows/nightly-vm.yml:26-56`; `Tests/ViewerUITests/SourceViewVisualRegressionTests.swift:57-67,142-153,436-445`
- **Evidence:** The PR gate runs only `bash scripts/test-headless-gate.sh` (`pr.yml:108`). Every render-matrix evidence suite gates its body behind `throw XCTSkip("T5 heavy tier — runs in the VM/nightly lane, not the headless gate.")` unless `MDV_VM_GUI_SESSION=1` (e.g. `SourceViewVisualRegressionTests.swift:57-59`). The pixel tier runs **only** in `nightly-vm.yml`, on a `[self-hosted, macos-vm]` runner (`nightly-vm.yml:36`) at `cron: "0 8 * * *"` (line 28).
- **Impact:** No green PR carries any evidence that on-screen rendering works — by design. That is acceptable *iff* the nightly VM lane is actually online and passing. `CLAUDE.md`/MEMORY note the local render cron as STOPPED, and a self-hosted macOS VM runner is easy to have silently offline. If it is, the render tier — the project's stated highest-risk area — regresses with **no signal at all** on green PRs, and pre-launch confidence in render is unverified.
- **Suggested fix:** Before launch, confirm the `macos-vm` self-hosted runner has executed `nightly-vm.yml` recently and green; add a freshness/heartbeat check (fail the merge gate, or a dashboard, if the last successful nightly VM render run is older than N days). Capture the last JUnit artifact date.
- **Fix size:** S (verification) / M (heartbeat wiring)
- **Fix risk:** safe

### F5 — Matrix cannot discover surfaces; many real content surfaces have no render guard and no matrix row
- **Severity:** P2
- **File:** `Tests/ViewerUITests/SurfaceCoverageMatrixTests.swift:26-47`
- **Evidence:** The matrix enumerates 8 `ViewMode` cases + 8 hard-coded aux surfaces (`canvas`, `terminal`, `walkthrough`, `claudeMonitor`, `imageEditor`, `audioEditor`, `spreadsheet`, `fileTabStrip`). It is two static dictionaries with no tie to the runtime surface registry (`list_surfaces` / `SurfaceRegistry`). Real user-facing surfaces with **no** matrix row and no real-render suite include: notebook cell list (`Sources/ViewerUI/NotebookCellListView.swift`), LSP diagnostics panel (`Sources/ViewerUI/LSP/LSPDiagnosticsView.swift`), review index + comment cards (`Sources/ViewerUI/Review/ReviewIndexTab.swift`, `CommentCards.swift`), git graph / worktrees / unified history (`Sources/ViewerUI/Git/GitGraphColumn.swift`, `GitWorktreesTab.swift`, `UnifiedHistoryView.swift`, `FolderStatsView.swift`), markdown overview + find minimap (`Sources/ViewerUI/MarkdownOverviewView.swift`, `FindMatchMinimapView.swift`), package explorer (`PackageExplorerView.swift`).
- **Impact:** The "unmapped surface = RED gate" property (the guard's whole point) only holds for surfaces a human remembered to type into the dict. A new surface that no one adds is never flagged — the guard structurally cannot fail for it. So the mandate is enforced for the enumerated 16 and silently unenforced for everything else.
- **Suggested fix:** Drive the lens side from `ViewMode.allCases` (already done) *and* the aux side from the live surface registry / `list_surfaces` output, so a newly-registered surface with no evidence row fails the guard automatically.
- **Fix size:** M
- **Fix risk:** careful (couples the guard to the registry API; needs a stable enumeration source)

### F6 — LSP integration is untested in a clean CI (smoke suites skip when language servers absent)
- **Severity:** P2
- **File:** `Tests/ViewerCoreTests/LSPPoolSmokeTests.swift:26,50-53`; `Tests/ViewerCoreTests/LSPMultiLanguageSmokeTests.swift`
- **Evidence:** `LSPPoolSmokeTests` throws `XCTSkip("sourcekit-lsp not on PATH")` (line 26) and additional skips for cold-start timeout / failure (`ensureOpened timed out`, line 50). `LSPMultiLanguageSmokeTests` has 6 skip sites. Only the failure-path *unit* tests in `LSPPoolTests` run without a real server.
- **Impact:** The LSP subsystem's end-to-end behavior (hover, definitions, diagnostics, rename) is only exercised when `sourcekit-lsp` and other language servers happen to be installed on the runner. On a clean CI image they skip, so LSP integration ships effectively unguarded against real-server regressions. LSP is a headline feature — this is table-stakes coverage that silently evaporates.
- **Suggested fix:** Pin a known language-server toolchain into the VM/nightly lane and make these suites **fail** (not skip) there when the server is expected but missing, so the skip can't mask a broken environment. Keep host skips.
- **Fix size:** M
- **Fix risk:** safe

### F7 — No coverage floor is enforced; the coverage job always passes
- **Severity:** P3
- **File:** `.github/workflows/coverage.yml:6`
- **Evidence:** The workflow header states it `emits a per-file + TOTAL llvm-cov report over Sources/; it always exits 0.` No threshold / `--fail-under` / minimum-percent gate exists.
- **Impact:** Coverage is informational only. A change that deletes tests or adds a large untested subsystem produces no red signal from the coverage lane — coverage can silently erode over time with nothing catching the drift.
- **Suggested fix:** Add a soft TOTAL floor (e.g. "must not drop >X% vs the base branch") as a warning first, then a hard gate once a baseline is agreed. Owner decision on the target number.
- **Fix size:** S
- **Fix risk:** safe

### F8 — 90 test files gate their bodies behind XCTSkip — a large authored-but-unrun surface on the merge gate
- **Severity:** P3
- **File:** tree-wide (`grep -rl XCTSkip Tests/` → 90 files); highest counts: `SourceViewVisualRegressionTests.swift` (16), `LSPPoolSmokeTests.swift` (12), `uat/PreviewsUATTests.swift` (8), `ImageEditorVisualRegressionTests.swift` (7), `FileTabStripVisualRegressionTests.swift` (7)
- **Evidence:** 90 of the test files contain `XCTSkip`. Most are legitimate VM-only tiers or environment-gated smokes, but the aggregate means a substantial fraction of the *authored* test surface never executes on the host merge gate.
- **Impact:** The green host gate covers materially less than the raw test-file count implies. Combined with F4/F6, the effective host-gate coverage of UI/render/LSP is thin; confidence should be calibrated to what the VM lane actually runs, not to the test-file census.
- **Suggested fix:** Emit a per-run skip-manifest (which suites skipped and why) from both the host gate and the VM lane, so "skipped everywhere" suites (authored but never executed in any lane) surface as a distinct, actionable category.
- **Fix size:** M
- **Fix risk:** safe

### F9 — FFI buffer/handle unsafe error paths have no direct unit tests
- **Severity:** P3
- **File:** `rust-core/crates/ffi/src/handle.rs:107-127`; `rust-core/crates/ffi/src/buf.rs:52-76`
- **Evidence:** `handle.rs` and `buf.rs` (the memory-management primitives at the C ABI boundary) contain 0 in-file `#[test]`. The null / freed-token / mutex-poison recovery branches — `handle.rs:107` (`None` for null / a freed token / unknown value), `buf.rs:52-61` (`free_in_place` null/cap guards), `buf.rs:71-76` (`as_slice` null guard) — are exercised only indirectly via the 57 round-trip tests in `ffi/src/tests.rs`, none of which appear to feed a deliberately-null or double-freed handle across the boundary.
- **Impact:** These are the exact paths where a bug is a use-after-free / segfault at the FFI seam (the project's most fragile boundary, per its own SwiftPM-staleness / SIGSEGV lessons). Indirect happy-path round-trips do not prove the null/freed/poison guards behave — a regression here fails as an opaque crash, not a red test.
- **Suggested fix:** Add direct unit tests: pass a null `*mut SessionHandle` to the resolver and assert `None`; double-`free_in_place` a buffer and assert idempotent null-out; resolve a token after free and assert miss (no ABA). All host-runnable, no VM.
- **Fix size:** S
- **Fix risk:** safe

### F10 — ~20 standalone SwiftUI views carry interaction logic with no test reference in any lane
- **Severity:** P3
- **File:** e.g. `Sources/ViewerUI/KeyboardShortcutsView.swift`, `SnippetManagerView.swift`, `PackageExplorerView.swift`, `AnnotationsView.swift`, `ActionHistoryView.swift`, `LogPatternsView.swift`, `NotebookCellListView.swift`, `CodeActionPicker.swift`, `LSPRenamePrompt.swift`, `FindMatchListView.swift`
- **Evidence:** Basename cross-check found ~20 top-level `ViewerUI` `*View` files with zero reference under `Tests/`. Hand-verification confirmed several hold real interaction logic (snippet CRUD, keyboard-shortcut editing, log-pattern management, code-action selection) not covered by a split-out model suite — unlike the `DocumentModel+*` extensions and `ConflictResolutionView` (whose logic *is* tested via `ConflictResolutionModelTests`).
- **Impact:** Pure static layout in these views is low-risk, but the embedded logic (list mutation, selection, form editing) is unguarded at every tier. Lower priority than the primary content surfaces (F1/F5) since these are secondary panels, but they are user-reachable interaction surfaces with no regression net.
- **Suggested fix:** Extract the stateful logic from each into a testable model (as was done for `ConflictResolutionView` → `ConflictResolutionModelTests`) and add host behavior tests; add the interaction-bearing ones to the render matrix per F5.
- **Fix size:** L (spread across ~20 views)
- **Fix risk:** safe

---

## Positive observations

The following are genuinely strong and should be preserved:

- **Rust core is comprehensively tested.** `web/main.rs` (115 tests), `tui/main.rs` (66), `pm/lib.rs` (30 — the SQLite store), `serve` (well-distributed: `lifecycle.rs` 18, `serve.rs`/`watch.rs` 10 each, `envelope.rs` 8), `core` (51 files with tests + 6 integration suites). Dedicated **proptest** and **cargo-fuzz** lanes exist per the dep policy, so new parsers get differential/round-trip and fuzz coverage, not just examples.
- **MCP tool catalog is dispatch-tested end-to-end.** `Tests/ViewerCoreTests/Automation/MCPToolCatalogTests.swift` drives `MCPToolCatalog.dispatch(name:…)` through a `FakeAutomationHost` for the full 39-tool surface, with a completeness list (line 116-121) and teeth assertions (`XCTAssertEqual(host.ranVerb, …, "teeth: the verb reached the host dispatch")`). The agent-facing attack surface is well guarded (24 automation test files total).
- **Error paths get targeted regression tests.** The 20 `Audit_*` files are per-finding regression suites, e.g. `Audit_…_MCPServer_swift_DeadTransportTests` covers the EPIPE / dead-transport swallow-and-hang path with a real stub host — precisely the kind of error-path coverage this review looks for.
- **Data-safety flows are covered under behavior-named suites** (not obvious by basename): disk conflict (`DiskConflictResolverTests`, `SaveConflictDecisionTests`, `DiskConflictBannerWiringTests`), external-edit reconcile (`ExternalEditReconcileWiringTests`, `ConflictResolutionModelTests`), save-copy (`SaveCopyTests` + `SaveCopyWiringTests`), file resurrection (`FileResurrectionTests`, `DocumentModelResurrectionTests`).
- **Hex and diff *model* layers are deeply tested** even though their pixel tiers are gapped (F1): 10+ hex model suites, 25+ diff suites (parse, hunk, selection, clipboard, differential-fuzz).
- **Teeth are codified, not aspirational.** `MDVNegativeControl.isBroken("<NAME>")` (e.g. `MDV_ENABLE_BROKEN_RULER`) lets a pixel test spawn the app in a deliberately-broken state to prove the guard goes red — a repeatable, committed teeth proof, and `SourceViewVisualRegressionTests` has a `test_meta_brokenRulerIsDetectedAsRegression` self-check.
- **The render-matrix guard exists at all.** Most projects have no enumeration of "which surface has render coverage." Findings F3/F5 are about *strengthening* a good idea, not introducing one.

---

## Coverage gaps (what I did NOT examine)

- **I executed no test suite.** All findings are static + structural (skip-guards, assertion shape, CI wiring). I did not confirm the nightly VM lane's *actual* last-run status or green/red result (F4 is the structural risk; the live runner state is unknown to me).
- **Did not measure line/branch coverage numbers.** No `llvm-cov` run; the reference cross-check is presence-of-a-test, not percentage. A file referenced in `Tests/` may still have thin branch coverage.
- **Canvas DSL, ImageEditing, Audio, Walkthrough, Plugins, Terminal, Sessions** subsystems were sampled at the census level only (each showed strong basename coverage) — not deep-read for edge-case/error-path gaps within their suites.
- **Rust `core/canvas/` DSL, `nav`, `formula`, `json` engines** — confirmed present in the 51 tested `core` files but not individually audited for missing edge cases.
- **Perf/bench suites** (`FoldBench`, `CrossFileSearchBench`, `perf_floor.rs`) — not assessed for whether their thresholds are meaningful; `CLAUDE.md` notes they're load-flaky.
- **Test *quality* of passing suites** — I checked teeth on the render matrix and MCP catalog specifically; I did not audit whether other green suites assert meaningfully vs. tautologically.
- **The `web`/`tui`/`serve` front-ends' integration behavior** — high in-file `#[test]` counts confirmed, but not read for untested network/error branches.
