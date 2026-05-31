import XCTest
@testable import ViewerCore

/// Tests for the per-tab disk-staleness signal (0d): the pure
/// `Tab.classifyDiskState` helper + `Tab.diskState` participation in
/// Equatable. Pure value logic, host-safe.
final class TabDiskStateTests: XCTestCase {

    private let m1 = Date(timeIntervalSince1970: 1_000)
    private let m2 = Date(timeIntervalSince1970: 2_000)

    // Missing file → .deleted regardless of baseline.
    func test_classify_missingFile_isDeleted() {
        let s = Tab.classifyDiskState(
            baselineMTime: m1, baselineSize: 10,
            currentMTime: nil, currentSize: nil, currentExists: false)
        XCTAssertEqual(s, .deleted)
    }

    // mtime mismatch → stale.
    func test_classify_mtimeMismatch_isStale() {
        let s = Tab.classifyDiskState(
            baselineMTime: m1, baselineSize: 10,
            currentMTime: m2, currentSize: 10, currentExists: true)
        XCTAssertEqual(s, .staleVsDisk)
    }

    // size mismatch (same mtime) → stale; catches same-second edits.
    func test_classify_sizeMismatch_isStale() {
        let s = Tab.classifyDiskState(
            baselineMTime: m1, baselineSize: 10,
            currentMTime: m1, currentSize: 11, currentExists: true)
        XCTAssertEqual(s, .staleVsDisk)
    }

    // Proven match → fresh.
    func test_classify_match_isFresh() {
        let s = Tab.classifyDiskState(
            baselineMTime: m1, baselineSize: 10,
            currentMTime: m1, currentSize: 10, currentExists: true)
        XCTAssertEqual(s, .fresh)
    }

    // Can't-tell (nil baseline) must NOT false-positive into stale — a
    // display signal mirrors hasExternalEdit's conservative `false`.
    func test_classify_unknownBaseline_isFresh() {
        let s = Tab.classifyDiskState(
            baselineMTime: nil, baselineSize: nil,
            currentMTime: m2, currentSize: 99, currentExists: true)
        XCTAssertEqual(s, .fresh)
    }

    // diskState participates in Equatable so SwiftUI re-diffs when it flips.
    func test_equatable_includesDiskState() {
        let url = URL(fileURLWithPath: "/tmp/x.md")
        let id = UUID()
        let fresh = Tab(id: id, url: url, state: .empty, diskState: .fresh)
        let stale = Tab(id: id, url: url, state: .empty, diskState: .staleVsDisk)
        XCTAssertNotEqual(fresh, stale)
        XCTAssertEqual(fresh, Tab(id: id, url: url, state: .empty, diskState: .fresh))
    }

    // Default is .fresh.
    func test_default_isFresh() {
        XCTAssertEqual(Tab(url: URL(fileURLWithPath: "/tmp/a")).diskState, .fresh)
    }
}
