# Test execution

## Current state

- Headless gate: `MDV_HEADLESS_GATE=1 swift test --parallel`, ~5,266 tests, **95 s** (includes
  a `swift build --build-tests` phase unless `SKIP_BUILD=1`).
- Test targets: ViewerCoreTests (295 files), ViewerUITests (279 files), ViewerKitTests (18),
  RustCoreTests (21). ~102 k LOC of tests, ~599 test classes total.
- Heavy tiers (T4 LiveAppTestCase / T5 PixelTestCase / WKWebView suites) self-skip on the host;
  they run only in the VM/nightly lane. So the 95 s is purely the headless tiers.
- 12 logical cores (8 P + 4 E).

## How `swift test --parallel` actually parallelizes (the key mechanic)

XCTest under SwiftPM parallelizes **process-per-test-CLASS**, not per-method, and **not
per-target**. SwiftPM spawns N `xctest` worker processes and distributes the *test classes*
across them. Consequences for this repo:

1. **Parallelism is bounded by class count and balance, not core count.** With ~599 classes
   across 12 cores there's plenty of width on average, **but the tail is set by the slowest
   individual class** — a single 1,000-LOC class (e.g. `PluginsAndMcpAutomationUATTests`,
   `DocumentModelTests` at 1.2k / 1.2k LOC) runs in one process and can't be split, so the whole
   `--parallel` run can't finish faster than its slowest class.
2. **Giant monolithic test classes are the enemy of `--parallel`.** The lever is **rebalancing
   the slowest classes** — splitting a heavy class into several smaller ones lets them schedule
   onto different workers. (Rec **T3**.)
3. **Splitting *targets* doesn't help parallelism directly** (parallelism is within the run
   across classes), but it *does* help **build** incrementality and lets you run a subset
   (`swift test --filter ViewerCoreTests`) for a fast inner loop.

## Recommendations

### T6 — MEASURE first (low effort, do before T3)
`swift test --parallel` prints no per-class timing by default. Capture it once:
`swift test --parallel --xunit-output /tmp/mdv-tests.xml` then sort the `<testcase time=…>`
entries. This tells you (a) build-phase vs test-phase split of the 95 s, and (b) the 10–20
classes that dominate the tail. Without this, T3 is guesswork. **Do this before investing in
T3.** (Owner directive: measure, don't guess.)

### T3 — Rebalance the slow test classes (after T6)
Once T6 names the tail, split the worst offenders into multiple `XCTestCase` subclasses so
`--parallel` can fan them across workers. Estimate 10–25% off the 95 s **if** the tail is
class-bound (T6 confirms). Pure mechanical refactor, low risk, but real work — file as a ticket.

### Worker count (probably already optimal — verify)
SwiftPM's `--parallel` worker count derives from core count. On 12 cores it should already spawn
~12 workers. No `--num-workers` knob is exposed by `swift test` (unlike `xcodebuild`'s
`-parallel-testing-worker-count`). Nothing to tune here unless T6 shows under-subscription.

### Subset/selective runs for the inner loop (already supported — document it)
`swift test --filter ViewerCoreTests.<Class>` is the fast inner-loop path (CLAUDE.md already
notes this). No change needed; just the standing guidance. The full `--parallel` gate stays the
merge gate.

### Swift Testing migration (NOT recommended now)
Swift Testing parallelizes **in-process** (one process, async tasks) which can be far faster
than XCTest's process-per-class model — but migrating ~599 XCTest classes / 102 k LOC is a
massive, risky, multi-week effort and orthogonal to the wins above. Record as a possible
long-horizon direction, not an action item.

## Build phase of the gate

The 95 s includes `swift build --build-tests`. Applying the SwiftPM gate-build wins from
`swiftpm.md` (Rec **F2** `--disable-index-store`, **F6** no-dSYM) trims this phase directly,
independent of test-execution tuning. Use `SKIP_BUILD=1` when iterating on the same compiled
bundle to isolate the test phase.

## Rust tests
See `rust.md` — `cargo-nextest` (T1) is the analogous process-parallel win for the 640 Rust
tests across 6 crate binaries.

## Sources
- https://forums.swift.org/t/make-swiftpm-run-xctest-and-testing-tests-in-parallel-by-default/78348
- https://github.com/apple/swift-package-manager/issues/5329
- https://tuist.dev/blog/2025/03/25/tests
- https://www.avanderlee.com/swift-testing/vapor-and-swift-testing-running-tests-in-parallel/
