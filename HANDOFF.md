<!-- CLAUDE-HANDOFF v1 -->
# Handoff — markdown/data consumer-tools suite shipped; frontier owner/VM-bound  (2026-06-14)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `60a6cec`

## Mission
Autonomous loop: drain `WORK_QUEUE.md` top-down / ship complete host-validated work (host-test the model, leave render at `review`), keep `main` headless-gate-green, commit per item, log. Owner is doc-heavy; recent value = §2.5-safe markdown/data **consumer** features.

## Current state
- **21 features shipped this run → `review`** (host-tested model + render/menu = VM tail). Recent (newest first):
  - Editor ▸ Lines: in-place Sort/Reverse/Remove-Duplicates (883) + Remove-Empty/Collapse-Blank (884).
  - Markdown: Promote/Demote Headings (882).
  - **Data interop set:** CSV→Markdown/JSON (870), **CSV Summary (885)**, **JSON→CSV (886)** — all pure §2.5-safe consumers.
  - LSP hover (710) reconciled — ALREADY BUILT in CM6 (stale entry), → review, no code.
  - 675 epic slices: line-endings (862), doc-stats + trim/final-newline (863), indentation (864), TOC (865).
  - Markdown docs/export: Copy/Export HTML (866), Check Links (867), Lint (869), self-contained HTML (871), Open in Browser (881), Minify JSON (868).
  - Audio (533/534), content Text Size base×zoom incl. rendered-markdown (358).
  - Validated (host): 853 (highlight warm), 575 (clippy cast-ratchet).
- **Tree clean** except pre-existing untracked `archive/Untitled.txt` + `untitled2.md` (NOT ours).
- **Headless gate green** (~5623 tests). NOTE: the gate can flake on a perf bench under load — re-run before trusting a red.

## Next action
The clean high-value host pool is thin but the **§2.5-safe CONSUMER vein keeps yielding when probed** (don't HOLD prematurely):
1. Probe for a fresh consumer/output feature (new file consuming an existing model/engine output — safe even when the engine is Rust-ported). Candidates noted as borderline: Open-in-Browser (done), file checksum, highlighted-code-as-HTML, more lint rules.
2. A real (even convenience) user feature is NOT the "marginal work" the SOP forbids — that rule targets TEST busywork. Ship real features; only HOLD when truly nothing real remains.

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
