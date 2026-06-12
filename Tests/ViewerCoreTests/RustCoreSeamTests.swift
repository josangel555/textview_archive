import XCTest
@testable import ViewerCore

/// Coverage for the generalized Rust-core seam (`RustCoreGates` +
/// `RustCoreFallback`) and the CSV gate's delegation to it. Pure logic — gate
/// precedence + fail-safe fallback — with injected defaults/environment, so no
/// global state is touched.
final class RustCoreSeamTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    override func setUp() {
        suiteName = "RustCoreSeam-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suiteName) }

    // MARK: Gate precedence

    func test_gate_shippedDefaults_matchTheSoakSet() {
        // TSK-649 stage A: the soak set (consumed + A/B-validated + longest
        // proven) ships ON; everything else stays OFF until its soak round.
        // Editing this set is a DELIBERATE soak decision, never a side effect.
        let soakSet: Set<RustCoreCapability> = [
            .csv, .indent, .diff, .hex, .hexSearch,
            .fuzzy, .find, .transcript, .markdown,
        ]
        for cap in RustCoreCapability.allCases {
            XCTAssertEqual(
                RustCoreGates.isEnabled(cap, defaults: defaults, environment: [:]),
                soakSet.contains(cap),
                "\(cap) shipped default diverged from the soak set")
        }
    }

    func test_gate_explicitUserOff_survivesShippedDefaultOn() {
        // A user who toggled a slice OFF stays OFF even after the shipped
        // default flips ON (object(forKey:) distinguishes unset from false).
        defaults.set(false, forKey: RustCoreCapability.csv.defaultsKey)
        XCTAssertFalse(RustCoreGates.isEnabled(.csv, defaults: defaults, environment: [:]),
                       "explicit OFF must beat the shipped default")
        // And the env kill switch still beats everything.
        defaults.removeObject(forKey: RustCoreCapability.csv.defaultsKey)
        XCTAssertFalse(RustCoreGates.isEnabled(
            .csv, defaults: defaults, environment: ["MDV_RUST_CSV": "0"]))
    }

    func test_gate_persistedToggle() {
        defaults.set(true, forKey: RustCoreCapability.markdown.defaultsKey)
        XCTAssertTrue(RustCoreGates.isEnabled(.markdown, defaults: defaults, environment: [:]))
        // The leak probe must be a capability whose SHIPPED default is OFF
        // (cmEdit is the only one left — it flips last); else the default
        // masks the probe.
        XCTAssertFalse(RustCoreGates.isEnabled(.cmEdit, defaults: defaults, environment: [:]),
                       "a different capability's toggle must not leak")
    }

    func test_gate_envOverride_winsOverToggle() {
        defaults.set(true, forKey: RustCoreCapability.csv.defaultsKey)
        // env "0" pins the Swift A-side even though the toggle is on.
        XCTAssertFalse(RustCoreGates.isEnabled(.csv, defaults: defaults, environment: ["MDV_RUST_CSV": "0"]))
        // env "1"/"true" forces ON even with toggle off.
        defaults.set(false, forKey: RustCoreCapability.csv.defaultsKey)
        XCTAssertTrue(RustCoreGates.isEnabled(.csv, defaults: defaults, environment: ["MDV_RUST_CSV": "1"]))
        XCTAssertTrue(RustCoreGates.isEnabled(.csv, defaults: defaults, environment: ["MDV_RUST_CSV": "true"]))
        XCTAssertFalse(RustCoreGates.isEnabled(.csv, defaults: defaults, environment: ["MDV_RUST_CSV": "yes"]),
                       "only 1/true count as ON")
    }

    func test_csv_legacyKeysPreserved() {
        XCTAssertEqual(RustCoreCapability.csv.defaultsKey, "MarkdownViewer.experimental.rustCSV")
        XCTAssertEqual(RustCoreCapability.csv.envVar, "MDV_RUST_CSV")
        // New capabilities follow the consistent scheme.
        XCTAssertEqual(RustCoreCapability.cmEdit.envVar, "MDV_RUST_CMEDIT")
        XCTAssertEqual(RustCoreCapability.hexSearch.defaultsKey, "MarkdownViewer.experimental.rust.hexSearch")
    }

    func test_envVars_unique() {
        let vars = RustCoreCapability.allCases.map(\.envVar)
        XCTAssertEqual(Set(vars).count, vars.count, "no two capabilities share an env var")
        let keys = RustCoreCapability.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count, "no two capabilities share a defaults key")
    }

    func test_rustCSVGate_delegatesToCoreGates() {
        // The CSV shim must agree with the generalized gate for the same inputs.
        for env in [[:], ["MDV_RUST_CSV": "1"], ["MDV_RUST_CSV": "0"]] as [[String: String]] {
            XCTAssertEqual(
                RustCSVGate.isEnabled(defaults: defaults, environment: env),
                RustCoreGates.isEnabled(.csv, defaults: defaults, environment: env),
                "shim disagreed with RustCoreGates for env \(env)")
        }
    }

    // MARK: Fallback contract

    func test_fallback_gateOff_runsSwift() {
        let o = RustCoreFallback.run(.diff, defaults: defaults, environment: ["MDV_RUST_DIFF": "0"],
                                     rust: { XCTFail("rust must not run when gate off"); return "R" },
                                     swift: { "S" })
        XCTAssertEqual(o.value, "S")
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertFalse(o.usedRust)
    }

    func test_fallback_gateOn_rustSucceeds() {
        let o = RustCoreFallback.run(.diff, defaults: defaults, environment: ["MDV_RUST_DIFF": "1"],
                                     rust: { "R" }, swift: { "S" })
        XCTAssertEqual(o.value, "R")
        XCTAssertEqual(o.source, .rust)
        XCTAssertTrue(o.usedRust)
    }

    func test_fallback_gateOn_rustThrows_fallsBackToSwift() {
        struct Boom: Error {}
        let o = RustCoreFallback.run(.diff, defaults: defaults, environment: ["MDV_RUST_DIFF": "1"],
                                     rust: { throw Boom() }, swift: { "S" })
        XCTAssertEqual(o.value, "S")
        XCTAssertEqual(o.source, .swiftFallback)
        XCTAssertFalse(o.usedRust, "a bridge fault must report Swift provenance")
    }
}
