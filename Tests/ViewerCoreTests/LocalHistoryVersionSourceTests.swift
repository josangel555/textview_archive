import XCTest
@testable import ViewerCore

/// Teeth for `LocalHistoryVersionSource` (TSK-1103) — the Local-History
/// conformance of `VersionSource` that drives the unified viewer. End-to-end
/// against a real `LocalHistoryStore` in a temp dir: list ordering, version-text
/// retrieval, diff-vs-current, this-version's-own-change, and range cumulative
/// diff. Diffs are asserted via the real parser (the renderer's path) so a
/// generator/source drift fails here.
final class LocalHistoryVersionSourceTests: XCTestCase {

    private var dir: URL!
    private var store: LocalHistoryStore!
    private let path = "/Users/me/notes.md"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-lhvs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalHistoryStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func date(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    /// Build a source whose "current" content is fixed to `current`.
    private func source(current: String) -> LocalHistoryVersionSource {
        LocalHistoryVersionSource(
            store: store, path: path, displayName: "notes.md",
            currentContent: { current })
    }

    /// Reconstruct the new file from parsed unified-diff text (added+context
    /// lines, new order).
    private func reconstructNew(_ text: String) -> [String] {
        var out: [String] = []
        for file in RustDiffAdapter.parse(text) {
            for hunk in file.hunks {
                for line in hunk.lines where line.kind == .added || line.kind == .context {
                    out.append(line.content)
                }
            }
        }
        // Drop the parser's trailing "" (its encoding of "diff text ended in \n";
        // see UnifiedDiffGeneratorTests) so this equals the file's logical lines.
        if out.last == "" { out.removeLast() }
        return out
    }

    // MARK: - list / content

    func test_listVersions_newestFirst() {
        store.snapshot(path: path, content: "v1\n", at: date(1000))
        store.snapshot(path: path, content: "v2\n", at: date(2000))
        store.snapshot(path: path, content: "v3\n", at: date(3000))
        let versions = source(current: "v3\n").listVersions()
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions[0].timestamp, date(3000))
        XCTAssertEqual(versions[2].timestamp, date(1000))
        XCTAssertTrue(versions.allSatisfy { $0.kind == .localHistory })
    }

    func test_listVersions_carriesByteSize() {
        // TSK-1462 — the timeline's size/delta annotation needs each ref to
        // carry its snapshot's byte size.
        store.snapshot(path: path, content: "12345\n", at: date(1000))       // 6 bytes
        store.snapshot(path: path, content: "1234567890\n", at: date(2000))  // 11 bytes
        let versions = source(current: "x").listVersions()   // newest-first
        XCTAssertEqual(versions.map(\.byteSize), [11, 6])
    }

    func test_content_ofVersion() {
        store.snapshot(path: path, content: "alpha\n", at: date(1000))
        let s = source(current: "alpha\n")
        let v = s.listVersions()[0]
        XCTAssertEqual(s.content(of: v), "alpha\n")
    }

    func test_content_unknownVersion_nil() {
        let s = source(current: "x")
        let bogus = VersionRef(id: "999", shortLabel: "?", timestamp: date(1), kind: .localHistory)
        XCTAssertNil(s.content(of: bogus))
    }

    // MARK: - diff vs current

    func test_diffAgainstCurrent_reflectsLiveContent() {
        store.snapshot(path: path, content: "one\ntwo\n", at: date(1000))
        let s = source(current: "one\nTWO\nthree\n")   // edited since the snapshot
        let v = s.listVersions()[0]
        let text = s.diffAgainstCurrent(v)
        XCTAssertFalse(text.isEmpty)
        // The diff applied to the old version reconstructs the CURRENT content.
        XCTAssertEqual(reconstructNew(text), ["one", "TWO", "three"])
    }

    func test_diffAgainstCurrent_emptyWhenIdentical() {
        store.snapshot(path: path, content: "same\n", at: date(1000))
        let s = source(current: "same\n")
        let v = s.listVersions()[0]
        XCTAssertEqual(s.diffAgainstCurrent(v), "")
    }

    // MARK: - this version's own change (vs predecessor)

    func test_diff_ownChange_vsPredecessor() {
        store.snapshot(path: path, content: "a\nb\n", at: date(1000))
        store.snapshot(path: path, content: "a\nB\nc\n", at: date(2000))
        let s = source(current: "a\nB\nc\n")
        let newest = s.listVersions()[0]   // the 2000 version
        let text = s.diff(from: newest, to: nil)
        XCTAssertFalse(text.isEmpty)
        // Own change reconstructs the newest version's content from its predecessor.
        XCTAssertEqual(reconstructNew(text), ["a", "B", "c"])
    }

    func test_diff_ownChange_oldestVsEmpty() {
        store.snapshot(path: path, content: "first\n", at: date(1000))
        let s = source(current: "first\n")
        let oldest = s.listVersions().last!
        let text = s.diff(from: oldest, to: nil)
        // Oldest has no predecessor → its own change is an all-add from empty.
        XCTAssertEqual(reconstructNew(text), ["first"])
    }

    // MARK: - two-version diff (ordered)

    func test_diff_twoVersions_orderedForward_regardlessOfClickOrder() {
        store.snapshot(path: path, content: "x\n", at: date(1000))
        store.snapshot(path: path, content: "x\ny\n", at: date(2000))
        let s = source(current: "x\ny\n")
        let versions = s.listVersions()
        let newer = versions[0], older = versions[1]
        // Click newer then older — should still read oldest→newest.
        let text = s.diff(from: newer, to: older)
        XCTAssertEqual(reconstructNew(text), ["x", "y"])
    }

    // MARK: - cumulative range

    func test_cumulativeDiff_acrossRange() {
        store.snapshot(path: path, content: "a\n", at: date(1000))
        store.snapshot(path: path, content: "a\nb\n", at: date(2000))
        store.snapshot(path: path, content: "a\nb\nc\n", at: date(3000))
        let s = source(current: "a\nb\nc\n")
        let versions = s.listVersions()   // [3000, 2000, 1000]
        // Range from oldest (1000) to newest (3000) → net change is +b +c.
        let text = s.cumulativeDiff(in: [versions[0], versions[2]])
        XCTAssertEqual(reconstructNew(text), ["a", "b", "c"])
    }

    func test_cumulativeDiff_singleOrEmpty_isEmpty() {
        store.snapshot(path: path, content: "a\n", at: date(1000))
        let s = source(current: "a\n")
        let v = s.listVersions()[0]
        XCTAssertEqual(s.cumulativeDiff(in: [v]), "")
        XCTAssertEqual(s.cumulativeDiff(in: []), "")
    }

    // MARK: - protocol-level

    func test_supportsRangeDiff_true() {
        XCTAssertTrue(source(current: "x").supportsRangeDiff)
    }
}
