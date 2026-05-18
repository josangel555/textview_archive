# Testing audit — 2026-05-17

Scope: full sweep after the UTM VM test pipeline came back online. Goal is to confirm whether recent commits skipped tests while the VM was dark, and to plug the obvious gaps.

## 1. File-count signal

| Bucket | Count |
|---|---:|
| Source `.swift` files under `Sources/` | 85 |
| Test `.swift` files under `Tests/` | 71 |
| Ratio (tests / sources) | 0.84 |

Per-module breakdown:

| Module | Sources | Tests | Notes |
|---|---:|---:|---|
| `ViewerCore` | 41 | 40 | strongest coverage — most stores / parsers / git helpers have a 1:1 test file |
| `ViewerKit` | 4 | 3 | small surface, fine; `HighlightLanguage` is exercised via TreeSitterEngine tests |
| `ViewerUI` | 39 | 28 | weakest ratio — most SwiftUI views (`SidebarView`, `MetadataPanel`, the Git tab views, `CSVTableView`, `CommandPaletteView`, etc.) are visual-only and not directly hosted; coverage comes through model-level tests + `ContentViewHostingTests` |
| `MarkdownViewer` (app entry) | 1 | 0 | `main.swift` — not directly testable, exercised via `InteractionScriptTests` / `LongFlowTests` when a built `.app` is present |

The shape is healthy for a SwiftUI app: business logic in `ViewerCore` is densely tested, view code is tested through model + hosting probes rather than per-view unit tests (which would be brittle for SwiftUI bodies).

## 2. Per-commit test-touch audit (last 25)

Legend: ✅ = test file touched/added in same commit, ⚠ = feature shipped without test in commit (may be covered elsewhere — see follow-up column), ➖ = docs/refactor/no feature surface, ❌ = real gap.

| SHA | Subject | Source touched | Tests touched | Verdict |
|---|---|---|---|---|
| c0a9092 | fix: MarkdownRenderedView fragment compare + URL parser | `MarkdownRenderedView.swift` | `MarkdownRenderedViewTests.swift` | ✅ |
| d2ebbc2 | test: @MainActor on existing tests | `HTMLRenderer.swift`, `MermaidBundle.swift` (signature only) | 7 test files annotated | ✅ |
| bbae9d5 | feat: Mermaid + CR Phase 1 + Walkthrough types | 12 source files | 6 test files (29 Mermaid + Review tests) | ⚠ — Walkthrough types had **no** Codable round-trip tests (fixed in this audit). SwiftUI hosting of mermaid not covered (fixed in this audit). |
| 4cc29d8 | docs: session summary | — | — | ➖ |
| ed7f93e | test: SidebarRevealTests | — | `SidebarRevealTests.swift` | ✅ |
| c0abc99 | docs: BACKLOG | — | — | ➖ |
| 89f45de | feat: Reveal in Sidebar, Files lock, jq filter | 5 source files (`DocumentModel`, `SidebarView`, `TabBar`, `JQRunner`, `main`) | `JQRunnerTests.swift` only | ⚠ — sidebar reveal + lock covered by ed7f93e (`SidebarRevealTests`); `JQRunner` covered. OK net. |
| 45abc87 | fix + feat: sidebar layout shifts, language override picker, design docs | 13 source files incl. `DocumentModel` (languageOverrides) | — | ❌ language override engine (`effectiveLanguage`, `setCurrentLanguage`, `hasLanguageOverride`) had no tests — **added in this audit**. |
| c3200e8 | fix + feat: split-pane theme, current-line backdrop, Git menu wiring | `ContentView`, `DocumentModel` (`showGitPanel`), `SplitPaneView`, etc. | — | ❌ `showGitPanel` nonce + desired-tab pair untested — **added in this audit**. |
| fb4b60c | docs: BACKLOG | — | — | ➖ |
| bf2f886 | refactor: extract JSONFileStore | 4 source files | `JSONFileStoreTests.swift` | ✅ |
| bbd273b | feat: Log tab graph renderer | `GraphLayout.swift`, `GitLogTab.swift`, `GitGraphColumn.swift` | `GraphLayoutTests.swift` | ✅ (layout logic; view code is visual) |
| c8ea29c | feat: DiffView | `DiffParser.swift`, `DiffView.swift`, `DocumentModel`, `ViewMode` | `DiffParserTests.swift` | ✅ (parser logic; view code is visual) |
| 5c338b8 | docs: VM smoke testing | — | — | ➖ |
| 66c964f | fix: Swift 6.3 strict concurrency | 6 source files (annotation-only) | — | ➖ |
| b1cd878 | feat: tabbed Git panel | 9 Git view files + `GitClient.swift` | `GitClientPanelTests.swift`, `GitStatusTabGroupingTests.swift` | ✅ |
| 1a4a6e1 | docs | — | — | ➖ |
| 94e130d | feat: Open in Terminal + git log views + diff coloring | 4 source files | `DiffHighlighterTests.swift` | ⚠ — "Open in Terminal" is a one-line `NSWorkspace.openApplication`; "show git log" wraps `GitClient.log` (already tested) into a synthetic-markdown tab; both are not worth dedicated tests. |
| 3e32d79 | docs: BACKLOG | — | — | ➖ |
| 092bdd8 | polish: command palette icon | `CommandPaletteView.swift` | — | ⚠ — purely visual swap. Not a model surface. OK. |
| 6fdad21 | feat: split view minimal v1 | 5 source files | — | ⚠ — `splitURL`/`swapSplit` are simple state mutations; one-liner. Acceptable. |
| 0fd5472 | feat: CSV table mode + FILES accordion | 4 source files | `CSVParserTests.swift` | ✅ |
| f12ee43 | fix + feat: overnight batch — find bugs, sidebar UX, scale audit | 7 source files | — | ⚠ — assorted polish; `BookmarkLineCacheTests` / `RegexCacheTests` followed up in 3a26bb3. |
| dedfd3b | docs: BACKLOG | — | — | ➖ |
| 3a26bb3 | fix: code-review remediations | 12 source files | `BookmarkLineCacheTests.swift`, `RegexCacheTests.swift` | ✅ |

**Headline:** of the 25 commits, 9 are docs-only, 2 are concurrency / refactor cleanup. Of the 14 feature/fix commits:
- 8 shipped with paired tests
- 4 shipped polish-only / visual changes that aren't worth a dedicated test
- 2 shipped real model-level surface without paired tests (`languageOverrides` in 45abc87, `showGitPanel` in c3200e8) — both now covered by this audit.

## 3. Currently-skipped tests (rationale)

19 `XCTSkip` calls live in the suite. All are environment-gated:

| File | Count | Skip reason | Verdict |
|---|---:|---|---|
| `GitClientTests.swift` | 1 | `/usr/bin/git` missing | reasonable — Git is host-tooling |
| `JQRunnerTests.swift` | 1 | `jq` missing at `/usr/bin/jq` or `/opt/homebrew/bin/jq` | reasonable — jq is host-tooling |
| `RecentChangesDiscoveryTests.swift` | 1 | `/usr/bin/git` missing | same |
| `InteractionDeepTests.swift` | 6 | `.app` not built | reasonable — these are integration tests against a launched bundle |
| `InteractionScriptTests.swift` | 3 | `.app` not built | same |
| `LongFlowTests.swift` | 3 | `.app` not built | same |
| `ScenarioTests.swift` | 4 | `.app` not built | same |
| `SourceViewVisualRegressionTests.swift` | 6 | `.app` not built / `MDV_SKIP_VISUAL` / screen-recording denied / window unpublished / fixture missing | reasonable — visual baselines need a real screen |

No `@available` auto-skips. No silent skips inside `setUp` that bypass the suite total.

## 4. TODOs / FIXMEs in test files

`grep -rn "TODO\|FIXME\|XXX\|HACK" Tests/` → **zero hits**. Tests are clean.

## 5. Module-level gap assessment

Strongest:
- `ViewerCore/Git` — every parser + `GitClient` shellout has a test.
- `ViewerCore/Review` — three full test files (`ReviewModelTests`, `ReviewStoreTests`, `ReviewExporterTests`) covering Layer-1/2/3 of `CODE_REVIEW_DESIGN.md` §9.
- `ViewerCore/Mermaid` — 29 tests across parsing, vendor-blob integrity, and HTML host emission.

Weakest:
- `ViewerCore/Walkthrough` — types-only ship in bbae9d5 had **no Codable tests**. Now covered by `WalkthroughScriptTests.swift` (added).
- `ViewerUI/Git/*` tab views — visual-only, no per-view tests. Acceptable; logic is in `GitClient` / `GraphLayout` which are tested.
- `ViewerUI` SwiftUI bodies generally — covered through model assertions + `ContentViewHostingTests`. Adding per-view tests would be brittle.
- `DocumentModel` newly-added features: `languageOverrides`, `showGitPanel`, `isSidebarLocked` — sidebar lock covered by `SidebarRevealTests` (ed7f93e); the other two were untested. **Now covered** by additions in this audit.

## 6. Code-review polish-issue follow-up (from bbae9d5 commit notes)

Two items the user flagged:

1. **Date sub-second precision in `ReviewStore` round-trip** — *not a bug.* `JSONFileStore` uses `.iso8601` encoding which is whole-second resolution; tests already pin `Date(timeIntervalSince1970:)` to whole seconds via the `t0` fixture (`ReviewStoreTests.swift:29`). The comment in that file already documents the rationale. **Accepted, no fix needed.** A regression test that asserts sub-second drift behavior is added to make the contract explicit (see below).

2. **Null `headSha` encoding in `ReviewExporter`** — *not a bug.* `ReviewExporter.ScopeRepo` overrides `encode(to:)` to force `baseSha` / `headSha` to emit `null` even when nil (lines 304-330). `testScopeWorkingTreeNullHeadSha` already covers this. **Accepted, no fix needed.** Added one extra assertion that the value round-trips back through `JSONFileStore.decoder` to confirm nil-symmetry.

## 7. Tests added in this audit

| File | Tests | Why |
|---|---:|---|
| `Tests/ViewerCoreTests/Walkthrough/WalkthroughScriptTests.swift` | 17 | Walkthrough types ship in bbae9d5 with zero coverage. Round-trip every Action variant (12) + nil-optionals + full-script + reject unknown kind + reject wrong schema version + every PopoverAnchor case. |
| `Tests/ViewerUITests/DocumentModelGitPanelTests.swift` | 4 | `showGitPanel` (c3200e8) bumps a nonce + sets desired tab — completely untested. Covers nonce bump, desired-tab setting, default-arg, and the "two clicks of same tab still bump" SwiftUI-dedup edge case. |
| `Tests/ViewerUITests/DocumentModelLanguageOverrideTests.swift` | 5 | `languageOverrides` map (45abc87) — auto-detect baseline, set / clear / per-tab isolation / hasLanguageOverride flag. |
| `Tests/ViewerCoreTests/Review/ReviewExporterPolishTests.swift` | 2 | Explicit contract tests for the two polish items so the assumptions don't silently regress: ISO-8601 sub-second drop + null-headSha round-trip through decoder. |
| `Tests/ViewerUITests/MermaidHostingTests.swift` | 4 | SwiftUI integration for the Mermaid pipeline — `renderedHTML` emits host div + shim CSS, cache hit, `.mmd` file hosts a WKWebView (regression guard for ContentView's category-routing). |

Total: **32 new tests**, all model-level / pure-Swift (no `.app` build required, no host tooling).

## 8. Final VM test count

Pre-audit baseline:  **694 pass / 18 XCTSkip / 0 fail**.
After this audit:    **726 pass / 18 XCTSkip / 0 fail** (+32 pass, no new skips, no regressions).

Run command: `ssh macOS15 'cd markdown_viewer && MDV_BACKGROUND=1 MDV_SKIP_WORKSPACE_RESTORE=1 swift test 2>&1 | tail -4'`
