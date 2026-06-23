# TextView / MarkdownViewer — Claude instructions

## Testing rules

### ⛔ NEVER report a render/on-screen bug "fixed" without confirming on the REAL UI (OWNER DIRECTIVE 2026-06-20)

The owner has been burned repeatedly: an agent reports a bug fixed, but on screen
it behaves the same broken way. **A host-green / model-green result is NOT a fix
for on-screen behavior — it is "model fixed, on-screen UNVERIFIED" at most.**

This is **T6** — agent-driven journey UAT, the tier above T5 (T1/T1m/T2' headless ·
T4 LiveApp · T5 Pixel · **T6 agent-driven journey UAT**, run via the `run-uat`
skill, NOT `swift test`). Two modes (do NOT conflate them):
- **PARTIAL T6 — mandatory for EVERY render-path change.** Before claiming any
  on-screen behavior is fixed (to the owner OR via `task_validate`), CONFIRM YOUR
  OWN CHANGE WITH YOUR OWN EYES on the real UI — the SCOPED slice that exercises
  exactly what you changed (not the whole suite). Mechanism: drive the relevant
  steps via the agent UI-automation path (`mac-computer-use` MCP when it ships;
  until then the VM GUI lane + `screencapture` and Read the PNG — see
  `.claude/skills/run-uat` / `vm-ui-testing`). You looked at it and it actually
  behaves correctly = the bar.
- **FULL T6 — the whole journey suite; OWNER-REQUESTED, major releases only.**
  A comprehensive regression + completeness sweep across the app
  (`docs/research/agent-uat-framework-2026-06-20/`). NOT run per-change — too
  expensive; the owner triggers it for releases.
- If you cannot do even the partial on-screen confirmation, report
  **"model-fixed, on-screen UNVERIFIED — needs UAT/owner"** and leave at `review`.
  NEVER say "fixed" / move to `done` on model evidence alone. The acceptance
  criterion for a UI bug is the pixels/behavior the user sees.

### Root-cause discipline — DIAGNOSE before you fix (OWNER DIRECTIVE 2026-06-23)

Before implementing ANY bug fix, answer these — explicitly, in the ticket:
1. **Is this a CLASS of bugs?** Does the same pattern live elsewhere? `grep` for siblings and
   fix the class, not the one instance. (The session-switch scroll reset, the footer-stats
   blank-on-switch (TSK-1120), and "loading…" flashes are the SAME class: imperative state
   populated AROUND a switch, raced by the declarative render that reads it.)
2. **What is the MECHANISM — sync sequencing, async timing, or a data bug?** Is the value
   never CAPTURED, never SERIALIZED, never RESTORED, or restored-but-mis-TIMED vs the render?
   Don't patch the RESTORE side when the root is CAPTURE/serialize, and don't patch one stage
   of a multi-handoff async chain — the bug just moves to the next stage (this is *why* a bug
   "keeps coming back" after each "fix").
3. **VERIFY the mechanism end-to-end — do NOT infer from code order.** SwiftUI body re-eval is
   async/coalesced; an `@Published` mutation does not re-render synchronously. "restoreScroll
   runs after select(), so it's too late" is WRONG without proving the render actually reads
   before the seed. For timing bugs, INSTRUMENT / observe at runtime.
4. **Prefer collapsing the fragile chain over adding a stage-patch.** A single source of truth
   (e.g. scroll lives on the Tab, the view reads it declaratively) removes the race by
   construction; another imperative seed just adds one more handoff to drop at.
5. **Render/timing bugs you cannot observe host-only: do NOT claim "fixed" on static
   inference** — build to the VM / `/Applications` and confirm on-screen first (ties to the
   render-confirm directive above).

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
  - **Codified negative-control switch (TSK-1134):** instead of hand-reverting,
    gate a *deliberate* break behind `MDVNegativeControl.isBroken("<NAME>")`
    (reads `MDV_ENABLE_BROKEN_<NAME>=1`) and have the T5 test spawn the app with
    that env set to assert the guard goes RED — a repeatable, committed teeth
    proof. Use that one helper for every such switch (consistent, greppable key).
    First instance: `MDV_ENABLE_BROKEN_RULER` (TextDisplayView ↔
    SourceViewVisualRegressionTests).

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
are heavy and VM-coupled. **The heavy tiers run ONLY under the explicit VM GUI
lane (`MDV_VM_GUI_SESSION=1`, which `test-in-vm.sh` sets + forwards); otherwise
they self-skip — regardless of whether a `dist/` bundle exists** (TSK-817). This
closed a footgun: a bare `swift test` on a host that merely had a built bundle
(e.g. just after an `/Applications` build) used to run a T4 `LiveAppTestCase`
and **spawn a window on the owner's screen mid-work**. So the bare `swift test`
sweep runs to completion on the host (exercises the headless tiers, skips T4/T5)
even with a bundle present. Still: prefer the gate (below) or
`--filter ViewerCoreTests.<...>` (pure logic, no heavy tiers) for host loops;
NEVER a bare/broad `--filter ViewerUITests` if you're unsure (it's safe now, but
ViewerCoreTests is the unambiguous host-safe target).

- **Test framework — Swift Testing (hybrid) for NEW pure-logic; XCTest for the
  rest (TSK-787/1130).** New PURE-LOGIC suites MAY use Swift Testing
  (`import Testing`, `@Test`/`#expect`, `@Test(arguments:)` for parameterized
  cases — prefer it there over XCTest's repetition). KEEP XCTest for: anything
  tier-based (the `TierBaseCases` hierarchy + `TierGateObserver` are XCTest), the
  VM/live tiers, and existing suites (don't churn-convert). Both frameworks run
  together under one `swift test` (pilot: `Tests/ViewerCoreTests/SwiftTestingPilotTests.swift`).

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
  - **RENDER/UAT validation MUST use `all`, not `test` — `test` spawns a STALE
    `dist/` (2026-06-15 stale-dist trap, LESSONS.md).** The rsync excludes
    `dist/` and `test` mode never rebuilds it, so T4 `LiveAppTestCase`/`*UATTests`/
    T5 spawn whatever `dist/TextView.app` was last built on the VM (can be a MONTH
    stale → false "regression" failures, e.g. a fake editor-save-data-loss alarm).
    For live-app/pixel validation run `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>
    MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all` (`all` = `build_all`
    rebuilds `dist/` first). Before trusting any UAT failure, verify freshness:
    `stat -f "%Sm" dist/TextView.app/Contents/MacOS/MarkdownViewer` vs `git log -1`.
    Capture FULL output (NOT `… | tail`) — JUnit says only "see swift test output".
  - GUI/pixel lane (T4/T5): `MDV_VM_GUI_SESSION=1 bash scripts/test-in-vm.sh …`
    REQUIRES `MDV_VM_SUDO_PASS=<vm-sudo-password>` — without it the sudo wrapper silently
    runs NOTHING ("a password is required" buried in the log). Note the
    `launchctl asuser` bridge runs xctest + spawned apps as ROOT, so windowid/
    temp artifacts land in root's `/var/folders/zz/...`. (`test-in-vm.sh`
    raises `ulimit -n 8192` itself — TSK-500 fixed the fd-exhaustion false
    failures.)
  - The VM has **no Rust toolchain**: it links the host-built
    `rust-core/link/libmdvcore_ffi.a` (build it on the host first if Rust
    changed; the rsync ships it since `rust-core/` isn't excluded). Never
    `cargo build` on the VM.
  - The VM has no git remote — it's an rsync mirror. Do not
    `git pull` on the VM.
- **VM credentials**: host `macOS15`, user `vm-tester@<vm-ip>`,
  sudo password `<vm-sudo-password>`. Safe to `sudo -S` over ssh.

## Project-specific

- **SwiftPM staleness traps (TSK-626 family): after changing the staged C
  header OR any cross-module public type's LAYOUT (e.g. adding a case to
  `RustCore.CoreError`), `touch` every file that references it — INCLUDING
  the Tests/ targets' files** — before trusting test results. Stale test
  objects against a re-laid-out enum SIGSEGV (signal 11) in ways that look
  exactly like FFI/unwinding bugs (live case 2026-06-12: a pure-Swift
  `throw CoreError.panic` segfaulted). Suspect staleness BEFORE the boundary.
- Bundle id stays `com.markdownviewer.MarkdownViewer` (TCC-stable).
- Local signing only (cert `MarkdownViewer Local Dev`); no Developer
  ID until shipping public.
- Bundle size cap: 80 MB total + 65 MB main-executable sub-cap
  (`scripts/check-bundle-size.sh` defaults; override via `BUDGET_MB` /
  `EXEC_BUDGET_MB`), wired into `scripts/build-app.sh`. The two caps are
  tracked separately because grammar parsers can live as
  `Contents/Frameworks/` dylibs OR static-linked in the exec, and the
  exec sub-cap catches a silent regression to static-linking. The exec
  cap grew 26→44→52→60→65 (owner-approved TSK-660 rust-grammar landings + a
  2026-06-14 headroom ask + a 2026-06-22 owner bump to 65 — release exec hit
  60.4 MB organically, no static-link regression); most of the ~60 MB exec is double-carried
  tree-sitter grammar parse tables, so REDUCING the cap (lazy-load /
  dedup) is the real reclaim — tracked by TSK-1214/TSK-1098, an owner
  call on the target budget. (The older "48/26" and "25 MB" figures
  predated those bumps.)
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
- **Check `mcp__tasked__task_list` before creating** to avoid duplicates;
  **read the latest with `mcp__tasked__task_get` before updating** (staleness).
  (These are the BOARD tools — not the built-in Claude Code TaskList, whose
  `#NNN` numbering is a different system from board `TSK-NNN`.)
- **Before validating/closing any `fixed` board ticket, match its recorded
  `understanding`/transition reasons against the board TITLE.** The #NNN trap has
  produced mislabeled-as-fixed tickets (work for a different finding recorded on a
  same-numbered board id — TSK-326/276/279 confirmed 2026-06-10). A topic mismatch
  ⇒ `task_record {to: progress}` with a correction note, never validate.
- This complements the durable docs (`AUTONOMOUS_PROGRESS.md` for the autonomous
  run log, `BACKLOG.md` for the standing queue) — the task board is the live
  per-item state; the docs are the narrative that survives compaction.

## Automated / autonomous runs (SOP)

Standing operating procedure for autonomous/heartbeat runs (the screen is the
agent's until the owner says stop; work in waves, don't stop to ask "should I
continue", document blockers and move on):

> **TWO HARD RULES FOR EVERY CRON / AUTOMATED FIRING (owner directive
> 2026-06-20) — these override anything below that conflicts:**
> 1. **Work INLINE — do NOT use the Workflow tool or any multi-agent fan-out.**
>    The main loop does the work DIRECTLY, ONE item at a time (spike → implement
>    → test → gate → commit). Workflows spin dozens of agents and burn tokens (a
>    120-agent reconcile cost ~6M); the cron run is deliberately lean + inline.
>    Fan-out / `Workflow` is ONLY for owner-triggered "ultracode" sessions.
> 2. **NEVER stop with "there is no more work."** There is ALWAYS plenty. If the
>    actionable queue looks empty, PULL FROM THE BOARD: validate `fixed` items
>    (with teeth), push `review`, triage `reported`, fix bugs, re-verify — drain
>    toward `done`. A "no work" stop is a PROCESS FAILURE, not a valid state.

- **Each firing: read `docs/TASK_WORKFLOW.md` IN FULL and follow it** — it is
  the single operating procedure (lane goals, prioritization, lifecycle,
  validation policy) and the authoritative copy where this summary drifts.
  If substantive work is already in flight this turn, treat the nudge as a
  no-op. A fresh/compacted session reads `HANDOFF.md` (repo root) first.
- **Pick work from the `tasked` board** (`http://localhost:8787/mcp` —
  the SYSTEM OF RECORD, NOT the built-in Claude Code TaskList). Drive it ONLY
  via the **`mcp__tasked__*` MCP tools** (agent `claude-mdv`; ids `TSK-###`);
  the old `python3 /tmp/board.py` helper and the human REST endpoint are
  RETIRED — never recreate or spoof them. The board is **shared across
  projects** — grep this repo before acting on a task; skip foreign
  `agent:forge`/`sess-forge-*` tasks.
- **PRIORITY: DRAIN `BACKLOG.md` top-down — the SINGLE curated worklist**
  (owner directive 2026-06-22: ONE backlog = the curated "what to work on" list;
  everything else lives on the board; stale tracking docs are archived). The dated
  `docs/CURATED_TASKS_*.md` + `WORK_QUEUE.md` were folded into `BACKLOG.md` and
  archived under `archive/tracking-2026-06-22/`. `BACKLOG.md` is owner-curated and
  priority-ordered (P0 user-facing bugs/perf → P1 user-facing features → P2
  internal/rust-core/test). Each firing: pick the next actionable item, drive its
  `TSK-###` on the board to at least `review`/`validated`. The board (`tasked`) is
  the SYSTEM OF RECORD for task STATE — advance items THERE; do NOT check items off
  in a file. USER-FACING value wins ties. When an item is owner-blocked, `task_park`
  it + take the next. When `BACKLOG.md` is fully drained, fall back to the board's
  groomed pools (security/rust-core/parity/theming), then the `fixed`-lane validation
  drain. DON'T ship a risky blind change; if it needs the screen/owner, file it and move on.
- **Spike + design are AUTO-APPROVED (owner directive 2026-06-13; full text
  TASK_WORKFLOW §0.5).** For any non-trivial ticket the agent runs the spike
  (scope/what-exists/feasibility/options) AND produces the design + breakdown
  AUTONOMOUSLY, then implements — never `task_park` just because something
  "needs design / a decision about approach". Re-surface to the owner ONLY (and
  only after a spike frames it) for: a genuine **dependency approval**, a **true
  undifferentiated ambiguity** (can't tell WHAT is asked), or a hard **blocker**.
  Chipping order: regressions → bug fixes → minor-features (no design) → epics
  (spike→design→breakdown→ship in slices) → very-large (file-and-forget).
- **Migration policy (owner directive 2026-06-11, full text TASK_WORKFLOW §2.5):
  Swift engines with an approved Rust port take USER-FACING BUGFIXES ONLY** —
  no perf work, refactors, features, or test backfill on the Swift twin
  (find TSK-630, markdown TSK-631, transcript parse TSK-632, fuzzy TSK-633;
  CSV/diff/hex already ported). Matching audit findings get re-tagged
  `port-superseded`, fixed once in Rust. Engine ports + the Phase 1 contract
  work (windowed snapshot, error v2, envelope, TSK-634 FFI codegen) rank ABOVE
  Swift internal-quality work. New Rust deps land `default-features = false`
  with an explicit minimal feature list (owner rider, TSK-629).
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
- **Commit hygiene — NO process-noise commits (owner directive 2026-06-22).** Do
  NOT make standalone doc-churn commits. FOLD the `LESSONS.md` / `HANDOFF.md` /
  `AUTONOMOUS_PROGRESS.md` / `CHANGELOG.md` updates for an item INTO that item's CODE
  commit, when possible. Commit a doc on its own only when it genuinely stands alone
  (a fresh design doc; the periodic handoff at a real session checkpoint). A day must
  NOT carry 30+ separate doc commits — combine docs with the code change they describe.
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
  survives compaction) and advance the board task to `fixed` with the commit SHA —
  but FOLD that log line INTO the item's code commit (per Commit hygiene above), not
  a separate doc commit.
- **Keep `CHANGELOG.md` current (OWNER ASK 2026-06-13; expanded 2026-06-22).** It is
  the **OWNER's** at-a-glance view of TOTAL effort — not only end-user-visible change.
  Two parts per date:
  - **User-facing** — `Added` / `Changed` / `Fixed` / `Performance`: descriptive,
    one plain-language line each, from the USER's seat (a feature/fix/perf the owner
    can SEE or FEEL).
  - **`### System work`** — a TERSE INFORMATIONAL roll-up (a few bullets, per AREA:
    tests, CI/infra, refactors, gated rust-core ports, tracking) of the
    NON-user-facing effort, so the owner can see where a day's commits actually went
    (a "147 commits, 3 user-facing" day shows the other ~144's shape here). Summarize
    the INFORMATION — what was done, per area — NOT per-commit detail, NOT
    feature-descriptive prose, NOT a literal table.
  Detailed per-item narrative still lives in `AUTONOMOUS_PROGRESS.md`. If a tick lands
  nothing at all, leave it untouched.
- A perf-bench-only gate failure (e.g. `FoldBench`/`CrossFileSearchBench`
  wall-clock asserts) under machine load is flaky — re-run / confirm no
  non-bench failures before chasing it.

## Quick references

- `docs/TASK_WORKFLOW.md` — THE autonomous-loop SOP (lane goals,
  prioritization, lifecycle, validation policy); read every firing.
- `BACKLOG.md` — pending work, decisions, and audit follow-ups.
- `LESSONS.md` — institutional knowledge (compositor bug, perf wins,
  signing, VM screen-capture privacy notes, SwiftPM staleness traps).
- `docs/PERFORMANCE_PROFILING.md` + `scripts/vm-profile.sh` — perf
  measurement harness (PerfSignpost / xctrace). MEASURE, don't guess
  (owner directive 2026-06-10): `--instrument 'os_signpost'` is
  load-bearing; UI-opening captures run on the UTM VM via the script
  (modes open|resize, configs release|debug — debug for symbolicated
  stacks).
- `MANUAL_TESTING.md` — checklist for features without automation.
- `DESIGN.md` — top-level architecture.
- `docs/TRACKER_FEEDBACK.md` — feedback queue for the `tasked` tool itself
  (file new items as INT-### tickets in the `internal` project).
- `docs/research/rust-core-audit-2026-06-09/` — the rust-core production
  audit (synthesis.md = verdict + Phase 0-3 roadmap; epic TSK-538).
- `docs/` — feature design docs (Mermaid impl, Walkthrough v2, Code
  Review, Sessions, LSP, Plugins v2, etc.).
