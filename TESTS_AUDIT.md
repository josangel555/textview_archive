# TESTS_AUDIT.md

Audit of the E2E test surface looking for tests that exercise
overlapping paths. Goal: cut wall-clock time without losing
confidence. Recommendations only — no deletions performed by this
pass. Review and apply selectively.

## Suite layout (Tests/ViewerUITests/)

| File | Tests | Approx wall-clock | Notes |
|---|---|---|---|
| AppLauncher.swift | — | — | Shared infra |
| BookmarkIntegrationTests.swift | 4 | <0.1s ea | Unit-y, fast |
| ComponentVisualTests.swift | many | <0.05s ea | Pure SwiftUI tree dumps |
| ContentViewHostingTests.swift | ~6 | <0.1s ea | NSHostingView introspection |
| CrossSearchIntegrationTests.swift | ~5 | <0.5s ea | Pure logic, no app spawn |
| DiagnosticDumpTests.swift | 7 | <0.5s ea | View tree walks |
| DocumentModelTests.swift | many | <0.05s ea | Model unit tests |
| DragDropTests.swift | ~3 | <0.5s ea | Mostly logic |
| FileWatcherIntegrationTests.swift | several | ~1s ea | Real FS, slow but unique |
| FindBarTests.swift | ~4 | <0.5s ea | Mostly logic |
| FormatToggleTests.swift | ~3 | <0.5s ea | Model unit |
| **InteractionDeepTests.swift** | 6 | **~2–3s ea (spawns app)** | Tab/palette/resize/zoom scripts |
| **InteractionScriptTests.swift** | 3 | **~2–3s ea (spawns app)** | View-toggle/tabs/zoom scripts |
| **LongFlowTests.swift** | 3 | **~3–5s ea (spawns app)** | 15-step scenarios |
| MarkdownRenderedViewTests.swift | ~3 | <0.1s ea | Logic |
| RenderedFindBarTests.swift | ~3 | <0.5s ea | Logic |
| **ScenarioTests.swift** | 4 | **~2–3s ea (spawns app)** | Scenario chains |
| SidebarModelTests.swift | many | <0.05s ea | Unit |
| **SourceViewVisualRegressionTests.swift** | 2 | **~3s ea (spawns app + screencap)** | Compositor regression — unique, don't touch |

Bolded files spawn the real `.app` via `AppLauncher`. They dominate
the suite's wall-clock. Total app-spawning tests: ~18 × ~3s ≈ 50s of
the ~75s full-suite time.

## Concrete overlap

### 1. Zoom-persistence trio is testing the same mechanic three ways

- `InteractionDeepTests.test_zoom_persistsAcrossNewTab`
- `LongFlowTests.test_zoomPersists_acrossFreshLaunch`
- `ScenarioTests.test_scenario_zoomPersistsAcrossViewToggle`

All three open the app, zoom in, do something, assert the model
zoom value persisted. The "across fresh launch" one is unique
(restart behavior) — keep it. The other two test that zoom is
in `model.zoom` after a model mutation — that's a model-level
property test, NOT a scenario test. Could move to `DocumentModelTests`
(no app spawn) and shave ~5–6s off the suite.

### 2. Tab open/close coverage spans 5 files

Every app-spawning test file opens at least one file and closes a
tab as part of its setup. The dedicated tests are:
- `InteractionDeepTests.test_tabCycling_nextPrev_andSelectByIndex` — unique
- `InteractionDeepTests.test_closeMiddleTab_keepsOthers` — unique
- `InteractionScriptTests.test_newTabAndClose_changesTabCount` — overlaps with `LongFlowTests.test_heavyTabChurn`
- `LongFlowTests.test_heavyTabChurn_openAndCloseManyTabs` — unique (stress)
- `ScenarioTests.test_scenario_openMultipleFiles_buildsTabList` — overlap with above

Recommendation: drop `InteractionScriptTests.test_newTabAndClose_changesTabCount`
(strictly weaker than `heavyTabChurn`) and `ScenarioTests.test_scenario_openMultipleFiles_buildsTabList`
(also weaker). Saves ~5–6s.

### 3. Rendered/Source toggle: 2 tests doing the same toggle

- `InteractionScriptTests.test_toggleView_swapsRenderedAndSourceViews`
- `ScenarioTests.test_scenario_renderedSourceRoundtrip_keepsContent`

Both: open markdown → toggle → assert view mode. Drop one. Saves ~3s.

### 4. ContentViewHostingTests vs DiagnosticDumpTests

Both walk the SwiftUI hosting tree asserting structure. The hosting
tests focus on NSHostingView types; the diagnostic-dump tests focus
on actual NSView positions. Different intent → keep both, but a
fast scan finds 2-3 cases with the same assertion shape:
- `DiagnosticDumpTests.test_tabBar_isPresent_andHasNonZeroFrame_whenFileOpened`
  overlaps with `ContentViewHostingTests` of similar name.

Not significant time savings — both are <0.5s. Skip.

### 5. App-spawn tests share boilerplate

Every app-spawning test does:
```
let appBundle = ...
killAndWaitForOldInstance()
try AppLauncher.runScript(...)
let dump = ...
```

This is in AppLauncher already, so no dedup needed here.

## Recommended pass (concrete)

1. **Move pure-property tests out of app-spawning files**:
   - Zoom-after-mutation → `DocumentModelTests`
   - Save: ~3 app spawns ≈ 9s.

2. **Delete strictly-weaker tests**:
   - `InteractionScriptTests.test_newTabAndClose_changesTabCount`
   - `ScenarioTests.test_scenario_openMultipleFiles_buildsTabList`
   - `ScenarioTests.test_scenario_renderedSourceRoundtrip_keepsContent` if covered by InteractionScript
   - Save: ~3 app spawns ≈ 9s.

3. **Merge complementary app-spawn tests into single scripts**:
   - Today: 4 separate "open + view-toggle + zoom" tests.
   - Could: one scripted scenario that does open + toggle + zoom +
     close in sequence and asserts model state at each step.
   - Save: ~3 app spawns ≈ 9s.

Total potential savings: ~25s, or ~33% of suite wall-clock.

## What I'm NOT recommending

- Deleting `SourceViewVisualRegressionTests.*`. Both tests catch a
  bug class no other test can see (LESSONS.md). Don't touch.
- Deleting any unique scenario — `test_dayInTheLife_15Interactions`
  is a high-confidence smoke that's worth its 4s.
- Deleting anything from `DocumentModelTests`,
  `CrossSearchIntegrationTests`, `BookmarkIntegrationTests`,
  `FileWatcherIntegrationTests`. They're cheap and specific.

## How to apply this audit

This document is what landed in the autonomous pass. The user wants
to review before deletions. Once approved, I can do the moves +
merges in a single batched commit; each step is independently
revertable.
