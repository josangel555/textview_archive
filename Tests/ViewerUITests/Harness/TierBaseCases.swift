import XCTest
import Foundation

/// Per-tier base classes (§3.3.1, §4) — *tier is the type*.
///
/// The testing-pyramid audit found the recurring over-placement root
/// cause (§4.5): tier was never a first-class, machine-checkable
/// property — only target + filename + an ad-hoc env gate — so nothing
/// *stopped* a test from sitting too high. These three base classes make
/// tier explicit in the type hierarchy and bake in the guardrail (§4):
///
/// > A test may sit at tier N+1 only if it asserts on an observable that
/// > tier N cannot faithfully produce. The PR must name that observable.
///
/// The default is HEADLESS; you must *opt up*. A subclass of a heavy base
/// (`LiveAppTestCase` / `PixelTestCase`) is required to carry a one-line
///
///     // TIER-JUSTIFY: <the ④ / cross-process / OS-integration observable
///     //               that forces this tier>
///
/// comment naming the observable that forces it. That comment is the
/// reviewable artifact the guardrail asks for; a heavy test without one
/// is a code-review smell.
///
/// Tier ladder (SwiftUI/AppKit; see TESTING_STRATEGY.md §1.1):
///
///   ┌──────────────────────────────────────────────────────────────┐
///   │ HeadlessUITestCase   T1 / T1m / T2'  host, no window, no perm  │  ← default
///   │ LiveAppTestCase      T4              spawns dist/TextView.app  │  ← opt up
///   │ PixelTestCase        T5              WindowServer pixels (VM)  │  ← opt up
///   └──────────────────────────────────────────────────────────────┘
///
/// CI gating (WIRED — see `.github/workflows/pr.yml`): the merge gate runs
/// the bare `swift test --parallel` sweep on a host with no `dist/` bundle
/// and no GUI session, so `HeadlessUITestCase` descendants run while
/// `LiveAppTestCase` (T4) / `PixelTestCase` (T5) descendants self-skip
/// (`LaunchHarness.isAppBuilt == false`, no Screen-Recording). The in-process
/// live-WKWebView suites that `#192`-gate themselves on `MDV_RUN_WEBVIEW_TESTS`
/// are NOT run by the merge gate — `pr.yml` does not set that env, so they
/// self-skip there too (TSK-1133: corrected — the gate does not run the WebView
/// lane). Both the WebView lane AND the heavy T4/T5 tiers run for real only in
/// the separate VM / nightly lane (`scripts/test-in-vm.sh`).
///
/// The "headless" property is made non-regressable by `TierGateObserver`
/// (the class-membership query this design called for): when the gate sets
/// `MDV_HEADLESS_GATE=1`, the observer fails the run if any `LiveAppTestCase`
/// / `PixelTestCase` subclass *runs its body* instead of skipping. So a
/// heavy test that loses its `isAppBuilt` / screencapture guard — or is
/// mis-filed under the wrong base — turns the gate red instead of silently
/// drifting off-headless. Tier is the type, and the type is enforced.

// MARK: - T1 / T1m / T2' — the default, headless tier

/// Default base for app/UI-tier tests. Runs entirely in the host test
/// process: no spawned `.app`, no real `NSWindow`, no Screen-Recording
/// permission. Covers the three headless tiers from §1.1:
///
///   - **T1**  pure value / logic (plain XCTest assertions).
///   - **T1m** `@MainActor` model / coordinator — construct a hermetic
///     `DocumentModel` (the DI seam) or drive verbs via `HeadlessHarness`
///     and assert on `model.*` scalars. THE leverage tier (~20% of
///     regressions; catches the republish-storm / leak classes that
///     "drive the app and look at it" is structurally blind to).
///   - **T2'** in-process `NSHostingView` walk — `host.layoutSubtreeI
///     fNeeded()` + `DiagnosticDump`, asserting realized-tree shape /
///     geometry only.
///
/// `@MainActor` because `DocumentModel` / `SessionsAppCoordinator` and
/// any `NSHostingView` work are main-actor-isolated. No `// TIER-JUSTIFY:`
/// required — this is the floor.
@MainActor
class HeadlessUITestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Arm the headless-gate enforcement observer. Registering from the
        // *floor* tier — which always runs in the gate — guarantees the
        // observer is live before any heavy-tier test could start, no matter
        // the alphabetical class order. Idempotent + process-global.
        TierGateObserver.register()
    }
}

// MARK: - T4 — real .app, spawned process

/// Base for tests that genuinely need a REAL process boundary: they spawn
/// `dist/TextView.app` via `--script` and read its dump back. Reserve for
/// the irreducible T4 residue (§3.4): the AppDelegate↔coordinator launch
/// wiring that only exists in a real process, real-`NSWindow` geometry
/// clamping, cross-*process* `PreferencesStore` persistence across a
/// relaunch. VM-coupled (Xcode + GUI session); not part of the
/// host-headless merge gate.
///
/// **A subclass MUST carry a `// TIER-JUSTIFY:` comment** naming the
/// cross-process / OS observable that forces T4 over T1m. If the
/// assertions only read `model.*` scalars, it's a T1m test wearing a T4
/// costume — demote it to `HeadlessUITestCase`.
///
/// Not `@MainActor`: the live suites drive an out-of-process app and
/// manage their own isolation (process spawn, file polling). Forcing
/// main-actor isolation on the base would be invasive for no benefit.
class LiveAppTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Belt-and-suspenders: also arm enforcement from the heavy bases, in
        // case a future invocation runs a heavy suite in isolation (its own
        // `--filter`) without any `HeadlessUITestCase` having registered first.
        TierGateObserver.register()
    }
}

// MARK: - WebView lane — in-process live WKWebView suites (#192)

/// Base for the in-process live-`WKWebView` suites (component snapshots, hosting
/// probes, Mermaid realization, rendered find bar, gutter/editor WebView probes, …).
/// They realize a real `WKWebView` in the host process, so they `#192`-gate on
/// `MDV_RUN_WEBVIEW_TESTS` (the VM/nightly WebView lane) via
/// `WebViewTestTeardown.skipUnlessEnabled()` in their own `setUp`, self-skipping in
/// the headless gate. Making the tier a TYPE — not just a per-suite skip — lets
/// `TierGateObserver` ENFORCE it: if a suite's manual gate ever regresses and a body
/// runs in the headless gate, the observer flags it, the same machine-checkable
/// guarantee the T4/T5 bases carry (TSK-1132, per the TSK-788 audit). Like the other
/// heavy bases, this only arms the observer; the suites keep their own skip + teardown.
class WebViewTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        TierGateObserver.register()
    }
}

// MARK: - T5 — WindowServer pixels (the real screen)

/// Base for the single irreducibly-real-screen tier: tests that read the
/// user's actual composited pixels via `screencapture(1)` against a live
/// window. The only observable here is stage ④ (WindowServer composite,
/// §1.1) — out-of-process, no headless equivalent, requires a real GUI
/// login session (the VM) and TCC Screen-Recording grant.
///
/// Today this guards exactly ONE bug class
/// (`NSRulerView`-in-`tile()`-in-SwiftUI-commit sibling-blank
/// compositing; see `SourceViewVisualRegressionTests`). A T2-px /
/// `cacheDisplay` raster would render the strips correctly while the live
/// window is blank — a FALSE green — which is precisely why this can't be
/// demoted.
///
/// **A subclass MUST carry a `// TIER-JUSTIFY:` comment** naming the
/// ④-compositor observable that forces a real screen. The structural
/// prohibition ("never attach `NSRulerView` / subclass `NSLayoutManager`
/// in the source view", LESSONS.md) is the primary defense; T5 is
/// belt-and-suspenders.
///
/// Not `@MainActor`: same reasoning as `LiveAppTestCase` — it spawns the
/// app and drives `screencapture(1)` out-of-process.
class PixelTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        TierGateObserver.register()
    }

    /// TSK-822: the T5 pixel tier (AppleScript-driven app spawn + `screencapture`)
    /// can ONLY function inside the explicit VM GUI lane — `launchctl asuser`
    /// gives the spawned app a WindowServer + Screen-Recording + Automation
    /// context. Gate the WHOLE tier on the same tested decision `LaunchHarness`
    /// uses for the live tiers (TSK-817), so a subclass self-skips everywhere it
    /// can't actually capture: the host merge gate, a bare host `swift test`
    /// (which would otherwise OPEN A WINDOW on the owner's screen — the footgun
    /// these per-test `MDV_HEADLESS_GATE`-only guards left open), AND a non-GUI
    /// `test-in-vm.sh test` over ssh (where the capture false-fails with
    /// AppleScript `-609` / a blank shot — the symptom that surfaced this).
    /// Only `MDV_VM_GUI_SESSION=1` (the GUI lane) runs them.
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard LaunchHarness.shouldRunLiveTiers(
            env: ProcessInfo.processInfo.environment, bundleExists: true) else {
            throw XCTSkip("T5 pixel tier — requires the explicit VM GUI lane (MDV_VM_GUI_SESSION=1).")
        }
    }
}
