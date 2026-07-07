import XCTest

import ViewerCore

/// Tests for the feature-flag mechanism (`RustCSVGate`) and the routing
/// adapter (`RustCSVAdapter`). These nail down the SHIPPING-SAFE contract:
/// default OFF = Swift path, and both opt-ins (env var, UserDefaults) flip it
/// ON. Headless / pure-logic, host-safe.
final class GateAndAdapterTests: XCTestCase {

    /// A throwaway UserDefaults suite so we never touch the real prefs DB.
    private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Gate default & opt-ins

    func testGateShippedDefaultIsOn_soakSet() {
        let d = scratchDefaults()
        // TSK-649 stage A: csv is in the soak set — no env override, no
        // persisted toggle → the shipped default is ON. (Explicit toggles
        // and MDV_RUST_CSV=0 still pin Swift — pinned elsewhere.)
        XCTAssertTrue(RustCSVGate.isEnabled(defaults: d, environment: [:]))
    }

    func testGateEnvVarForcesOn() {
        let d = scratchDefaults()
        XCTAssertTrue(RustCSVGate.isEnabled(defaults: d, environment: ["MDV_RUST_CSV": "1"]))
        XCTAssertTrue(RustCSVGate.isEnabled(defaults: d, environment: ["MDV_RUST_CSV": "true"]))
    }

    func testGateEnvVarZeroForcesOffEvenWithToggleOn() {
        let d = scratchDefaults()
        d.set(true, forKey: RustCSVGate.defaultsKey)
        // Env "0" is an explicit override that pins the Swift A-side.
        XCTAssertFalse(RustCSVGate.isEnabled(defaults: d, environment: ["MDV_RUST_CSV": "0"]))
    }

    func testGatePersistedToggleEnables() {
        let d = scratchDefaults()
        d.set(true, forKey: RustCSVGate.defaultsKey)
        XCTAssertTrue(RustCSVGate.isEnabled(defaults: d, environment: [:]))
        d.set(false, forKey: RustCSVGate.defaultsKey)
        XCTAssertFalse(RustCSVGate.isEnabled(defaults: d, environment: [:]))
    }

    // MARK: - Adapter routing

    func testAdapterParseAlwaysReturnsValidResult() {
        // Stage-B: rust is the only engine; pin the parsed content directly.
        let input = "a,b\n1,2\n3,4\n"
        let result = RustCSVAdapter.parse(input)
        XCTAssertEqual(result.header, ["a", "b"])
        XCTAssertEqual(result.rows, [["1", "2"], ["3", "4"]])
    }

    func testAdapterRustParseMappingIsFaithful() throws {
        // Direct exercise of the rust path — proves the Table →
        // CSVParser.Result mapping (delimiter Character, header, rows) holds.
        let input = "x;y;z\n1;2;3\n4;5;6\n"
        let rust = try RustCSVAdapter.rustParse(input)
        XCTAssertEqual(rust.delimiter, ";")
        XCTAssertEqual(rust.header, ["x", "y", "z"])
        XCTAssertEqual(rust.rows, [["1", "2", "3"], ["4", "5", "6"]])
        XCTAssertFalse(rust.truncated)
    }
}
