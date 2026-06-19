import XCTest
@testable import ViewerCore

/// TSK-711 — feature gate for the in-progress editable-CSV grid. Default OFF;
/// env override beats the persisted toggle; an explicit persisted toggle beats
/// the default. Pure + host-safe.
final class CSVEditingGateTests: XCTestCase {

    /// An isolated UserDefaults suite so the test never touches the real prefs.
    private func freshDefaults() -> UserDefaults {
        let name = "CSVEditingGateTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_default_isOff() {
        let d = freshDefaults()
        XCTAssertFalse(CSVEditingGate.isEnabled(defaults: d, environment: [:]),
                       "editable CSV ships OFF until the epic completes")
    }

    func test_envOverride_forcesOn() {
        let d = freshDefaults()
        XCTAssertTrue(CSVEditingGate.isEnabled(defaults: d, environment: ["MDV_CSV_EDIT": "1"]))
        XCTAssertTrue(CSVEditingGate.isEnabled(defaults: d, environment: ["MDV_CSV_EDIT": "true"]))
    }

    func test_envZero_forcesOff_evenIfToggleOn() {
        let d = freshDefaults()
        d.set(true, forKey: CSVEditingGate.defaultsKey)   // persisted ON
        XCTAssertFalse(CSVEditingGate.isEnabled(defaults: d, environment: ["MDV_CSV_EDIT": "0"]),
                       "an env 0 pins it OFF, overriding the persisted toggle")
    }

    func test_persistedToggle_beatsDefault() {
        let d = freshDefaults()
        d.set(true, forKey: CSVEditingGate.defaultsKey)
        XCTAssertTrue(CSVEditingGate.isEnabled(defaults: d, environment: [:]))

        d.set(false, forKey: CSVEditingGate.defaultsKey)
        XCTAssertFalse(CSVEditingGate.isEnabled(defaults: d, environment: [:]))
    }
}
