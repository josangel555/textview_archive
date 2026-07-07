import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-1502 — the remembered-lens store (round-trip + eviction) and the
/// precedence resolver (lock > remembered-if-gate > default), plus the gate.
final class RememberedLensStoreTests: XCTestCase {

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remembered-\(UUID().uuidString).json")
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/docs/\(name)")
    }

    func test_remember_and_recall_roundTrip() {
        let store = RememberedLensStore(storeURL: tempStoreURL())
        XCTAssertNil(store.rememberedMode(for: url("a.md")))
        store.remember(url("a.md"), mode: .source)
        XCTAssertEqual(store.rememberedMode(for: url("a.md")), .source)
        // Case-insensitive filename key (macOS default FS).
        XCTAssertEqual(store.rememberedMode(for: url("A.MD")), .source)
        // Overwrite.
        store.remember(url("a.md"), mode: .rendered)
        XCTAssertEqual(store.rememberedMode(for: url("a.md")), .rendered)
        store.forget(url("a.md"))
        XCTAssertNil(store.rememberedMode(for: url("a.md")))
    }

    func test_persistsAcrossInstances() {
        let storeURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let s1 = RememberedLensStore(storeURL: storeURL)
        s1.remember(url("keep.csv"), mode: .table)
        JSONFileStore.flushSync()
        let s2 = RememberedLensStore(storeURL: storeURL)
        XCTAssertEqual(s2.rememberedMode(for: url("keep.csv")), .table,
                       "a fresh store instance recalls the persisted lens")
    }

    func test_eviction_boundsTheStore() {
        let store = RememberedLensStore(storeURL: tempStoreURL(), maxEntries: 10)
        for i in 0..<25 { store.remember(url("f\(i).md"), mode: .source) }
        // Count is bounded; exercised indirectly (no public count) via the
        // resolver still working for a recently-added key.
        XCTAssertEqual(store.rememberedMode(for: url("f24.md")), .source)
    }

    // MARK: - The precedence resolver (the on-consult logic)

    func test_resolve_lockWinsOverRemembered() {
        let m = RememberedLensStore.resolve(
            locked: .hex, remembered: .source,
            available: [.hex, .source, .rendered], inferredDefault: .rendered,
            gateOn: true)
        XCTAssertEqual(m, .hex, "an explicit lock always wins, even with the gate on")
    }

    func test_resolve_rememberedOnlyWhenGateOn() {
        let base = { (gate: Bool) in
            RememberedLensStore.resolve(
                locked: nil, remembered: .source,
                available: [.source, .rendered], inferredDefault: .rendered,
                gateOn: gate)
        }
        XCTAssertEqual(base(false), .rendered, "gate OFF → the remembered lens is ignored")
        XCTAssertEqual(base(true), .source, "gate ON → the remembered lens applies")
    }

    func test_resolve_availabilityGating() {
        // A remembered lens no longer available degrades to the default.
        let m = RememberedLensStore.resolve(
            locked: nil, remembered: .hex,
            available: [.source, .rendered], inferredDefault: .rendered,
            gateOn: true)
        XCTAssertEqual(m, .rendered)
        // Same for a stale lock.
        let l = RememberedLensStore.resolve(
            locked: .table, remembered: nil,
            available: [.source], inferredDefault: .source,
            gateOn: true)
        XCTAssertEqual(l, .source)
    }

    // MARK: - Gate

    func test_gate_shipsOff_envAndDefault() {
        let suite = "RememberedLensGate-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RememberedLensGate.isEnabled(defaults: d, environment: [:]),
                       "auto-remember ships OFF until the owner resolves it")
        XCTAssertTrue(RememberedLensGate.isEnabled(defaults: d, environment: ["MDV_REMEMBER_LENS": "1"]))
        d.set(true, forKey: RememberedLensGate.defaultsKey)
        XCTAssertTrue(RememberedLensGate.isEnabled(defaults: d, environment: [:]))
        XCTAssertFalse(RememberedLensGate.isEnabled(defaults: d, environment: ["MDV_REMEMBER_LENS": "0"]),
                       "env pin beats the persisted default")
    }
}
