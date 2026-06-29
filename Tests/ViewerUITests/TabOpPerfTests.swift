import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1 (T1m, host-safe) timing guard for the **model-side** cost of tab
/// operations — the "closing a tab takes ~1s / switching is very slow" report
/// (TSK-108). This measures the SYNCHRONOUS main-actor work `selectTab` /
/// `closeTab` / `open` do on `DocumentModel` (republish trigger + updateDerived:
/// git-diff kick, repoFocus.recompute, warmLSP, scroll capture/restore). It does
/// NOT measure SwiftUI view re-render (no view tree here) — so:
///   • if these assertions are comfortably met, the live freeze is in the VIEW
///     layer (full-tree republish / WebView reload) → fix = narrow observation;
///   • if they FAIL, the model path itself is doing blocking work per op → fix
///     there.
/// Either outcome is diagnostic. Thresholds are generous (a model-side tab op
/// should be sub-millisecond-ish; we assert well above noise to avoid flakes but
/// still catch a 1s-class regression).
@MainActor
final class TabOpPerfTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabOpPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "TabOpPerf-\(UUID().uuidString)"
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

    private func ms(_ block: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
    }

    func test_modelSide_tabSwitch_and_close_areFast() throws {
        let model = makeModel()
        let n = 8
        // A few hundred lines each — representative of a real source file.
        let body = (0..<400).map { "line \($0): the quick brown fox jumps over the lazy dog" }
            .joined(separator: "\n")
        for i in 0..<n { model.open(url: try writeFile("f\(i).txt", body)) }
        XCTAssertEqual(model.tabs.tabs.count, n)

        // Switch across all tabs twice; record worst + mean.
        var switchTimes: [Double] = []
        for _ in 0..<2 {
            for i in 0..<n {
                switchTimes.append(ms { model.selectTab(at: i) })
            }
        }
        let worstSwitch = switchTimes.max() ?? 0
        let meanSwitch = switchTimes.reduce(0, +) / Double(switchTimes.count)
        print("[TabOpPerf] model-side selectTab: mean=\(String(format: "%.2f", meanSwitch))ms worst=\(String(format: "%.2f", worstSwitch))ms over \(switchTimes.count) switches")

        // Close from the right; record per-close time.
        var closeTimes: [Double] = []
        while model.tabs.tabs.count > 0 {
            let idx = model.tabs.tabs.count - 1
            closeTimes.append(ms { model.closeTab(at: idx) })
        }
        let worstClose = closeTimes.max() ?? 0
        print("[TabOpPerf] model-side closeTab: worst=\(String(format: "%.2f", worstClose))ms over \(closeTimes.count) closes")

        // Generous guards — catch a 1s-class regression, tolerate CI noise.
        // The wall-clock WORST-case can't measure reliably INSIDE the parallel
        // headless gate: `--num-workers` contention spikes a single op to ~300ms+
        // via scheduler starvation (NOT a real freeze — flaked 2026-06-29 at
        // 332ms). Assert the timing only OUTSIDE the parallel gate (isolated /
        // nightly), same policy as CrossFileSearchBench; under the gate the test
        // body still exercises selectTab/closeTab (behavior), we just don't pin
        // wall-clock. A real 1s-class freeze still fails the isolated/nightly run.
        if ProcessInfo.processInfo.environment["MDV_HEADLESS_GATE"] == nil {
            XCTAssertLessThan(worstSwitch, 250, "model-side tab switch should not be a 1s-class freeze")
            XCTAssertLessThan(worstClose, 250, "model-side tab close should not be a 1s-class freeze")
        } else {
            print("[TabOpPerf] wall-clock asserts skipped under MDV_HEADLESS_GATE (parallel-contention noise); worstSwitch=\(String(format: "%.1f", worstSwitch))ms worstClose=\(String(format: "%.1f", worstClose))ms")
        }
    }
}
