import XCTest
@testable import ViewerCore

/// TSK-618 — the deterministic-chrome contract for harness spawns.
/// `MDV_PRISTINE_CHROME=1` must route chrome-state defaults through an
/// EMPTIED process suite: persisted pollution (open terminal, zoom,
/// dock sizes) is invisible, and the pristine instance's own writes
/// never reach the shared standard defaults.
final class PristineChromeTests: XCTestCase {

    override func tearDown() {
        unsetenv("MDV_PRISTINE_CHROME")
        super.tearDown()
    }

    func test_inactiveByDefault_returnsStandardDefaults() {
        unsetenv("MDV_PRISTINE_CHROME")
        XCTAssertFalse(PristineChrome.isActive)
        XCTAssertTrue(PristineChrome.launchDefaults() === UserDefaults.standard,
            "without the env, chrome state must keep using .standard")
    }

    func test_active_returnsEmptiedSuite_thatHidesPollution() {
        // Pollute the pristine suite directly (simulating a prior pristine
        // launch's writes) — activation must wipe it.
        let polluted = UserDefaults(suiteName: PristineChrome.suiteName)!
        polluted.set(true, forKey: "MarkdownViewer.terminalPane.isOpen")
        polluted.set(320.0, forKey: "MarkdownViewer.terminalPane.height")

        setenv("MDV_PRISTINE_CHROME", "1", 1)
        XCTAssertTrue(PristineChrome.isActive)
        let fresh = PristineChrome.launchDefaults()
        XCTAssertFalse(fresh === UserDefaults.standard,
            "pristine mode must NOT hand back the shared standard defaults")
        XCTAssertNil(fresh.object(forKey: "MarkdownViewer.terminalPane.isOpen"),
            "the pristine suite must be EMPTIED at launch — prior pollution visible")
        XCTAssertNil(fresh.object(forKey: "MarkdownViewer.terminalPane.height"))
    }

    func test_pristineWrites_neverReachStandardDefaults() {
        setenv("MDV_PRISTINE_CHROME", "1", 1)
        let key = "mdv.test.pristine-isolation-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let pristine = PristineChrome.launchDefaults()
        pristine.set("leaked?", forKey: key)
        XCTAssertNil(UserDefaults.standard.string(forKey: key),
            "a pristine instance's chrome writes must not pollute .standard")
        // Clean the suite artifact.
        pristine.removePersistentDomain(forName: PristineChrome.suiteName)
    }
}
