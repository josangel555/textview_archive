import ApplicationServices
import XCTest
import Foundation
import ViewerCore
import ViewerUI

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
// MARK: - AX — out-of-process real-interaction (the TSK-1254 apex tier)

/// Base for the native-AX interaction tier (owner policy 2026-07-29: AX
/// tests for new UI work; bootstrapped 2026-07-31). Tests spawn
/// `dist/TextView.app`, attach OUT-OF-PROCESS via
/// `AXUIElementNode.application(pid:)`, locate elements by their `mdv.*`
/// accessibility identifier through the host-tested `AXDriverCore`, and
/// perform REAL actions (`kAXPressAction`) — the only substrate where
/// SwiftUI materializes an AX tree at all (the in-process tree is empty,
/// proven 2026-07-04; System Events can't see SwiftUI identifiers).
///
/// **A subclass MUST carry a `// TIER-JUSTIFY:` comment** naming the
/// real-event / out-of-process observable that forces this tier — if the
/// assertion could read `model.*` after calling the action closure, it's
/// a T1m test wearing an AX costume.
///
/// Runs ONLY in the explicit VM GUI lane (`MDV_VM_GUI_SESSION=1`, same
/// gate as T5 — spawning would open a window on the owner's screen
/// anywhere else) AND when the runner holds the Accessibility TCC grant.
/// On the VM both ssh paths are trusted (`sshd-keygen-wrapper` +
/// `Terminal` carry `kTCCServiceAccessibility` auth); a missing grant
/// self-skips with the fix spelled out rather than false-failing.
class AXInteractionTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        TierGateObserver.register()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard LaunchHarness.shouldRunLiveTiers(
            env: ProcessInfo.processInfo.environment, bundleExists: true) else {
            throw XCTSkip("AX tier — requires the explicit VM GUI lane (MDV_VM_GUI_SESSION=1).")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("""
                AX tier — the test runner lacks the Accessibility TCC grant. \
                On the VM: System Settings → Privacy & Security → Accessibility \
                → enable the spawning context (Terminal / sshd), or add the \
                runner to /Library/Application Support/com.apple.TCC/TCC.db \
                (kTCCServiceAccessibility) via the ssh+sudo path.
                """)
        }
    }

    // MARK: shared spawn rig (ONE home for the fixed spawn waits — the
    // sleep-ratchet counts source lines, so per-suite copies tax it)

    private static let appExe: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // (file) → Harness/
            .deletingLastPathComponent()   // → ViewerUITests/
            .deletingLastPathComponent()   // → Tests/
            .deletingLastPathComponent()   // → repo root
        return here.appendingPathComponent(
            "dist/TextView.app/Contents/MacOS/MarkdownViewer").path
    }()

    private static let windowIDFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.markdownviewer.MarkdownViewer.windowid")

    /// The spawned app under test; reaped in tearDown.
    private(set) var app: Process?

    override func tearDown() {
        if let p = app, p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        app = nil
        super.tearDown()
    }

    /// Spawn `dist/TextView.app` into `scene` (isolated session store,
    /// test-instance tagged), activate it (SwiftUI event routing needs a
    /// foreground app), and return its out-of-process AX root.
    func spawnAndAttach(scene: String) throws -> AXUIElementNode {
        guard FileManager.default.isExecutableFile(atPath: Self.appExe) else {
            throw XCTSkip("App not built at dist/ — run the VM `pixel`/`all` lane.")
        }
        try? FileManager.default.removeItem(at: Self.windowIDFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.appExe)
        var env = ProcessInfo.processInfo.environment
        env["MDV_UI_SCENE"] = scene
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-ax-sessions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        env["MDV_SESSIONS_DIR"] = sessionsDir.path
        p.environment = env
        try p.run()
        app = p

        let deadline = Date().addingTimeInterval(12)
        var sawWindow = false
        while Date() < deadline {
            if let data = try? Data(contentsOf: Self.windowIDFile),
               let s = String(data: data, encoding: .utf8),
               Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0 {
                sawWindow = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard sawWindow else {
            throw XCTSkip("no window id published — app failed to launch a window")
        }
        // Activation can transiently fail (-609 "Connection is invalid")
        // when a PREVIOUS test's same-named instance is still unwinding in
        // WindowServer — retry briefly instead of proceeding backgrounded
        // (clicks need the window frontmost).
        for attempt in 0..<5 {
            let activate = Process()
            activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            activate.arguments = ["-e", "tell application \"MarkdownViewer\" to activate"]
            try? activate.run()
            activate.waitUntilExit()
            if activate.terminationStatus == 0 { break }
            Thread.sleep(forTimeInterval: 0.5 + Double(attempt) * 0.5)
        }
        Thread.sleep(forTimeInterval: 2.0)   // scene apply + first paint settle
        return AXUIElementNode.application(pid: p.processIdentifier)
    }

    /// Poll `condition` until it holds or `timeout` passes — condition-
    /// polling; the sleep is the sampling interval.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return condition()
    }
}

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
