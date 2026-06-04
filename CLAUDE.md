# TextView / MarkdownViewer — Claude instructions

## Testing rules

Tier is the **type** (`Tests/ViewerUITests/Harness/TierBaseCases.swift`):
`HeadlessUITestCase` (T1/T1m/T2', the default) is host-safe; `LiveAppTestCase`
(T4, spawns `dist/TextView.app`) and `PixelTestCase` (T5, WindowServer pixels)
are heavy and VM-coupled. The heavy tiers **self-skip** when there's no built
bundle / no GUI session, so the bare `swift test` sweep now runs to completion
on the host — it just exercises the headless tiers and skips T4/T5.

- **The merge/PR gate runs the HEADLESS tiers on the host.** Use the gate
  script — it is what CI runs (`.github/workflows/pr.yml`):
  - `bash scripts/test-headless-gate.sh` — `MDV_HEADLESS_GATE=1 swift test
    --parallel`, then fails if any heavy-tier test ran its body (enforced by
    `TierGateObserver` via a sentinel file). Heavy tiers self-skip; this is
    host-green and non-disruptive (no window ever opens).
  - The bare `swift test` / `swift test --parallel` is fine on the host now —
    it completes (heavy tiers self-skip). Filter sweeps
    (`swift test --filter ViewerCoreTests.<...>` /
    `--filter ViewerKitTests.<...>`) remain handy for a fast pure-logic loop.
  - `swift build` for compile checks.
- **Heavy tiers (T4 `LiveAppTestCase` / T5 `PixelTestCase`) run for REAL only
  on the VM** — they need a GUI login session + Screen-Recording. They are the
  separate VM / nightly lane (`.github/workflows/nightly-vm.yml`,
  `scripts/test-in-vm.sh`), NOT the merge gate. Do NOT force them to run on the
  host (don't build `dist/` and then sweep): a window would open and disrupt
  your daily work. If you *want* to run them, use the VM.
- **The in-process live-WKWebView suites** (`ComponentVisualTests`,
  `ContentViewHostingTests`, `DiagnosticDumpTests`, `MermaidHostingTests`,
  `RenderedFindBarTests`) `#192`-gate themselves out of the bare sweep; run them
  with `MDV_RUN_WEBVIEW_TESTS=1 swift test --filter ...` in their own
  invocation. They are part of the VM / nightly lane, not the merge gate.
- **VM workflow:**
  - Sync: `rsync -az --delete --exclude='.build/' --exclude='.swiftpm/'
    --exclude='dist/' --exclude='.git/objects/pack/'
    /Users/me/Documents/workspaces/claude/markdown_viewer/
    macOS15:markdown_viewer/`
  - Run: `ssh macOS15 'cd markdown_viewer && swift test'` (or
    `bash scripts/test-in-vm.sh all` for build + full suite + JUnit).
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

## Task tracking (use it — don't just do work silently)

From now on, **track work as tasks** instead of doing it ad-hoc. File
generously and keep the board honest:

- **One task per unit of work** — every finding, bug, feature, sub-task,
  refactor, decision. When in doubt, file it. A task is cheaper than a lost
  thread.
- **Status discipline.** Mark a task `in_progress` BEFORE starting it and
  `completed` only when it's *fully* done **and validated** (headless gate green
  / tests pass). Never mark done on a partial or failing change. If blocked,
  keep it open and file a new task for the blocker.
- **Hesitancy / confidence tagging** — every task carries `metadata`:
  - `confidence`: `high` | `medium` | `low` (how sure I am of scope/approach).
  - `blocker`: `none` | `owner-decision` | `owner-dep-approval` |
    `live-validation` | `supervised` | `deliberately-deferred`.
  - `area`: `rust-core` | `monitor` | `perf` | `security` | `ci` | `poc` | …
  - and a subject prefix for at-a-glance scanning: `[DONE]`, `[BLOCKED:<why>]`,
    `[WONT-DO]`, `[SECURITY]`, etc.
- **Owner-gated items don't block the loop.** Anything needing the owner's
  decision (a dep approval, a risky supervised refactor) is filed as a
  `pending` task with `blocker` set AND appended to the `DECISIONS NEEDED`
  section of `docs/AUTONOMOUS_PROGRESS.md` — then move on to other work.
- **Check `TaskList` before creating** to avoid duplicates; **read the latest
  with `TaskGet` before updating** (staleness).
- This complements the durable docs (`AUTONOMOUS_PROGRESS.md` for the autonomous
  run log, `BACKLOG.md` for the standing queue) — the task board is the live
  per-item state; the docs are the narrative that survives compaction.

## Quick references

- `BACKLOG.md` — pending work, decisions, and audit follow-ups.
- `LESSONS.md` — institutional knowledge (compositor bug, perf wins,
  signing, VM screen-capture privacy notes).
- `MANUAL_TESTING.md` — checklist for features without automation.
- `DESIGN.md` — top-level architecture.
- `docs/` — feature design docs (Mermaid impl, Walkthrough v2, Code
  Review, Sessions, LSP, Plugins v2, etc.).
