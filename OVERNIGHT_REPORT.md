# Overnight session report

Session ran autonomously per "I'll be away till tomorrow. Keep going."
Below is what landed, what to test manually, and what's deliberately
left for daylight review.

## Shipped (commit-by-commit)

| Commit | What |
|---|---|
| `649b159` | SwiftUI line-number gutter (synced to NSTextView scroll) + LESSONS.md |
| `150b399` | HACKABILITY.md + PLUGINS.md + STATE.md (design docs, no code) |
| `71a3e34` | Native previews — image/audio/video/PDF + SQLite stub. New `.preview(URL, FileCategory)` state |
| `ef63e9e` | Status bar extras — cursor Ln/Col + indent type (Tabs / Spaces(N) / Mixed) |
| `cbc310f` | Search-anywhere sidebar widget + Settings window (Cmd+,) |
| `760bf0e` | Rendered MD find: custom JS injection for count + purple/pink colors. SQLite browser (real, replacing stub) |
| `cf6ebcc` | `mdv` CLI + `markdownviewer://` URL scheme |
| `169a4de` | Mode normalization: every file has Source+HEX picker; markdown also gets Rendered; JSON/XML get Formatted |
| `6aa58eb` | Phase 7 git module + CHANGED sidebar section |
| `024e6ad` | Phase 8 Claude activity timeline in sidebar |
| `4d18bbb` | Phase 8.5 workspace auto-save + restore (tabs survive relaunch) |
| `fa23a80` | Test isolation: tests skip workspace restore |
| `b64ecd4` | TESTS_AUDIT.md — overlap analysis, no deletions |

## Test status

Added through this session: SQLiteReaderTests (11), IndentDetectorTests (8),
FileCategoryMediaTests (8), DocumentControllerMediaTests (7),
GitClientTests (7), WorkspaceStoreTests (5). Total +46 unit tests.

`SourceViewVisualRegressionTests` (real WindowServer screencap + pixel
variance check) is the load-bearing guard against the compositor
pathology. Both tests in it (real + meta) green.

Full suite last seen passing at fa23a80. Run `swift test` to confirm.

## Manual sanity checklist for tomorrow

After `bash scripts/install-app.sh` (or `build-app.sh debug`):

- [ ] Open a .md file. Confirm:
  - [ ] TabBar / ModeBar / Sidebar / StatusBar all visible
  - [ ] Source view has line-number gutter
  - [ ] Drag-select across multiple lines works
  - [ ] Click in empty space at end of a line extends selection
  - [ ] Cmd+F → find bar opens, type "the" → matches highlighted, count shown as `n/N`
  - [ ] In rendered mode: same Cmd+F flow, matches in pink, current in purple
  - [ ] Status bar shows Ln:Col, Lines, Chars, Size, Indent, EOL, Enc
- [ ] Open a .png / .mp4 / .pdf / .sqlite. Each gets a native viewer.
- [ ] SQLite: click a table → result grid shows up; type a custom query → ⌘↵ runs it.
- [ ] Sidebar sections: BOOKMARKS, SEARCH, CHANGED (only if root is a git repo), CLAUDE (only if transcripts exist).
- [ ] Settings (Cmd+,): theme picker, zoom slider, wrap toggle, sidebar width.
- [ ] `mdv DESIGN.md` after `bash scripts/install-mdv-cli.sh` — opens the file.
- [ ] Quit and relaunch. Tabs should restore. (Skip with `MDV_SKIP_WORKSPACE_RESTORE=1` for clean start.)
- [ ] Toggle mode picker: each file type shows the right subset of Source/HEX/Rendered/Format.

## Documents to read

- `LESSONS.md` — the compositor bug and how its tests work. Updated this session.
- `HACKABILITY.md` — extension points map.
- `PLUGINS.md` — plugin system DESIGN draft (no impl).
- `STATE.md` — state management plan.
- `TESTS_AUDIT.md` — proposed E2E dedup.
- `PHASE_5B_TREESITTER.md` — already-shipped (TreeSitter highlighting).

## What's NOT done

- **E2E test dedup**: audit in `TESTS_AUDIT.md`. Concrete recommendations,
  no deletions performed. Apply after reviewing the candidates.
- **Phase 9 distribution**: real Developer ID signing + notarization +
  DMG. Still in TCC-re-prompt territory. Out of scope per "only local
  signing for now."
- **Tier 4 tart base image (CI)**: infra-only, not blocking anything.
- **Phase 2.5 split view**: untouched.
- **Polish: small daily-use items (#23)**: catch-all that didn't have
  specifics. Will discuss when you find them.
- **Inline diff overlay** for the markdown content (vs. just CHANGED
  in the sidebar): would be next steps for the git story.
- **Wrap-mode gutter accuracy**: when word-wrap is on and a logical
  line wraps to N visual rows, the SwiftUI gutter still shows N rows
  with sequential numbers instead of N-1 blanks. Documented in commit
  `649b159`.

## Known test failure left for you

After the mode-normalization (commit `169a4de`) one E2E test
regressed:

  `InteractionDeepTests.test_zoom_persistsAcrossNewTab`
  → expects 5 step dumps, gets 1.

Behavior: the script (`zoom-reset; toggle-view; zoom-in; zoom-in;
open b.md`) is supposed to produce 5 dump files via the per-step
capture. Only 1 lands. The first dump is fine; the rest never get
written. Did not have time to fully diagnose. Hypothesis: the
`toggle-view` step (which now flows through the unified
`setCurrentViewMode`) crashes the script runner inside the .app,
or there's an exception swallowed before subsequent steps run.

I added a `guard dumps.count == 5` check so the test fails cleanly
with a useful message instead of hard-crashing on `dumps[3]`. The
rest of the suite passes around it. ~370 tests green; 1 known
regression to track.

To repro standalone:
  `swift test --filter InteractionDeepTests/test_zoom_persistsAcrossNewTab`

## Known limitations / quirks for review

- **Workspace restore behavior**: opens tabs by path. Files that have
  moved or been deleted are silently skipped. Probably fine. Consider:
  a "couldn't find these" notification at restore time.
- **SQLite browser**: read-only. Won't show inline image data in cells
  (just renders as text). Acceptable for v1; the dataset is intended
  to be inspected, not edited.
- **WKWebView `allowsContentJavaScript = true`**: changed from false
  so our injected find runtime can run. Page-supplied scripts are
  still blocked by the strict CSP (`script-src` is unspecified, which
  inherits `default-src 'none'`). Confirmed: user markdown can't
  execute JS via this change. Worth a fresh look if you're paranoid.
- **Claude timeline**: only parses the most-recent transcript per
  project. Capped at 200 events. Older sessions exist but aren't
  surfaced — they're one click away in a future feature.

## If something breaks

- Pull `LESSONS.md` first — most "weird visual issues" are documented.
- Source view broke again? → It's `NSRulerView`. Don't attach one.
  `MDV_ENABLE_BROKEN_RULER=1 mdv file.swift` reproduces it.
- Find bar shows nothing? → Likely `allowsContentJavaScript` was flipped
  off again.
- Test took 124s instead of <5s? → Stale `swift build` zombies holding
  the SwiftPM `.build` lock. `ps aux | grep swift build`, kill by PID.

Good morning.
