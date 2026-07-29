# ViewerCoreTests root slice 3/7 (153–228) — Test Inventory & Learnings

**Batch:** Files 153–228 of 528 Swift tests in `Tests/ViewerCoreTests` root · **76 files** · **~13,432 LOC total**

---

## File Inventory (1–2 line entries)

**Tests/ViewerCoreTests/FileResurrectionTests.swift** (90 LOC) — tier: headless-unit | framework: XCTest | pins: deleted-file resurrection from local history (O_EXCL atomicity, workspace boundary fencing, path traversal guards) | teeth: real (tests safety boundaries that could break silently)

**Tests/ViewerCoreTests/FileTreeFilterTests.swift** (110 LOC) — tier: headless-unit | framework: XCTest | pins: tree-filter visibility rule (ancestor-chain + subtree preservation when any node matches) | teeth: real (pure algorithm guard; regression breaks file-pane filtering)

**Tests/ViewerCoreTests/FileTreeOpsTests.swift** (121 LOC) — tier: headless-unit | framework: XCTest | pins: file-tree node insertion/removal/reordering and parent-link consistency | teeth: real (data structure invariants; broken link = silent loss)

**Tests/ViewerCoreTests/FileTreeRecencyConcurrencyTests.swift** (179 LOC) — tier: headless-unit | framework: XCTest | pins: recency-ranking index under concurrent add/remove (race detection via thread sanitizer) | teeth: real (catch race-condition corruption)

**Tests/ViewerCoreTests/FileTreeRecencyTests.swift** (158 LOC) — tier: headless-unit | framework: XCTest | pins: time-ordered MRU tracking for file tree (temporal consistency across session/sort operations) | teeth: real (silent sort/ranking regressions)

**Tests/ViewerCoreTests/FileTreeServiceTests.swift** (106 LOC) — tier: headless-unit | framework: XCTest | pins: file-tree service API surface (update batching, change notifications, hierarchy resolve) | teeth: real (notification contracts that drive downstream UI)

**Tests/ViewerCoreTests/FileWatcherStopRaceTests.swift** (88 LOC) — tier: headless-unit | framework: XCTest | pins: FSEvents stop/cleanup race (dealloc while callback firing — TSAN catch) | teeth: real (prevents UAF/crash on shutdown)

**Tests/ViewerCoreTests/FileWatcherTests.swift** (273 LOC) — tier: headless-unit | framework: XCTest | pins: FSEvents watch surface (create/modify/delete detection, recursive folders, exclusion patterns) | teeth: real (core is silent-fail if events miss)

**Tests/ViewerCoreTests/FindDifferentialFuzzTests.swift** (59 LOC) — tier: headless-unit | framework: XCTest | pins: find-engine correctness via differential vs. naive reference (corpus: regex, literal, case-insensitive) | teeth: real (fuzzing catches Unicode/RE bugs)

**Tests/ViewerCoreTests/FindEngineTests.swift** (214 LOC) — tier: headless-unit | framework: XCTest | pins: find-all, highlighting, match extraction under regex/literal/fuzzy modes | teeth: real (silent mismatch = wrong highlights)

**Tests/ViewerCoreTests/FirstRunExperienceTests.swift** (64 LOC) — tier: headless-unit | framework: XCTest | pins: first-launch session init and workspace discovery (empty state, sample walkthrough insertion) | teeth: real (bad defaults = silent broken UX on first open)

**Tests/ViewerCoreTests/FlameInteractionTests.swift** (90 LOC) — tier: headless-unit | framework: XCTest | pins: flame-graph click → code-location jump (profile data parsing, symbol resolution) | teeth: weak (interaction model is tested; real click requires UI tier)

**Tests/ViewerCoreTests/FlameProfileTests.swift** (284 LOC) — tier: bench | framework: XCTest | pins: flame-graph frame layout + rendering performance (layout stability under deep stacks) | teeth: real (perf cliff = bad profile UX)

**Tests/ViewerCoreTests/FocusWorkModeTests.swift** (201 LOC) — tier: headless-unit | framework: XCTest | pins: focus-mode (focus-folder filtering on tree/find/editors) and mode state machine | teeth: real (mode leakage breaks filtering)

**Tests/ViewerCoreTests/FoldBenchTests.swift** (69 LOC) — tier: bench | framework: XCTest | pins: fold-region parse perf on synthetic 10K-line JSON (best-of-3 cold compute, repeat cost bound) | teeth: real (guards 10x regressions; loose ceiling catches quadratic)

**Tests/ViewerCoreTests/FoldCommandsTests.swift** (78 LOC) — tier: headless-unit | framework: XCTest | pins: fold/unfold command behavior (region index lookup, line-range transforms) | teeth: real (silent bad index = wrong visual fold)

**Tests/ViewerCoreTests/FoldDisplayTests.swift** (118 LOC) — tier: headless-unit | framework: XCTest | pins: fold-gutter visual state (collapsed indicator, line-number remapping in folded regions) | teeth: real (display sync is critical for line-number semantics)

**Tests/ViewerCoreTests/FolderSizeStatsTests.swift** (186 LOC) — tier: headless-unit | framework: XCTest | pins: recursive folder-size accumulation + concurrent cache invalidation | teeth: real (bad cache = stale stats in sidebar)

**Tests/ViewerCoreTests/FolderWatcherTests.swift** (188 LOC) — tier: headless-unit | framework: XCTest | pins: folder-watching (recursive crawl, change aggregation, exclusion patterns) | teeth: real (miss = silent undetected file ops)

**Tests/ViewerCoreTests/FoldLineMapTests.swift** (122 LOC) — tier: headless-unit | framework: XCTest | pins: logical-to-visual line mapping under folds (caret position, selection translation) | teeth: real (wrong mapping = caret jumps)

**Tests/ViewerCoreTests/FoldRegionTests.swift** (206 LOC) — tier: headless-unit | framework: XCTest | pins: fold-region computation from tree-sitter parse (nesting, nested-fold handling) | teeth: real (wrong regions = invisible/over-folded code)

**Tests/ViewerCoreTests/FormatterMinifyJSONTests.swift** (54 LOC) — tier: headless-unit | framework: XCTest | pins: JSON minification (whitespace strip, key order preserved, round-trip) | teeth: real (silent data loss on malformed input)

**Tests/ViewerCoreTests/FormatterTests.swift** (435 LOC) — tier: headless-unit | framework: XCTest | pins: pretty-print for JSON/XML/JS with invariant guards (JS significant-content preservation via independent lexer) | teeth: real (lost char = parse error in diff/editor)

**Tests/ViewerCoreTests/FormulaEngineMoreFunctionsTests.swift** (238 LOC) — tier: headless-unit | framework: XCTest | pins: formula engine functions (date, string, math, conditional operators) across wide input range | teeth: real (formula miscalculation = silent data error)

**Tests/ViewerCoreTests/FormulaEngineTests.swift** (315 LOC) — tier: headless-unit | framework: XCTest | pins: formula parsing, evaluation, type coercion, error handling (division by zero, type mismatch) | teeth: real (formula corruption = data loss)

**Tests/ViewerCoreTests/FrameThrottleTests.swift** (75 LOC) — tier: headless-unit | framework: XCTest | pins: frame-drop throttling (adaptive sample rate under varying load, budget enforcement) | teeth: weak (sample counts; real perf requires profile capture)

**Tests/ViewerCoreTests/G5ParserHardeningTests.swift** (414 LOC) — tier: headless-unit | framework: XCTest | pins: multi-layer parser robustness from G5 audit (encoding detection CP1252/Latin-1, size caps, CSV quoting, HTML nesting guard, sanitizer quote-tokenizer, diff hunk clamps) | teeth: real (audit findings codified; regression = crash/memory on adversarial input)

**Tests/ViewerCoreTests/GalleryShapeFreeformTests.swift** (45 LOC) — tier: headless-unit | framework: XCTest | pins: freeform-shape layout (anchor-point placement, resize geometry) | teeth: real (geometry error = misaligned shapes)

**Tests/ViewerCoreTests/GalleryShapeTests.swift** (76 LOC) — tier: headless-unit | framework: XCTest | pins: shape model (rect/circle/polygon, property mutations, bounds calc) | teeth: real (wrong bounds = clipping/overflow)

**Tests/ViewerCoreTests/GitBlameParseTests.swift** (56 LOC) — tier: headless-unit | framework: XCTest | pins: `git blame` output parsing (author, date, commit SHA, line mapping) | teeth: real (parse error = blame data loss)

**Tests/ViewerCoreTests/GitBranchSwitchTests.swift** (162 LOC) — tier: headless-unit | framework: XCTest | pins: branch-switch workflow (current-branch tracking, switch guards, dirty-working-tree detection) | teeth: real (silent switch on dirty = data loss risk)

**Tests/ViewerCoreTests/GitClientGrepLogTests.swift** (90 LOC) — tier: headless-unit | framework: XCTest | pins: `git grep` / `git log --grep` integration (query escaping, result parsing) | teeth: real (injection/parse error = silent empty results)

**Tests/ViewerCoreTests/GitClientHistoryStatsTests.swift** (482 LOC) — tier: headless-unit | framework: XCTest | pins: commit history stats (line-change attribution, author ranking, time bucketing, large-history perf) | teeth: real (stats corruption = misleading history panel)

**Tests/ViewerCoreTests/GitClientMutationTests.swift** (141 LOC) — tier: headless-unit | framework: XCTest | pins: git mutations (add, commit, revert, cherry-pick, stash) surface | teeth: real (mutation error = silent state corruption)

**Tests/ViewerCoreTests/GitClientPanelTests.swift** (213 LOC) — tier: headless-unit | framework: XCTest | pins: git client API for panel display (status groups, diff hunks, blame mapping) | teeth: real (API contract mismatch = panel blank/corrupt)

**Tests/ViewerCoreTests/GitClientStatusTests.swift** (160 LOC) — tier: headless-unit | framework: XCTest | pins: `git status` parsing (file state classification, index vs. working-tree delta) | teeth: real (status misclassification = wrong UI indicators)

**Tests/ViewerCoreTests/GitClientTests.swift** (286 LOC) — tier: headless-unit | framework: XCTest | pins: git-client surface (repo discovery, status, log, diff; non-UTF-8 lossy decode; symlink handling) | teeth: real (parse error on encoding/symlink = silent data loss)

**Tests/ViewerCoreTests/GitClientTimeoutTests.swift** (122 LOC) — tier: headless-unit | framework: XCTest | pins: git-command timeout enforcement (hanging/slow command cancellation) | teeth: real (missed timeout = UI freeze/hang)

**Tests/ViewerCoreTests/GitRelativeTimeTests.swift** (37 LOC) — tier: headless-unit | framework: XCTest | pins: relative-time formatting ("2 hours ago", "3 days ago") | teeth: weak (UI text only; silent wrong delta cosmetic)

**Tests/ViewerCoreTests/GitStageOpTests.swift** (34 LOC) — tier: headless-unit | framework: XCTest | pins: stage/unstage operations (index update side effects) | teeth: real (index corruption = wrong next-commit state)

**Tests/ViewerCoreTests/GitVersionSourceTests.swift** (34 LOC) — tier: headless-unit | framework: XCTest | pins: version-string extraction from git commits (semver parsing, fallback) | teeth: weak (version cosmetic; silent wrong extract = display only)

**Tests/ViewerCoreTests/GoToPathHistoryStoreExtendedTests.swift** (134 LOC) — tier: headless-unit | framework: XCTest | pins: go-to-path history persistence (save/load, max-entries cap, duplicate dedup) | teeth: real (history corruption = lost navigation state)

**Tests/ViewerCoreTests/GoToPathHistoryStoreTests.swift** (173 LOC) — tier: headless-unit | framework: XCTest | pins: go-to-path query/result model (ranking, frecency, filtering) | teeth: real (bad ranking = slow search UX)

**Tests/ViewerCoreTests/GotoQueryParserTests.swift** (150 LOC) — tier: headless-unit | framework: XCTest | pins: go-to-path query syntax (symbol@file, line:col, `:` escaping) | teeth: real (parse error = silent query failure)

**Tests/ViewerCoreTests/GrammarLoaderTests.swift** (157 LOC) — tier: headless-unit | framework: XCTest | pins: tree-sitter grammar loading (language detection, parser construction, error handling) | teeth: real (loader fail = no syntax highlight)

**Tests/ViewerCoreTests/GraphLayoutTests.swift** (101 LOC) — tier: headless-unit | framework: XCTest | pins: graph-layout algorithm (node positioning, edge routing, cycle detection) | teeth: real (bad layout = unreadable graph)

**Tests/ViewerCoreTests/HeadingShiftCodeAwareTests.swift** (43 LOC) — tier: headless-unit | framework: XCTest | pins: heading-shift command respecting code-block boundaries (Markdown AST navigation) | teeth: real (escape code block = silent semantic error)

**Tests/ViewerCoreTests/HexCaretMapTests.swift** (203 LOC) — tier: headless-unit | framework: XCTest | pins: caret position in hex view (byte-offset ↔ grid caret bidirectional) | teeth: real (wrong map = caret jumps)

**Tests/ViewerCoreTests/HexDumpBuilderTests.swift** (391 LOC) — tier: headless-unit | framework: XCTest | pins: hex-dump line generation (ASCII sidebar, address calculation, wrapping on edits) | teeth: real (layout error = misaligned bytes)

**Tests/ViewerCoreTests/HexEditBufferTests.swift** (285 LOC) — tier: headless-unit | framework: XCTest | pins: hex edit buffer (nibble overwrite, dirty tracking, undo/redo, ASCII/hex sync) | teeth: real (edit corruption = silent data loss)

**Tests/ViewerCoreTests/HexHighlightPlanTests.swift** (108 LOC) — tier: headless-unit | framework: XCTest | pins: hex-view highlighting (match color mapping, range boundaries under line wraps) | teeth: real (wrong range = mislabeled highlight)

**Tests/ViewerCoreTests/HexLayoutTests.swift** (76 LOC) — tier: headless-unit | framework: XCTest | pins: hex-view grid layout (column widths, byte positioning under different display widths) | teeth: real (wrong width = display corruption)

**Tests/ViewerCoreTests/HexSearchEngineTests.swift** (147 LOC) — tier: headless-unit | framework: XCTest | pins: hex-view substring search (memmem-based byte find, forward/backward, wrap-around) | teeth: real (miss = silent undetected match)

**Tests/ViewerCoreTests/HexViewSizingTests.swift** (44 LOC) — tier: headless-unit | framework: XCTest | pins: hex-view column-sizing (wrap policy, responsive width calc) | teeth: weak (layout only; cosmetic on size change)

**Tests/ViewerCoreTests/HighlightGrammarCoverageTests.swift** (222 LOC) — tier: headless-unit | framework: XCTest | pins: grammar-loading coverage for all declared languages (parser construct, no missing/broken grammar) | teeth: real (broken grammar = no highlight for that language)

**Tests/ViewerCoreTests/HighlightLanguageGrammarParityTests.swift** (108 LOC) — tier: headless-unit | framework: XCTest | pins: rule consistency across grammar versions (scope assignments match expected for major constructs) | teeth: real (parity drift = visual highlight regression)

**Tests/ViewerCoreTests/HighlightScopeParityTests.swift** (170 LOC) — tier: headless-unit | framework: XCTest | pins: TextMate scope assignment parity (function names, keywords, comments render with expected scope tags) | teeth: real (scope mismatch = wrong color)

**Tests/ViewerCoreTests/HistoryContentFilterTests.swift** (104 LOC) — tier: headless-unit | framework: XCTest | pins: local-history filtering (exclude binary, size cap, timestamp range) | teeth: real (filter leak = OOM or exposure of private binaries)

**Tests/ViewerCoreTests/HistoryStoreTests.swift** (317 LOC) — tier: headless-unit | framework: XCTest | pins: local-history persistence (snapshot save/restore, revision ordering, GC) | teeth: real (history corruption = unrecoverable lost versions)

**Tests/ViewerCoreTests/HorizontalScrollerVisibilityTests.swift** (220 LOC) — tier: headless-unit | framework: XCTest | pins: horizontal-scroller show/hide logic under content width (responsive, stable, no flicker race) | teeth: weak (visibility toggle; edge-case cosmetic)

**Tests/ViewerCoreTests/HostedViewTabKindTests.swift** (99 LOC) — tier: headless-unit | framework: XCTest | pins: tab-kind model (surface type, persistence, routing to correct handler) | teeth: real (kind mismatch = wrong editor/view loaded)

**Tests/ViewerCoreTests/HotExitSpillTests.swift** (51 LOC) — tier: headless-unit | framework: XCTest | pins: hot-exit persistence (unsaved buffers captured to session snapshot on crash) | teeth: real (missed spill = data loss on crash)

**Tests/ViewerCoreTests/HotPathPerfRegressionTests.swift** (220 LOC) — tier: bench | framework: XCTest | pins: open hot-path perf (categorize, db route, decode on 8KB–1MB files; median-of-11 sampling to avoid GC noise) | teeth: real (order-of-magnitude regression caught; loose ceiling guards against O(n²))

**Tests/ViewerCoreTests/HTMLDocumentPolicyTests.swift** (487 LOC) — tier: headless-unit | framework: XCTest | pins: multi-layer HTML document security policy (render cap, sanitizer routing, JS default-deny, CSP sub-resource guard, link navigation) | teeth: real (policy regression = XSS vector exposure)

**Tests/ViewerCoreTests/HtmlExportTests.swift** (94 LOC) — tier: headless-unit | framework: XCTest | pins: HTML export surface (asset embedding, style injection, metadata preservation) | teeth: real (export corruption = broken exported document)

**Tests/ViewerCoreTests/HtmlExportXSSTests.swift** (152 LOC) — tier: headless-unit | framework: XCTest | pins: HTML export XSS hardening (markdown → HTML sanitization in export, metadata escaping) | teeth: real (escape miss = exported XSS vector)

**Tests/ViewerCoreTests/HTMLRendererMermaidTests.swift** (142 LOC) — tier: headless-unit | framework: XCTest | pins: mermaid-diagram rendering in markdown (parse, fence detection, fallback on invalid) | teeth: real (bad parse = diagram not rendered)

**Tests/ViewerCoreTests/HTMLRendererSafeURLTests.swift** (64 LOC) — tier: headless-unit | framework: XCTest | pins: URL sanitization in rendered HTML (javascript:, data:, vbscript: schemes neutralized) | teeth: real (miss = link-click injection)

**Tests/ViewerCoreTests/HTMLRendererTests.swift** (291 LOC) — tier: headless-unit | framework: XCTest | pins: markdown → HTML rendering (headings, code, lists, nested structures, edge cases) | teeth: real (render error = wrong visual output)

**Tests/ViewerCoreTests/HTMLSanitizerPolicyGuardTests.swift** (70 LOC) — tier: headless-unit | framework: XCTest | pins: sanitizer policy invariants (no script/iframe/form escape, event-handler quote-aware tokenizer H1b hardening) | teeth: real (regex bypass = XSS)

**Tests/ViewerCoreTests/HTMLSanitizerTests.swift** (347 LOC) — tier: headless-unit | framework: XCTest | pins: XSS sanitization (script/iframe/form/style/meta/object stripping, event-handler removal, javascript:/vbscript: URL neutralization, quote-adjacent & slash-separated handler bypasses) | teeth: real (sanitizer miss = on-screen XSS)

**Tests/ViewerCoreTests/HTMLTrustModeTests.swift** (108 LOC) — tier: headless-unit | framework: XCTest | pins: trust mode (secure/trusted state machine, opt-in JS/remote-resources) | teeth: real (state leak = unintended script execution)

**Tests/ViewerCoreTests/HTMLTrustPolicyTests.swift** (157 LOC) — tier: headless-unit | framework: XCTest | pins: trust policy enforcement (file: URL scope, remote-resource blocking, CSP envelope) | teeth: real (policy miss = exfil or script exec)

**Tests/ViewerCoreTests/HTMLVisitorSlugTests.swift** (65 LOC) — tier: headless-unit | framework: XCTest | pins: HTML visitor slug generation (anchor ID uniqueness, URL escaping, special-char handling) | teeth: real (slug collision = link target mismatch)

**Tests/ViewerCoreTests/HTTPClientCoreTests.swift** (282 LOC) — tier: headless-unit | framework: XCTest | pins: HTTP client (request building, header encoding, response parsing, error handling, timeout) | teeth: real (parse error = silent empty response)

**Tests/ViewerCoreTests/HTTPRequestStoreTests.swift** (177 LOC) — tier: headless-unit | framework: XCTest | pins: HTTP request history persistence (cache, dedup, max-entries cap) | teeth: real (bad cache = duplicate requests or stale responses)

---

## Test-Type Taxonomy

| Category | Count | % | Notes |
|----------|-------|---|-------|
| **Pure logic / model** | ~48 | 63% | File ops, tree, find, format, formula, git, hex, HTML, layout. Core logic — all headless-unit, most real teeth. |
| **Perf/bench** | 4 | 5% | FoldBench, HotPathPerf, FlameProfile, FlameInteraction. Best-of-N sampling, loose ceilings for CI stability. |
| **Security (XSS/injection)** | ~12 | 16% | HTMLSanitizer, HTMLDocumentPolicy, HtmlExportXSS, HTMLRendererSafeURL, SQLite escape patterns in git/HTTP. Real teeth — active attack class. |
| **FSEvents / file-system** | ~4 | 5% | FileWatcher, FolderWatcher, FileTree mutation. Real in-process, medium-confidence teeth. |
| **Data persistence** | ~6 | 8% | History, session store, go-to-path store, hot-exit. Real round-trip tests; corruption = silent data loss. |
| **Encoding / robustness** | ~2 | 3% | G5ParserHardening (multi-layer audit rollup); TextDecoder encoding-detection parity. Real teeth — adversarial inputs. |

### Coverage shape

- **Over-tested:** Pure model logic (formula, formatter, tree traversal, HTML sanitization) — good depth, multiple fixtures, edge cases, invariant guards.
- **Under-tested:** Async/threading boundaries (FSEvents callback reentrancy, concurrent cache invalidation) — only race-detection via TSAN; no deterministic multithreading fixtures.
- **Absent:** Live UI tier (T4 `LiveAppTestCase` / T5 pixel) — all headless. No gutter-fold visibility, no caret-position screen render, no scroll sync, no editor surface. Render correctness (tabs, panels, menu) is owner-driven or deferred to VM.

---

## Harness & Infra Patterns Worth Porting

### Base classes & utilities

- **`TierBaseCases` hierarchy:** Declares tier (T1/T1m/T2p/T4/T5) at class level via `testTier` property; `TierGateObserver` sentinel-file guards prevent heavy tiers from running host headless (self-skip if not in GUI session).
- **Per-test temp dir:** `FileManager.default.temporaryDirectory` with UUID subdirs, cleaned in `tearDown`. NEVER `~/Documents` or `~/Desktop` (iCloud sync risk). Good pattern: explicit setUp/tearDown with error propagation.
- **Fixture builders:** `sampleTree()`, `sampleCorpus()` — small, self-contained data structures for unit tests; prefer immutable structs for determinism.

### Negative controls & invariants

- **`jsSignificantContent()` independent lexer:** Formatter tests encode a **second implementation** to verify the primary doesn't drop/corrupt tokens. Catches lexer bugs that would silently corrupt output. Worth porting for any language-aware tool.
- **Best-of-N sampling for perf:** Bench tests take median-of-3 (cold) or median-of-11 (warm) to amortize GC/scheduler noise. Thresholds are ~10–30× the observed baseline, loose enough to not flake but tight enough to catch 10× regressions.
- **TSAN race guards:** `FileWatcherStopRaceTests` uses Swift concurrency + TSAN to catch UAF on shutdown. OS signals the race if callback re-enters while tearing down.

### Audit-driven test suites

- **`G5ParserHardeningTests`:** 414 LOC bundling guards from a **prior multi-layer code audit** (G5). Single file per audit finding class (SCALE, I18N, CORR, PARSE, PERF, WV) — a pattern for "maintain audit teeth after review."

---

## Flake & False-Green Risks Observed

1. **Perf-ceiling flakes under load:** `FoldBenchTests`, `HotPathPerfRegressionTests` use best-of-N to mitigate, but CI under heavy machine load can still breach loose ceilings. Mitigation: re-run on flake; consider lower-noise CI tier (e.g. dedicated perf box).
2. **Git tests skip cleanly if `git` missing:** `GitClientTests` throws `XCTSkip` if `/usr/bin/git` unavailable. Good UX, but silent skip on missing tool can hide setup issues. Recommendation: log skip reason prominently.
3. **HTML/XML parser permissiveness:** `FormatterTests` for XML note "XMLDocument is permissive — garbage might parse to text node." Weak invariant check. Real tests should validate exact shape, not just "no crash, non-empty output."
4. **Encoding detection ambiguity:** `G5ParserHardeningTests` handles CP1252 vs Latin-1 fallback, but conflicting encodings (e.g. 0x80–0x9F valid in CP1252 but not Latin-1) can flip results. Ordering matters; tests pin the priority but don't verify stability across encoding corpus.

---

## Rebuild Notes — Day-1 Test Strategy

### What to keep / adapt

1. **Audit-driven suite pattern (G5):** Each code audit should spawn a consolidated test file bundling all findings. Single-digit files per audit, comprehensive coverage, future-proof against feature refactors.
2. **Invariant guards for multi-stage pipelines:** Formatter's independent lexer, HTMLSanitizer's positive/negative attack corpus, git's lossy-decode pattern — these are load-bearing. Codify them early.
3. **Tier-based gating:** The `TierBaseCases` / `TierGateObserver` pattern successfully prevents heavy tests from running on the host. Replicate for render/UI tiers in the new codebase.
4. **Per-surface real-render matrix (from CLAUDE.md mandate TSK-1539):** This batch lacks it — no T4/T5 tests for visual output (editor gutter, fold indicators, hex dump layout, gallery shapes, etc.). New build should START with the matrix: every content surface needs ≥1 test per tier (WV/T1m/T4/T5/AX).

### What to avoid / improve

1. **Loose perf ceilings masked real regressions:** `HotPathPerf` 10–30× thresholds are CI-safe but miss gradual drift. Consider a **trend-tracking dashboard** (monthly perf baseline snapshots) alongside absolute thresholds.
2. **Async/race testing is **TSAN-only**:** No deterministic race fixtures. For Rust core, add `loom` proptest fixtures for high-confidence concurrency testing.
3. **UI visibility tests deferred to owner:** "Fixed on host, unverified on screen" is recurrent miss. Enforce **mandatory VM pixel tests** (T5 `PixelTestCase`) for any surface that renders (editor, panel, menu). The new codebase should front-load one T5 test per surface **day one**.
4. **`HeadlessUITestCase` → T1m:** Tests labeled "host-safe" but no guarantee they won't touch AppKit or fire up a SwiftUI canvas. Use a **strict mode** (block `NSApplication`, `NSWindow`, `UIApplication` imports in headless tests) to prevent accidental environment coupling.

### Evidence classes (from CLAUDE.md TSK-1543/TEST_PYRAMID)

**Mandate:** Every feature needs ≥1 test per class:
- **WV (WebView):** In-process markdown/HTML rendering.
- **T1/T1m:** Headless unit (host-safe).
- **T4 (LiveAppTestCase):** Real app spawned; UI automation possible.
- **T5 (PixelTestCase):** WindowServer pixel capture.
- **AX (Accessibility):** Real AXUIElement interaction (off-limits for agent, owner-only).

This batch covers WV / T1m / T1m-bench. New build should ensure **every feature** has:
- T1m logic test (model + API surface)
- WV test if WebView is involved (CM6 editor, markdown/HTML preview)
- T5 pixel test if visual output is user-facing
- AX test only if feature is accessibility-critical (menus, keyboard nav)

---

## Summary

This 76-file slice represents **mature unit coverage** of pure-logic subsystems (find, format, git, hex, HTML rendering/safety, tree structure). Real teeth on security (sanitizer, policy) and data integrity (undo/redo, persistence, encoding). Weakness: **no UI validation**. The rebuild should front-load the T4/T5 layer for every surface, enforce the real-render matrix at grooming time, and audit-drive guards for each pre-launch finding.
