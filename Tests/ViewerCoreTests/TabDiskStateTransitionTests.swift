import XCTest
@testable import ViewerCore

/// WAVE-1 foundations backfill: the *transition* behavior of the per-tab
/// disk-staleness signal as the on-disk `(mtime, size)` baseline evolves over
/// the lifetime of a tab. The sibling `TabDiskStateTests` pins single-shot
/// classifications; this suite walks a tab through the full state machine
/// (fresh → staleVsDisk → deleted, plus recovery + re-baseline) the way the
/// watcher / stat-sweep drives it, asserting each edge of
/// `Tab.classifyDiskState`.
///
/// Pure value logic — no FileManager, no app launch. Host-safe. Filter:
///   `swift test --filter ViewerCoreTests.TabDiskStateTransitionTests`
final class TabDiskStateTransitionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 1_000.000_001) // ns-resolution bump
    private let t2 = Date(timeIntervalSince1970: 2_000)

    /// Convenience: classify against a fixed baseline captured at load.
    private func classify(
        baseM: Date?, baseS: Int?,
        nowM: Date?, nowS: Int?, exists: Bool = true
    ) -> Tab.DiskState {
        Tab.classifyDiskState(
            baselineMTime: baseM, baselineSize: baseS,
            currentMTime: nowM, currentSize: nowS, currentExists: exists)
    }

    // MARK: fresh → stale → deleted (the canonical lifecycle)

    /// A tab loaded clean, then edited on disk (mtime bump), then deleted —
    /// the signal must walk fresh → staleVsDisk → deleted across the sweep.
    func test_lifecycle_freshThenStaleThenDeleted() {
        // 1. Just loaded: current stat == baseline → fresh.
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t0, nowS: 10), .fresh)
        // 2. External edit grows the file (mtime + size both move) → stale.
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t2, nowS: 25), .staleVsDisk)
        // 3. File removed entirely → deleted (baseline irrelevant once gone).
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: nil, nowS: nil, exists: false), .deleted)
    }

    /// `.deleted` wins even when `currentExists` is false but a stale stat
    /// (mtime/size) is somehow still supplied — existence is checked first.
    func test_deleted_takesPriorityOverStatMismatch() {
        XCTAssertEqual(
            classify(baseM: t0, baseS: 10, nowM: t2, nowS: 999, exists: false),
            .deleted)
    }

    /// Same-second edit that changes content but not the (1s-resolution)
    /// mtime is still caught by the SIZE dimension. Mirrors the
    /// `hasExternalEdit` "OR on either dimension" contract.
    func test_sameSecondEdit_caughtBySize() {
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t0, nowS: 11), .staleVsDisk)
    }

    /// Nanosecond mtime bump with identical size (APFS in-place same-length
    /// rewrite) is caught by the MTIME dimension.
    func test_nanosecondMtimeBump_sameSize_caughtByMtime() {
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t1, nowS: 10), .staleVsDisk)
    }

    // MARK: recovery / re-baseline

    /// After a reload re-baselines the loaded copy against disk, the SAME
    /// stat that previously read `.staleVsDisk` now reads `.fresh` — modeling
    /// `applyReload`'s `t.diskState = .fresh` re-baseline. We simulate it by
    /// adopting the post-edit stat as the NEW baseline.
    func test_reload_reBaselines_staleBecomesFresh() {
        // Was stale against the old baseline...
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t2, nowS: 25), .staleVsDisk)
        // ...reload adopts (t2, 25) as the new baseline → fresh again.
        XCTAssertEqual(classify(baseM: t2, baseS: 25, nowM: t2, nowS: 25), .fresh)
    }

    /// A file that was deleted then recreated (same path) re-stats as
    /// existing again; whether it reads fresh or stale depends purely on
    /// the new stat vs. the retained baseline — recreation alone does not
    /// pin it to `.deleted`.
    func test_recreatedFile_reclassifiesAgainstBaseline() {
        // Deleted...
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: nil, nowS: nil, exists: false), .deleted)
        // ...recreated with different bytes → stale (not stuck on deleted).
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t2, nowS: 42, exists: true), .staleVsDisk)
        // ...recreated byte-identical (same mtime+size) → fresh.
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t0, nowS: 10, exists: true), .fresh)
    }

    // MARK: conservative "can't prove a change" → fresh (never false-positive)

    /// A partial baseline (mtime known, size unknown) must not promote to
    /// stale on the unknown dimension alone — only a PROVEN mismatch on a
    /// known dimension flips it.
    func test_partialBaseline_mtimeMatchSizeUnknown_isFresh() {
        XCTAssertEqual(classify(baseM: t0, baseS: nil, nowM: t0, nowS: 10), .fresh)
    }

    /// Partial baseline where the KNOWN dimension mismatches still flips to
    /// stale (the unknown dimension doesn't shield a proven change).
    func test_partialBaseline_mtimeMismatchSizeUnknown_isStale() {
        XCTAssertEqual(classify(baseM: t0, baseS: nil, nowM: t2, nowS: 10), .staleVsDisk)
    }

    /// Current stat unavailable (nil mtime/size) but file exists — can't
    /// prove a change → fresh, never a spurious stale.
    func test_existsButCurrentStatUnavailable_isFresh() {
        XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: nil, nowS: nil, exists: true), .fresh)
    }

    // MARK: idempotence of a repeated sweep

    /// Re-running the sweep with the same inputs is stable (no oscillation):
    /// fresh stays fresh, stale stays stale until a reload re-baselines.
    func test_repeatedSweep_isStable() {
        for _ in 0..<3 {
            XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t0, nowS: 10), .fresh)
            XCTAssertEqual(classify(baseM: t0, baseS: 10, nowM: t2, nowS: 11), .staleVsDisk)
        }
    }
}
