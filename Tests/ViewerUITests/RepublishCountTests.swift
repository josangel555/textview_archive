import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1 (T1m, host-safe) **god-object republish** guard for tab operations
/// (TSK-108 perf cluster). Where `TabOpPerfTests` times the model-side work,
/// this counts how many times `DocumentModel.objectWillChange` fires
/// *synchronously* during a `selectTab` / `closeTab` on an already-warm,
/// same-view-mode tab.
///
/// Why this is the right signal: `ContentView` observes `DocumentModel`, so
/// every synchronous `objectWillChange` during a tab op forces a full
/// content-tree re-evaluation. The perf plan's Fix#2 (narrow ContentView
/// observation onto `tabCoordinator`) aims to drive this toward ~0; this test
/// records the CURRENT baseline and fails only on a balloon regression (a new
/// cascade that fans the count out by an order of magnitude). When Fix#2 lands
/// (live-validated turn) the upper bounds here get tightened to lock the win.
///
/// Async republishes (git-diff / LSP-warm Tasks that complete later) are
/// deliberately NOT counted: nothing spins the run loop inside a measured
/// block, so only the synchronous burst — the part that actually blocks the
/// main thread and storms the view — is observed.
@MainActor
final class RepublishCountTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepublishCount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RepublishCount-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Let any async materialize / updateDerived Tasks settle so the next
    /// measured block sees only its own synchronous republishes.
    private func drain() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        for _ in 0..<3 { await Task.yield() }
    }

    func test_warmSameModeTabSwitch_republishCount_isBounded() async throws {
        let model = makeModel()
        let n = 6
        let body = (0..<200).map { "line \($0): the quick brown fox" }.joined(separator: "\n")
        for i in 0..<n { model.open(url: try writeFile("f\(i).txt", body)) }
        XCTAssertEqual(model.tabs.tabs.count, n)

        // Warm pass: visit every tab once and let materialization settle, so
        // the measured pass switches between already-loaded same-mode tabs.
        for i in 0..<n { model.selectTab(at: i) }
        await drain()

        var count = 0
        let token = model.objectWillChange.sink { count += 1 }
        defer { token.cancel() }

        var perSwitch: [Int] = []
        // Two full sweeps of A→B→C→…; each individual selectTab is one warm switch.
        for _ in 0..<2 {
            for i in 0..<n {
                count = 0
                model.selectTab(at: i)        // synchronous burst only
                perSwitch.append(count)
            }
        }

        let worst = perSwitch.max() ?? 0
        let mean = Double(perSwitch.reduce(0, +)) / Double(perSwitch.count)
        print("[RepublishCount] warm selectTab: mean=\(String(format: "%.1f", mean)) worst=\(worst) over \(perSwitch.count) switches")

        // Baseline guard. MEASURED 2026-06-04: warm same-mode switch fires
        // exactly 1 god-object republish (mean=1.0, worst=1) — NOT a cascade.
        // (Key diagnostic: the model side is already minimal, so the live tab
        // freeze is entirely view-side — the cost of reacting to that 1
        // republish, i.e. full ContentView re-eval + WebView reload — which is
        // Fix#1's territory, not model-side republish trimming.) Bound at 4 (~4×
        // headroom): catches a re-wire that fans the count out per switch (the
        // #210/#215 lineage) without flaking on a +1. Fix#2 would drive this to 0.
        XCTAssertLessThanOrEqual(worst, 4,
            "warm same-mode tab switch ballooned god-object republishes (cascade regression; baseline=1)")
    }

    func test_closeTab_republishCount_isBounded() async throws {
        let model = makeModel()
        let n = 6
        let body = (0..<200).map { "line \($0): the quick brown fox" }.joined(separator: "\n")
        for i in 0..<n { model.open(url: try writeFile("f\(i).txt", body)) }
        for i in 0..<n { model.selectTab(at: i) }
        await drain()

        var count = 0
        let token = model.objectWillChange.sink { count += 1 }
        defer { token.cancel() }

        var perClose: [Int] = []
        while model.tabs.tabs.count > 0 {
            count = 0
            model.closeTab(at: model.tabs.tabs.count - 1)
            perClose.append(count)
        }
        let worst = perClose.max() ?? 0
        print("[RepublishCount] closeTab: worst=\(worst) over \(perClose.count) closes")

        // MEASURED 2026-06-04: worst=2 republishes per close. Bound at 6.
        XCTAssertLessThanOrEqual(worst, 6,
            "closing a tab ballooned god-object republishes (cascade regression; baseline=2)")
    }
}
