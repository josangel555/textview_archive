import XCTest
import RustCore
@testable import ViewerCore

/// Coverage for `RustCoreFallback.run` — the fail-safe router every
/// Rust-core slice ships behind (gate OFF → Swift; gate ON + Rust ok →
/// Rust; gate ON + Rust throws → Swift). This contract is the safety net
/// that lets a slice ship default-OFF without risking the proven path; it
/// was untested. Gate state is injected via `environment`/`defaults` so no
/// process state is touched. (The bridge-fault → Obs escalation added for
/// the audit finding is exercised by the throwing-path tests; we assert the
/// observable provenance contract here.)
final class RustCoreFallbackTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    // A capability whose SHIPPED default is still OFF (TSK-649 stage A
    // flipped csv/indent/diff ON) — these tests exercise the generic
    // fallback machinery and need the unset-default = off baseline.
    private let cap = RustCoreCapability.markdown

    override func setUp() {
        super.setUp()
        suiteName = "RustCoreFallbackTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var gateOnEnv: [String: String] { [cap.envVar: "1"] }

    func test_gateOff_runsSwift_taggedGateOff_andSkipsRust() {
        var rustCalled = false
        let out = RustCoreFallback.run(
            cap, defaults: defaults, environment: [:],
            rust: { rustCalled = true; return "rust" },
            swift: { "swift" })
        XCTAssertEqual(out.value, "swift")
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertFalse(out.usedRust)
        XCTAssertFalse(rustCalled, "gate OFF must not call into Rust at all")
    }

    func test_gateOn_rustSucceeds_taggedRust_andSkipsSwift() {
        var swiftCalled = false
        let out = RustCoreFallback.run(
            cap, defaults: defaults, environment: gateOnEnv,
            rust: { "rust" },
            swift: { swiftCalled = true; return "swift" })
        XCTAssertEqual(out.value, "rust")
        XCTAssertEqual(out.source, .rust)
        XCTAssertTrue(out.usedRust)
        XCTAssertFalse(swiftCalled, "a successful Rust result must not also run Swift")
    }

    func test_gateOn_rustThrowsPanic_fallsBackToSwift() {
        let out = RustCoreFallback.run(
            cap, defaults: defaults, environment: gateOnEnv,
            rust: { throw CoreError.panic },
            swift: { "swift-fallback" })
        XCTAssertEqual(out.value, "swift-fallback")
        XCTAssertEqual(out.source, .swiftFallback)
        XCTAssertFalse(out.usedRust)
    }

    func test_gateOn_rustThrowsNonPanic_fallsBackToSwift() {
        struct Boom: Error {}
        let out = RustCoreFallback.run(
            cap, defaults: defaults, environment: gateOnEnv,
            rust: { throw Boom() },
            swift: { 42 })
        XCTAssertEqual(out.value, 42)
        XCTAssertEqual(out.source, .swiftFallback)
    }

    func test_gateOn_viaUserDefaults_notEnv() {
        defaults.set(true, forKey: cap.defaultsKey)
        let out = RustCoreFallback.run(
            cap, defaults: defaults, environment: [:],
            rust: { "rust" },
            swift: { "swift" })
        XCTAssertEqual(out.source, .rust, "the defaults key alone should enable the gate")
    }

    func test_envOverrideBeatsDefaults_off() {
        // Env explicitly "0" overrides a defaults key that is ON → treated as
        // not "1"/"true", so the gate is OFF.
        defaults.set(true, forKey: cap.defaultsKey)
        let out = RustCoreFallback.run(
            cap, defaults: defaults, environment: [cap.envVar: "0"],
            rust: { "rust" },
            swift: { "swift" })
        XCTAssertEqual(out.source, .swiftBecauseGateOff,
                       "an explicit env '0' must win over a true defaults key")
    }
}
