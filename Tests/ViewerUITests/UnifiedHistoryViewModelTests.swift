import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// Teeth for `UnifiedHistoryViewModel` (TSK-1103) — the single view-model
/// driving the unified version viewer for BOTH back-ends. Pins the selection
/// state machine (none/single/range), the single-mode toggle
/// (own-change / view / vs-current), last-write-wins, and Restore — so a logic
/// regression fails the HOST gate even though the SwiftUI pixels are VM-only.
///
/// Uses a deterministic in-memory `VersionSource` fake so the tests are pure +
/// fast (no git, no disk).
@MainActor
final class UnifiedHistoryViewModelTests: XCTestCase {

    /// In-memory fake. Versions carry their content inline; diffs are encoded
    /// as readable sentinels so transitions are assertable without a real diff.
    struct FakeSource: VersionSource {
        let displayName = "fake.txt"
        let versionsList: [VersionRef]
        let contents: [String: String]   // id → content
        let current: String

        func listVersions() -> [VersionRef] { versionsList }
        func content(of version: VersionRef) -> String? { contents[version.id] }
        func diffAgainstCurrent(_ version: VersionRef) -> String {
            "DIFF(\(version.id) vs current)"
        }
        func diff(from: VersionRef, to: VersionRef?) -> String {
            if let to { return "DIFF(\(from.id)..\(to.id))" }
            return "OWNCHANGE(\(from.id))"
        }
        func cumulativeDiff(in selection: [VersionRef]) -> String {
            let ids = selection.map(\.id).sorted().joined(separator: ",")
            return "CUMULATIVE(\(ids))"
        }
    }

    private func ref(_ id: String, _ t: TimeInterval, bytes: Int? = nil) -> VersionRef {
        VersionRef(id: id, shortLabel: id, timestamp: Date(timeIntervalSince1970: t),
                   byteSize: bytes, kind: .localHistory)
    }

    private func makeVM() -> UnifiedHistoryViewModel {
        // v3 newest, v1 oldest.
        let v1 = ref("v1", 1000), v2 = ref("v2", 2000), v3 = ref("v3", 3000)
        let source = FakeSource(
            versionsList: [v3, v2, v1],
            contents: ["v1": "one\n", "v2": "two\n", "v3": "three\n"],
            current: "current\n")
        let vm = UnifiedHistoryViewModel(source: source, kind: .localHistory)
        vm.reloadVersionsSync()
        return vm
    }

    /// Poll `detail` until it satisfies `pred` or a short timeout, since detail
    /// loads run on a detached task.
    private func awaitDetail(_ vm: UnifiedHistoryViewModel,
                             where pred: @escaping (UnifiedHistoryViewModel.Detail) -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if pred(vm.detail) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
        }
        XCTFail("detail did not reach expected state; got \(vm.detail)", file: file, line: line)
    }

    // MARK: - list

    func test_reload_listsNewestFirst() {
        let vm = makeVM()
        XCTAssertEqual(vm.versions.map(\.id), ["v3", "v2", "v1"])
    }

    // MARK: - single selection + modes

    func test_singleClick_setsSingleMode_ownChangeByDefault() async {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)
        XCTAssertEqual(vm.selectionMode, .single)
        XCTAssertEqual(vm.primarySelection, "v3")
        await awaitDetail(vm) { $0 == .diff("OWNCHANGE(v3)") }
    }

    func test_toggle_toViewVersion_showsContent() async {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)
        vm.setSingleMode(.viewVersion)
        await awaitDetail(vm) { $0 == .content("three\n") }
    }

    func test_toggle_toDiffVsCurrent() async {
        let vm = makeVM()
        vm.click(version: vm.versions[1], command: false)   // v2
        vm.setSingleMode(.diffVsCurrent)
        await awaitDetail(vm) { $0 == .diff("DIFF(v2 vs current)") }
    }

    func test_setSameMode_isNoOp() {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)
        XCTAssertEqual(vm.singleMode, .ownChange)
        vm.setSingleMode(.ownChange)   // no change
        XCTAssertEqual(vm.singleMode, .ownChange)
    }

    // MARK: - range selection

    func test_cmdClickSecond_armsRange_andShowsCumulative() async {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)        // single v3
        vm.click(version: vm.versions[2], command: true)         // cmd v1 → range
        XCTAssertEqual(vm.selectionMode, .range)
        XCTAssertEqual(Set(vm.rangeSelection.map(\.id)), ["v3", "v1"])
        await awaitDetail(vm) { $0 == .diff("CUMULATIVE(v1,v3)") }
    }

    func test_thirdCmdClick_startsFreshPair() {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)   // v3 single
        vm.click(version: vm.versions[1], command: true)    // → range v3,v2
        XCTAssertEqual(vm.selectionMode, .range)
        vm.click(version: vm.versions[2], command: true)    // third → fresh pair from primary
        // After a third cmd-click, the range is rebuilt (cap 2 enforced).
        XCTAssertLessThanOrEqual(vm.rangeSelection.count, 2)
    }

    func test_clearRange_returnsToSingle() async {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)   // v3 single (primary)
        vm.click(version: vm.versions[2], command: true)    // range v3,v1
        XCTAssertEqual(vm.selectionMode, .range)
        vm.clearRange()
        XCTAssertEqual(vm.selectionMode, .single)
        await awaitDetail(vm) { $0 == .diff("OWNCHANGE(v3)") }
    }

    func test_rangeLabel_ordersOldestToNewest() {
        let vm = makeVM()
        vm.click(version: vm.versions[0], command: false)   // v3
        vm.click(version: vm.versions[2], command: true)    // v1
        XCTAssertEqual(vm.rangeLabel, "v1 → v3")
    }

    // MARK: - Restore

    func test_restoreCandidateContent_returnsSelectedVersionText() {
        let vm = makeVM()
        vm.click(version: vm.versions[1], command: false)   // v2
        XCTAssertEqual(vm.restoreCandidateContent(), "two\n")
    }

    func test_restoreCandidateContent_nilWhenNoSelection() {
        let vm = makeVM()
        XCTAssertNil(vm.restoreCandidateContent())
    }

    // MARK: - Size annotation (TSK-1462)

    func test_byteLabel_deterministicUnits() {
        XCTAssertEqual(UnifiedHistoryViewModel.byteLabel(0), "0 B")
        XCTAssertEqual(UnifiedHistoryViewModel.byteLabel(999), "999 B")
        XCTAssertEqual(UnifiedHistoryViewModel.byteLabel(1_200), "1.2 KB")
        XCTAssertEqual(UnifiedHistoryViewModel.byteLabel(34_000), "34 KB")
        XCTAssertEqual(UnifiedHistoryViewModel.byteLabel(3_400_000), "3.4 MB")
    }

    func test_sizeAnnotation_pureFormatting() {
        // No size (git) → no annotation.
        XCTAssertNil(UnifiedHistoryViewModel.sizeAnnotation(bytes: nil, olderBytes: 5))
        // Oldest version (no predecessor) → plain size.
        XCTAssertEqual(UnifiedHistoryViewModel.sizeAnnotation(bytes: 500, olderBytes: nil),
                       "500 B")
        // Growth / shrink / equal.
        XCTAssertEqual(UnifiedHistoryViewModel.sizeAnnotation(bytes: 840, olderBytes: 500),
                       "840 B (+340 B)")
        XCTAssertEqual(UnifiedHistoryViewModel.sizeAnnotation(bytes: 488, olderBytes: 500),
                       "488 B (−12 B)")
        XCTAssertEqual(UnifiedHistoryViewModel.sizeAnnotation(bytes: 500, olderBytes: 500),
                       "500 B (±0 B)")
    }

    func test_sizeAnnotation_usesPredecessorInNewestFirstList() {
        let v1 = ref("v1", 1000, bytes: 100), v2 = ref("v2", 2000, bytes: 340),
            v3 = ref("v3", 3000, bytes: 300)
        let source = FakeSource(
            versionsList: [v3, v2, v1],
            contents: [:], current: "")
        let vm = UnifiedHistoryViewModel(source: source, kind: .localHistory)
        vm.reloadVersionsSync()
        XCTAssertEqual(vm.sizeAnnotation(for: v3), "300 B (−40 B)")
        XCTAssertEqual(vm.sizeAnnotation(for: v2), "340 B (+240 B)")
        XCTAssertEqual(vm.sizeAnnotation(for: v1), "100 B", "oldest has no predecessor")
    }
}
