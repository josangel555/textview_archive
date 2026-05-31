# TextView / MarkdownViewer — Claude instructions

## Testing rules

- **Do NOT run UI tests on the host Mac.** Anything that launches the
  `.app` / opens a window / spins up an NSApplication belongs on the
  UTM macOS15 VM. This includes:
  - `swift test` with no filter (sweeps L4/L5 live-app + visual tests).
  - `Tests/ViewerUITests/...` (interaction, scenario, visual, deep).
  - `scripts/vm-smoke.sh` (already VM-only).
- **OK on host (no UI):**
  - `swift build` for compile checks.
  - `swift test --filter ViewerCoreTests.<...>` for pure-logic suites
    (TabsState, CSVFilter, DocumentController, BookmarksStore, etc.).
  - `swift test --filter ViewerKitTests.<...>` for type/value tests.
- **VM workflow:**
  - Sync: `rsync -az --delete --exclude='.build/' --exclude='.swiftpm/'
    --exclude='dist/' --exclude='.git/objects/pack/'
    /Users/me/Documents/workspaces/claude/markdown_viewer/
    macOS15:markdown_viewer/`
  - Run: `ssh macOS15 'cd markdown_viewer && swift test'`
  - Smoke (build + run + screencap): `bash scripts/vm-smoke.sh`
  - The VM has no git remote — it's an rsync mirror. Do not
    `git pull` on the VM.
- **VM credentials**: host `macOS15`, user `vm-tester@<vm-ip>`,
  sudo password `<vm-sudo-password>`. Safe to `sudo -S` over ssh.

## Project-specific

- Bundle id stays `com.markdownviewer.MarkdownViewer` (TCC-stable).
- Local signing only (cert `MarkdownViewer Local Dev`); no Developer
  ID until shipping public.
- Bundle size cap: 37 MB total + 16 MB main-executable sub-cap (the
  lazy-grammar split moves parsers into `Contents/Frameworks/`, so the
  two caps are tracked separately). Enforced by
  `scripts/check-bundle-size.sh` (override via `BUDGET_MB` /
  `EXEC_BUDGET_MB`), wired into `scripts/build-app.sh`. The old "25 MB"
  figure predated the TreeSitter grammar expansion.
- Never write to `~/Documents`, `~/Desktop`, `~/Downloads` from
  automated paths. Use `FileManager.default.temporaryDirectory` (per-
  user `/var/folders/...`) for test scratch.
- Workspace state lives under `~/Library/Application Support/
  com.markdownviewer.MarkdownViewer/Workspaces/_last.json`.

## Quick references

- `BACKLOG.md` — pending work, decisions, and audit follow-ups.
- `LESSONS.md` — institutional knowledge (compositor bug, perf wins,
  signing, VM screen-capture privacy notes).
- `MANUAL_TESTING.md` — checklist for features without automation.
- `DESIGN.md` — top-level architecture.
- `docs/` — feature design docs (Mermaid impl, Walkthrough v2, Code
  Review, Sessions, LSP, Plugins v2, etc.).
