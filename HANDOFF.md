<!-- CLAUDE-HANDOFF v1 -->
# Handoff — markdown docs-tools burst shipped; host pool thin, frontier owner/VM-bound  (2026-06-14)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `6f154e1`

## Mission
Autonomous loop: drain `WORK_QUEUE.md` top-down / ship complete host-validated work (host-test the model, leave render at `review`), keep `main` headless-gate-green, commit per item, log. The owner is doc-heavy; recent value has come from §2.5-safe markdown/data *consumer* features.

## Current state
- **Shipped this run (all → `review`, host-tested model + render/menu = VM tail):**
  - 675 epic (robust plain-text editor) slices: Convert Line Endings (862), Doc Statistics + Trim-Trailing/Final-Newline (863), Convert Indentation (864), Insert TOC (865). Epic 675 is `triaged` with 5 slices banked.
  - Markdown docs-tools: Copy/Export as HTML (866), Check Links (867), Lint Markdown (869).
  - Data: Minify JSON (868).
  - Earlier: audio spectrum (533), audio trim/fade (534), content Text Size base×zoom incl. rendered-markdown (358).
  - Validated (host): 853 (highlight warm), 575 (clippy cast-ratchet).
- **Tree clean** except pre-existing untracked `archive/Untitled.txt` + `untitled2.md` (NOT ours — leave them).
- **Headless gate green** (5567 tests).

## Next action
The clean high-value host pool is **genuinely thin** (verified across many firings: WORK_QUEUE top, security/rust-core/theming pools, 675 clean runway, host-validatable `fixed` pool, markdown output/quality vein — all tapped or VM/owner-gated). Next firing:
1. Probe ONCE for a fresh high-value §2.5-safe *consumer* feature (the TOC/HTML/Check-Links/Lint pattern — a NEW consumer of existing models/output is safe even when the underlying engine is Rust-ported).
2. If none: board grooming or a documented HOLD — do NOT manufacture marginal features (the owner's bar). Surface the owner unblocks.

## Key decisions & lessons
- **§2.5 is about not MODIFYING port-target Swift engines — building a new CONSUMER of their output/data is safe** (TOC consumes headings, HTML export consumes `render()`, Check-Links/Lint consume focused parsers). Don't over-apply §2.5 (it caused one wrong HOLD).
- **`applyTextTransformToActiveFile { text in ... }`** (DocumentModel) is the shared encoding-preserving write-through used by all Edit-menu text transforms (Convert Encoding/Line-Endings/Indentation, TOC insert, Minify JSON). Reuse it.
- **CRLF-grapheme trap**: `"\r\n"` is ONE Character — walk `unicodeScalars` (every pure transform here does).
- **HtmlExport ≠ renderPage**: export omits the in-app no-network CSP (else a browser blocks external images).
- Menu commands live in `Sources/MarkdownViewer/main.swift` (NSMenu; Edit + View menus): add item + `@objc` handler + `validateMenuItem` case + a `DocumentModel.canX` gate. Mirror the shipped "Convert Encoding" submenu pattern.
- The big banked `review` pile (~13 features) is owner/VM-gated — host-side validation is exhausted for it.

## Files that matter
- `Sources/ViewerCore/` pure models (host-tested): `MarkdownTOC`, `HtmlExport`, `MarkdownLinks`, `MarkdownLint`, `Formatter.minifyJSON`, `TextCleanup`, `IndentConverter`, `LineEndingConverter`, `DocumentStats`, `ContentFontSizing` (+ audio `AudioTrimFade`/`SpectrumAnalyzer`).
- `Sources/ViewerUI/DocumentModel.swift` — the `canX` gates + `xActiveFile()` commands + `applyTextTransformToActiveFile`.
- `Sources/MarkdownViewer/main.swift` — the menus + `@objc` handlers + `validateMenuItem`.

## Open questions / blockers (DECISIONS NEEDED — see docs/AUTONOMOUS_PROGRESS.md)
1. **A VM validation pass** — highest leverage; converts the ~13-feature `review` pile + many `live-validation` `fixed` items → `done`. `ssh macOS15` + `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh`.
2. **TSK-343** local-history default (ON vs opt-in + retention) — PARKED, `waiting:human`.
3. **TSK-470** zoom-split — PARKED: separate document-zoom vs the deliberate 2026-05 merge (Text Size may already cover it).

## How to resume
1. Read this, then `docs/AUTONOMOUS_PROGRESS.md` (top logs = current state + lessons), then `WORK_QUEUE.md`.
2. `git -C <repo> log --oneline -12`; confirm tree clean (only the 2 untracked non-ours files).
3. Re-read `docs/TASK_WORKFLOW.md`. Probe for a fresh §2.5-safe consumer feature; build it model-tested → review; gate via `bash scripts/test-headless-gate.sh`; commit per item; log. If genuinely nothing clean+high-value: groom or HOLD with the 3 decisions, don't manufacture marginal work.
