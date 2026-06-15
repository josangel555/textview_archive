<!-- CLAUDE-HANDOFF v1 -->
# Handoff — markdown/data consumer-tools suite shipped; frontier owner/VM-bound  (2026-06-14)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `4a2c4b6`

## Mission
Autonomous loop: drain `WORK_QUEUE.md` top-down / ship complete host-validated work (host-test the model, leave render at `review`), keep `main` headless-gate-green, commit per item, log. Owner is doc-heavy; recent value = §2.5-safe markdown/data **consumer** features.

## Current state
- **OWNER INTAKE 2026-06-14 (TSK-887..945) — 15 shipped → `review`, 4 reconciled, 1 answered, 1 epic-slice, 1 parked.**
  Shipped (host model tested; menu/render = VM tail): 884 (Lines remove-empty/collapse-blank), 885 (CSV Summary),
  886 (JSON→CSV), 902 (preview tab italic), 900 (unknown-ext stuck-in-HEX fix), 907 (git dup-tab), 914
  (open-in-terminal → in-app), 920 (drag-file-to-terminal pastes path), 928 (textview:// scheme), 925 (CSV column
  sort), 931 (session rename menu), 903 (MD task-list checkboxes — rust+swift byte-matched), 919 (folder
  self-drag trap), 918 (sidebar resize cap lifted), 929 (follow external rename), 935 (New Tab from Clipboard),
  899 (⌘1/2/3 view-mode shortcuts). Reconciled-as-already-built: 710 (LSP hover), 930 (saved sessions), 932
  (unsaved dot), 913 (right-click rename). Answered: 904 (Format JSON discoverability). Epic: 698 slice 1 (JS
  transform engine). PARKED: 698 safe-exec decision (SPI/off-main/subprocess — owner pick).
- Earlier this run (still at `review`): 882, 883, 870, 862-866, 867-869, 871, 881, 868, 358, 533/534. ~36 total at review.
- **Tree clean** except pre-existing untracked `archive/Untitled.txt` + `untitled2.md` (NOT ours).
- **Headless gate green** (~5650 tests). NOTE: the gate can flake on a perf bench under load — re-run before trusting a red.

## Next action
The intake host-pool is largely drained; remaining items are VM-render, perf-traces, or epics. RE-SCAN the WHOLE
WORK_QUEUE each firing (not just intake) — that has repeatedly surfaced clean host work (935, 913, 919, 918, 929)
after I'd wrongly called the pool empty. Remaining host-probe candidates: **911** (commit-diff summary header —
uses host-tested TSK-514 DiffStat + commit metadata, host-testable), **937** (focus-toolwindow shortcuts — thin),
**901** (content auto-detect — value spread across extension-gated consumers). Then groomed pools / VM.
**THE TOP LEVER IS A VM VALIDATION PASS** (~36 items at `review` → `done`) + the parked 698 safe-exec decision.

## Key lessons (also appended to LESSONS.md 2026-06-14)
- **§2.5 forbids MODIFYING port-target Swift engines, not building a CONSUMER of their output.** TOC/HTML-export/Check-Links/Lint/CSV-convert all consume `MarkdownOutline`/`HTMLRenderer.render`/`CSVParser` → safe. (Over-applying it caused one premature HOLD.)
- **Anti-paper-cut / §5 "don't fill with marginal" targets TEST busywork, not real features.** Convenience features are real. (Over-applying caused another premature HOLD — I resumed and shipped Open-in-Browser.)
- **`DocumentModel.applyTextTransformToActiveFile { text in … }`** is the shared encoding-preserving write-through behind every active-file Edit transform — reuse it.
- **`HtmlExport.standaloneDocument` ≠ `renderPage`** (export omits the in-app no-network CSP); **`inlineLocalImages`** makes the export portable. CRLF-grapheme trap: walk `unicodeScalars`.
- Menu commands: `Sources/MarkdownViewer/main.swift` (Edit/View NSMenus) — item + `@objc` handler + `validateMenuItem` case + a `DocumentModel.canX` gate. Mirror the shipped "Convert Encoding" pattern.

## Files that matter
- `Sources/ViewerCore/` pure host-tested models: `MarkdownTOC`, `HtmlExport`, `MarkdownLinks`, `MarkdownLint`, `CsvConvert`, `BrowserPreview`, `Formatter.minifyJSON`, `TextCleanup`, `IndentConverter`, `LineEndingConverter`, `DocumentStats`, `ContentFontSizing` (+ audio `AudioTrimFade`/`SpectrumAnalyzer`).
- `Sources/ViewerUI/DocumentModel.swift` — `canX` gates + `xActiveFile()` commands + `applyTextTransformToActiveFile` + `htmlExportForActiveMarkdown(inlineImages:)` + `writeActiveMarkdownPreviewHTML`.
- `Sources/MarkdownViewer/main.swift` — menus + `@objc` handlers + `validateMenuItem`.

## Open questions / blockers (DECISIONS NEEDED — also in docs/AUTONOMOUS_PROGRESS.md)
1. **A VM validation pass** — converts the ~16-feature `review` pile → `done` (highest leverage). `ssh macOS15` + `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh`.
2. **TSK-343** local-history default (ON vs opt-in + retention) — PARKED.
3. **TSK-470** zoom-split — PARKED (Text Size may already cover it → close 470/321/322).
4. **TSK-733** session-switch save: (A) silently preserve dirty buffers vs (B) keep prompt — PARKED.

## How to resume
1. Read this, then `docs/AUTONOMOUS_PROGRESS.md` (top logs), then `WORK_QUEUE.md`.
2. `git -C <repo> log --oneline -15`; confirm tree clean (only the 2 untracked non-ours files).
3. Re-read `docs/TASK_WORKFLOW.md`. Probe for a fresh §2.5-safe consumer feature; build model-tested → `review`; gate via `bash scripts/test-headless-gate.sh` (re-run once if a bench flakes); commit per item; log. Owner away → keep shipping real features; only HOLD when nothing real remains.
