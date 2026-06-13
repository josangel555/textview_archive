import XCTest
@testable import ViewerUI

/// TSK-817: the heavy-tier launch gate must NEVER let a bare host `swift test`
/// spawn `dist/TextView.app` just because a bundle happens to exist (that put a
/// window on the owner's screen mid-work). `LaunchHarness.shouldRunLiveTiers` is
/// the pure decision behind `isAppBuilt`; these pin it without ever spawning.
final class LaunchHarnessTierGateTests: XCTestCase {

    private func decide(_ env: [String: String], bundle: Bool) -> Bool {
        LaunchHarness.shouldRunLiveTiers(env: env, bundleExists: bundle)
    }

    func test_bareHostRun_withBundlePresent_doesNotRunLiveTiers() {
        // THE FOOTGUN (regression teeth): no opt-in env + a present dist/ bundle
        // (e.g. just after an /Applications build) must NOT run the live tiers.
        // Pre-fix this returned true → a T4 LiveAppTestCase spawned a window.
        XCTAssertFalse(decide([:], bundle: true),
                       "a bare host swift test must never spawn the app off a stray bundle")
    }

    func test_headlessGate_neverRunsLiveTiers_evenWithBundle() {
        XCTAssertFalse(decide(["MDV_HEADLESS_GATE": "1"], bundle: true),
                       "the headless gate is the headless lane by definition")
        // Gate wins even if the GUI opt-in is somehow also set.
        XCTAssertFalse(decide(["MDV_HEADLESS_GATE": "1", "MDV_VM_GUI_SESSION": "1"], bundle: true))
    }

    func test_vmGuiLane_withBundle_runsLiveTiers() {
        // The explicit opt-in test-in-vm.sh sets + forwards for the VM Aqua lane.
        XCTAssertTrue(decide(["MDV_VM_GUI_SESSION": "1"], bundle: true),
                      "the VM GUI lane (the intended place) still runs the heavy tiers")
    }

    func test_vmGuiLane_withoutBundle_doesNotRun() {
        XCTAssertFalse(decide(["MDV_VM_GUI_SESSION": "1"], bundle: false),
                       "no bundle ⇒ nothing to spawn")
    }
}
