# TextView / MarkdownViewer — Claude instructions

## Testing rules

### Change → tests + tracker mandate (OWNER DIRECTIVE 2026-06-07)

Non-negotiable for **every** change. This codifies the terminal-tab-strip
miss, where a feature was shipped that headless tests "proved rendered" yet was
invisible on screen.

1. **Every change ships with tests.** Any code change MUST include corresponding
   new/updated tests. No test changes ⇒ the change isn't done.
2. **Cover all tiers that apply:** unit, integration, headless, AND UI tests —
   not just one.
3. **Real-UI tests run in the UTM VM** (T4 `LiveAppTestCase` / T5
   `PixelTestCase` / WebView suites), never the Mac host, unless the owner says
   otherwise. (Same as the 2026-06-06 directive below.)
4. **A headless "the element is rendered" check is NOT sufficient for UI.** An
   element can be in the view tree yet invisible on screen — zero/collapsed
   size, z-index/occlusion, color blending into its background (e.g. an
   *unemphasised* `selectedContentBackgroundColor` going grey), `isHidden`,
   `alpha`, clipping. When adding a UI element you MUST verify it is actually
   VISIBLE on screen (VM pixel capture / T5), not merely present in layout.
   NOTE the host limits found 2026-06-07: `NSView.hitTest` returns the hosting
   view for SwiftUI tap targets (SwiftUI owns its gesture routing), and
   `cacheDisplay` does NOT capture SwiftUI's CA-rendered layers — so true
   pixel/click validation of SwiftUI UI is VM-only.
5. **At least one test must INTERACT with the element** (click / keypress / etc.)
   to prove it exists and is interactable — "if it's not visible, how do we
   click it?" For SwiftUI, that's a VM UI test (real event) or, where a real
   event can't be synthesized, exercising the exact action closure the control
   is wired to (not a parallel reimplementation).
6. **Headless tests must pin each element's interaction BEHAVIOUR** — the
   model/state outcome of select/close/toggle/cycle/etc. — so a logic
   regression fails on the host gate even though the pixel check is VM-only.
7. **Every change has a `tasked` task.** No task ⇒ don't start. File it first.
8. **Drive `tasked` only via its MCP tools** (`mcp__tasked__*`) — never the
   retired `python3 /tmp/board.py`, never the human REST endpoint.

### Compositor occlusion + the ImageRenderer false-green trap (TSK-488, 2026-06-07)

The terminal-tab-strip miss recurred FOUR times because the symptom (no tabs)
was diagnosed with the wrong tool. Codified so we catch this class early:

- **An opaque, layer-backed `NSViewRepresentable` OCCLUDES a SwiftUI sibling
  drawn before it.** A SwiftUI stack hosting both a SwiftUI-drawn view and an
  `NSViewRepresentable` (CodeMirror WebView, terminal surface, any AppKit
  surface) is the danger zone: the representable becomes a real AppKit subview
  with its own `CALayer` that composites OVER earlier-painted SwiftUI siblings,
  even when geometrically adjacent (not overlapping). It is **position-
  dependent** — the SwiftUI view is fine if drawn AFTER the surface, blanked if
  drawn BEFORE. RULE: when a SwiftUI view shares a container with an opaque
  representable, give it its own layer ordered above the surface —
  `swiftUIView.compositingGroup().zIndex(1)` vs `surface.zIndex(0)` — in EVERY
  layout branch. Same family as the LESSONS `NSRulerView` sibling-blank.
- **`ImageRenderer` (and `cacheDisplay`, and headless frame-walks) give a FALSE
  GREEN for this class.** `ImageRenderer` rasterizes SwiftUI's OWN tree in
  isolation and draws a PLACEHOLDER for a representable — there is no opaque
  layer to occlude, so an occluded view renders perfectly. `cacheDisplay` is
  blind to SwiftUI CA layers (renders black). NEVER treat any of these as proof
  that on-screen UI is visible. The ONLY authority for "did it composite" is
  stage-④ WindowServer pixels: spawn the app + `screencapture -l<windowID>`
  (`PixelTestCase`/T5; harness `scripts/ui-snapshot.sh` + `MDV_UI_SCENE`).
- **Demonstrate TEETH on every real-UI test.** A green that has never been shown
  to go red is not a guard. After writing/maintaining a T5 pixel test, revert
  the fix once, rebuild, and confirm the test FAILS — then restore. A test that
  can't fail on the broken build is the false green we are trying to kill.

> **OWNER DIRECTIVE (2026-06-06): NO UI tests on the Mac — run UI / live-tier
> tests on the UTM VM only.** Never run T4 `LiveAppTestCase`, T5 `PixelTestCase`,
> the in-process WebView suites, or the `build-app.sh` pre-install smoke on the
> host (they open a window / spawn the app). The pre-install smoke is now opt-in
> (`MDV_RUN_SMOKE_GATE=1`); the headless gate (`test-headless-gate.sh`) is
> window-free and stays the host merge gate. UI validation → `ssh macOS15` +
> `bash scripts/test-in-vm.sh` / `bash scripts/vm-smoke.sh`. (The VM's *default*
> `swift` is 6.1.2, which CANNOT compile the test target — `scripts/test-in-vm.sh`
> auto-selects the installed Swift 6.3 toolchain via `TOOLCHAINS`; TSK-439 fixed.)

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
- **Run the suite on the VM as a validation step (owner standing ask,
  2026-06-06).** For substantive Swift changes, after the host gate is green,
  also run the suite on the UTM VM via `bash scripts/test-in-vm.sh` (it
  auto-selects the toolchain — see below). Two distinct VM signals:
  - **App-code forward-compat (Swift 6.1.2, the default):** a bare
    `ssh macOS15 'cd markdown_viewer && swift build'` uses 6.1.2, which is
    stricter than the host on default-actor-isolation — it caught the TSK-401
    skew. Good for compiling `Sources/`.
  - **Test target (needs Swift 6.3):** 6.1.2 REJECTS the test target's
    `try await super.setUp()` in `@MainActor` classes ("sending non-Sendable
    self") so the whole bundle fails to compile (TSK-439). `scripts/test-in-vm.sh`
    `select_toolchain()` picks the newest installed `swift-6.*-RELEASE`
    toolchain (currently **6.3**) and exports `TOOLCHAINS`, so `swift test`
    compiles + runs. A *bare* `ssh … swift test` does NOT (it uses 6.1.2) —
    use the script, or prepend `TOOLCHAINS=$(plutil -extract CFBundleIdentifier
    raw /Library/Developer/Toolchains/swift-6.3-RELEASE.xctoolchain/Info.plist)`.
- **VM workflow:**
  - Sync: `rsync -az --delete --exclude='.build/' --exclude='.swiftpm/'
    --exclude='dist/' --exclude='.git/objects/pack/'
    /Users/me/Documents/workspaces/claude/markdown_viewer/
    macOS15:markdown_viewer/`
  - Run: `ssh macOS15 'cd markdown_viewer && bash scripts/test-in-vm.sh test'`
    (auto-selects the 6.3 toolchain; `all` = build + full suite + JUnit). A bare
    `swift test` uses the default 6.1.2 and will NOT compile the test target —
    prefer the script (see the toolchain note above).
  - Smoke (build + run + screencap): `bash scripts/vm-smoke.sh`
  - The VM has **no Rust toolchain**: it links the host-built
    `rust-core/link/libmdvcore_ffi.a` (build it on the host first if Rust
    changed; the rsync ships it since `rust-core/` isn't excluded). Never
    `cargo build` on the VM.
  - The VM has no git remote — it's an rsync mirror. Do not
    `git pull` on the VM.
- **VM credentials**: host `macOS15`, user `vm-tester@<vm-ip>`,
  sudo password `<vm-sudo-password>`. Safe to `sudo -S` over ssh.

## Project-specific

- Bundle id stays `com.markdownviewer.MarkdownViewer` (TCC-stable).
- Local signing only (cert `MarkdownViewer Local Dev`); no Developer
  ID until shipping public.
- Bundle size cap: 48 MB total + 26 MB main-executable sub-cap (the
  lazy-grammar split moves parsers into `Contents/Frameworks/`, so the
  two caps are tracked separately). Enforced by
  `scripts/check-bundle-size.sh` (override via `BUDGET_MB` /
  `EXEC_BUDGET_MB`), wired into `scripts/build-app.sh`. The old "25 MB"
  figure predated the TreeSitter grammar expansion.
- Never write to `~/Documents`, `~/Desktop`, `~/Downloads` from
  automated paths. Use `FileManager.default.temporaryDirectory` (per-
  user `/var/folders/...`) for test scratch.
- **NEVER `killall MarkdownViewer` (or by any shipping exec name) in a
  script or test.** The installed `/Applications` app and every built/
  test-spawned bundle share the exec name `MarkdownViewer`, so a blanket
  `killall` SIGTERMs the owner's *running* app. `install-app.sh` no longer
  kills (macOS replaces a running bundle fine; new code on next relaunch);
  test spawns must be tagged (`MDV_TEST_INSTANCE=1`) and reaped by tag via
  `AppLauncher.killTestInstances`. If the owner says "something keeps
  closing my app," grep `killall` across `scripts/` + `Tests/` first.
- **The repo lives under iCloud-synced `~/Documents`** → the file provider
  re-stamps `com.apple.FinderInfo`/`fpfs#P` xattrs in real time, which trips
  `codesign --options runtime`. `build-app.sh` signs in a non-synced TMPDIR
  then swaps into `dist/`; `install-app.sh` `ditto --noextattr` + `xattr -cr`
  the installed bundle. Do codesign/xattr-sensitive work outside the synced
  tree, not in `dist/`.
- **Persisted state lives under TWO Application Support subdirs** (verified
  2026-06-06): `~/Library/Application Support/MarkdownViewer/` (NO bundle-id
  prefix) holds `Sessions/` (index.json + per-session snapshots + trash),
  `Workspaces/_last.json`, `bookmarks.json`, `history.json`, `recent-paths.json`;
  the bundle-id dir `~/Library/Application Support/com.markdownviewer.MarkdownViewer/`
  holds `Plugins/`, `Walkthroughs/`, `jdtls-data/`. Prefs (zoom/theme/wrap/window)
  are UserDefaults. `File → Reset` (`AppCacheReset`) clears these to a recoverable
  `_reset-backups/` backup.

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

## Automated / autonomous runs (SOP)

Standing operating procedure for autonomous/heartbeat runs (the screen is the
agent's until the owner says stop; work in waves, don't stop to ask "should I
continue", document blockers and move on):

- **Each firing:** read `docs/AUTONOMOUS_PROGRESS.md` (current wave + first
  unchecked item). If substantive work is already in flight this turn, treat the
  nudge as a no-op. A fresh/compacted session reads the latest
  `docs/HANDOFF_<date>.md` first.
- **Pick work from the `tasked` board** (`http://localhost:8787/mcp` JSON-RPC —
  the SYSTEM OF RECORD, NOT the built-in Claude Code TaskList). Helper:
  `python3 /tmp/board.py <tool> '<json>'`; agent `claude-mdv`; ids `TSK-###`.
  The board is **shared across projects** — grep this repo before acting on a
  task; skip foreign `agent:forge`/`sess-forge-*` tasks.
- **Priority:** SwiftUI app (`Sources/`) features/fixes FIRST each firing; fall
  back to the Rust TUI/web `[PORT]` lane only if no SwiftUI task is actionable.
  Prefer real features/bugs/perf over paper-cut test backfill (owner flagged that
  drift) — but DON'T ship a risky blind change; if it needs the screen/owner,
  file it and move on.
- **Lifecycle lanes:** `reported → ack → triaged → progress → fixed → review →
  validated → done`. Drive via the **`mcp__tasked__*` tools** (NOT the retired
  `python3 /tmp/board.py`); `task_advance` auto-walks lanes to `fixed`/`review`.
- **Agent self-validation (owner policy, 2026-06-07):** an agent MAY close its own
  work to `validated`/`done` via **`task_validate`** — BUT *only* with a `checks`
  artifact proving an **automated test that exercises the actual feature/behavior**
  and would fail if it regressed. The bar is "are we confident automated tests
  catch any regression of this behavior," not "build is green." Concretely:
  - **Pure-logic / model / FFI / parser behavior** (host-testable): write the
    behavior test, run it, attach the passing-checks artifact, self-validate.
  - **WebView/AppKit-*rendered* behavior** (CM6 editor pixels, gutter folds,
    indent-guide lines, caret insert, SwiftUI view wiring): host tests cover only
    the model layer — the render path has NO host coverage — so do NOT self-validate
    on host alone. Either add a VM UI test (nightly lane) that covers it, then
    validate, or leave at `fixed`/`review` for the human/VM gate. Never claim a
    visual behavior is regression-guarded when only its model is tested.
  - Owner-gated items (dep approval, risky supervised refactor, a genuine product
    decision) → use **`task_park{kind,question,context}`** (pings the owner) rather
    than self-advancing; don't block the loop.
- **Discipline:** keep `main` headless-gate-green; **commit per item**; land via
  rebase + fast-forward (no merge bubbles). Re-verify with the CENTRAL gate on the
  **committed** commit, not a torn worktree:
  `bash scripts/test-headless-gate.sh` (Swift) / `bash scripts/rust-core-gate.sh`
  (rust-core). New deps need explicit owner approval.
- **Validation ladder:** (1) `swift build` compile; (2) targeted
  `swift test --filter …` for the changed logic; (3) host headless gate
  (window-free); (4) `bash scripts/build-app.sh debug --install` to push the
  fresh bundle to `/Applications/TextView.app` (the copy the owner launches) —
  this does NOT run a host UI test (the pre-install smoke is opt-in via
  `MDV_RUN_SMOKE_GATE=1`); it just builds + installs; (5) **UI / live-tier
  validation runs on the UTM VM, never the Mac** (owner directive) — `ssh
  macOS15` + `swift test` / `vm-smoke.sh`. **Do NOT run T4/T5/live-app UI tests
  on the host.**
- **Log every landed item** to `docs/AUTONOMOUS_PROGRESS.md` (the narrative that
  survives compaction) and advance the board task to `fixed` with the commit SHA.
- A perf-bench-only gate failure (e.g. `FoldBench`/`CrossFileSearchBench`
  wall-clock asserts) under machine load is flaky — re-run / confirm no
  non-bench failures before chasing it.

## Quick references

- `BACKLOG.md` — pending work, decisions, and audit follow-ups.
- `LESSONS.md` — institutional knowledge (compositor bug, perf wins,
  signing, VM screen-capture privacy notes).
- `MANUAL_TESTING.md` — checklist for features without automation.
- `DESIGN.md` — top-level architecture.
- `docs/` — feature design docs (Mermaid impl, Walkthrough v2, Code
  Review, Sessions, LSP, Plugins v2, etc.).
