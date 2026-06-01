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

    func testGateDefaultIsOff() {
        let d = scratchDefaults()
        // No env override, no persisted toggle → OFF (the safe shipping default).
        XCTAssertFalse(RustCSVGate.isEnabled(defaults: d, environment: [:]))
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

    func testAdapterParseAlwaysReturnsValidResultRegardlessOfGate() {
        // Whether or not the gate is on for THIS process, the public
        // `parse(_:)` must produce a usable result (it consults the live gate;
        // we just assert it doesn't blow up and matches Swift content).
        let input = "a,b\n1,2\n3,4\n"
        let result = RustCSVAdapter.parse(input)
        let swift = CSVParser.parse(input)
        XCTAssertEqual(result.header, swift.header)
        XCTAssertEqual(result.rows, swift.rows)
    }

    func testAdapterRustParseProducesSwiftIdenticalResult() throws {
        // Direct exercise of the Rust path (bypasses the gate) — proves the
        // Table → CSVParser.Result mapping is faithful.
        let input = "x;y;z\n1;2;3\n4;5;6\n"
        let rust = try RustCSVAdapter.rustParse(input)
        let swift = CSVParser.parse(input)
        XCTAssertEqual(rust.delimiter, swift.delimiter)
        XCTAssertEqual(rust.header, swift.header)
        XCTAssertEqual(rust.rows, swift.rows)
        XCTAssertEqual(rust.truncated, swift.truncated)
    }
}
