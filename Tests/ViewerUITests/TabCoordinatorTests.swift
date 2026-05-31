import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// State-machine tests for `TabCoordinator`. Mirrors `TabsStateTests`
/// (pure-value semantics) but exercises the @MainActor coordinator
/// surface — append/close/move + the six per-tab dicts + the lazy
/// materializeTasks slot + split URL. No DocumentModel involvement.
///
/// The cleanup-after-close invariants (every per-tab dict drains
/// when its owning tab closes, across all three close paths) live
/// in `TabCoordinatorCleanupTests` so failures there point at the
/// fan-out bug directly instead of getting tangled up with the
/// append/select arithmetic in this file.
@MainActor
final class TabCoordinatorTests: XCTestCase {

    private func makeTab(_ name: String) -> Tab {
        Tab(url: URL(fileURLWithPath: "/\(name)"))
    }

    // MARK: - Initial state

    func test_initial_isEmpty() {
        let c = TabCoordinator()
        XCTAssertTrue(c.tabs.isEmpty)
        XCTAssertNil(c.selectedIndex)
        XCTAssertTrue(c.openTabURLs.isEmpty)
        XCTAssertNil(c.splitURL)
        XCTAssertFalse(c.isSplitOpen)
    }

    // MARK: - Append / openTabURLs maintenance

    func test_append_updates_openTabURLs() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        c.append(Tab(url: a))
        XCTAssertEqual(c.openTabURLs, [a])
        XCTAssertEqual(c.selectedIndex, 0)
    }

    func test_append_multiple_buildsUrlSet() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        c.append(Tab(url: a))
        c.append(Tab(url: b))
        XCTAssertEqual(c.openTabURLs, [a, b])
    }

    func test_append_blankTab_doesNotPolluteUrlSet() {
        let c = TabCoordinator()
        c.append(Tab())  // blank → url: nil
        XCTAssertTrue(c.openTabURLs.isEmpty)
    }

    // MARK: - openOrReveal

    func test_openOrReveal_appendsAndMaintainsUrlSet() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        c.openOrReveal(url: a, state: .empty, viewMode: .rendered)
        XCTAssertEqual(c.openTabURLs, [a])
    }

    func test_openOrReveal_existingURL_doesNotDuplicateUrlSet() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        c.append(Tab(url: a))
        c.openOrReveal(url: a, state: .empty, viewMode: .source)
        XCTAssertEqual(c.openTabURLs.count, 1, "url set must stay deduped")
        XCTAssertEqual(c.tabs.tabs.count, 1)
    }

    // MARK: - Replace / move

    func test_replace_doesNotChangeUrlSetWhenUrlStable() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        c.append(Tab(url: a))
        var t = c.tabs.tabs[0]
        t.viewMode = .source
        c.replace(at: 0, with: t)
        XCTAssertEqual(c.openTabURLs, [a])
    }

    func test_move_doesNotChangeUrlSet() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        c.append(Tab(url: a))
        c.append(Tab(url: b))
        c.move(from: 0, to: 2)
        XCTAssertEqual(c.openTabURLs, [a, b])
    }

    // MARK: - Per-tab CSV filter state

    func test_csvFilterState_roundTrips_perTab() {
        let c = TabCoordinator()
        let id1 = UUID(), id2 = UUID()
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "foo"
        c.setCsvFilterState(s, forTabID: id1)
        XCTAssertEqual(c.csvFilterState(forTabID: id1).globalQuery, "foo")
        XCTAssertEqual(c.csvFilterState(forTabID: id2).globalQuery, "",
                       "tabs without a stored entry get the default")
    }

    func test_csvFilterState_setEqualValue_isNoOpForPublish() {
        // setCsvFilterState dedupes on equality so the publisher
        // doesn't churn on every keystroke that matches the stored
        // value — same shape as FindCoordinator.setSourceMatchSummary.
        let c = TabCoordinator()
        let id = UUID()
        var count = 0
        let sub = c.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "x"
        c.setCsvFilterState(s, forTabID: id)
        let after1 = count
        c.setCsvFilterState(s, forTabID: id)  // identical value
        XCTAssertEqual(count, after1,
            "identical CSV state assignment must not republish")
    }

    func test_clearCsvFilterState_removes() {
        let c = TabCoordinator()
        let id = UUID()
        var s = TabCoordinator.CSVFilterState()
        s.globalQuery = "x"
        c.setCsvFilterState(s, forTabID: id)
        XCTAssertNotNil(c.csvFilterStates[id])
        c.clearCsvFilterState(forTabID: id)
        XCTAssertNil(c.csvFilterStates[id])
    }

    // MARK: - HEX width

    func test_hexWidth_returnsFallbackWhenNotSet() {
        let c = TabCoordinator()
        // Fallback gets clamped through HexLayout — 16 is in-range.
        XCTAssertEqual(c.hexWidth(forTabID: UUID(), fallback: 16), 16)
    }

    func test_hexWidth_storedValueWins() {
        let c = TabCoordinator()
        let id = UUID()
        c.setHexWidth(32, forTabID: id)
        XCTAssertEqual(c.hexWidth(forTabID: id, fallback: 16), 32)
    }

    func test_hexWidth_clampedOnWrite() {
        let c = TabCoordinator()
        let id = UUID()
        c.setHexWidth(100, forTabID: id)  // out of HexLayout range
        XCTAssertEqual(c.hexWidth(forTabID: id, fallback: 16), 64,
                       "HexLayout clamps to nearest allowed step (64)")
    }

    // MARK: - Language override

    func test_effectiveLanguage_noOverride_returnsAutodetected() {
        let c = TabCoordinator()
        XCTAssertEqual(
            c.effectiveLanguage(forTabID: UUID(), autodetected: .json),
            .json)
    }

    func test_setSelectedTabLanguage_storesAndClears() {
        let c = TabCoordinator()
        c.append(Tab(url: URL(fileURLWithPath: "/a.txt")))
        let id = c.selected!.id
        // .txt auto-detects as .plainText; override to .json.
        c.setSelectedTabLanguage(.json, autodetected: .plainText)
        XCTAssertEqual(c.effectiveLanguage(forTabID: id, autodetected: .plainText), .json)
        XCTAssertTrue(c.hasLanguageOverrideForSelected)
        // Setting back to autodetected clears the override.
        c.setSelectedTabLanguage(.plainText, autodetected: .plainText)
        XCTAssertFalse(c.hasLanguageOverrideForSelected)
        XCTAssertEqual(c.effectiveLanguage(forTabID: id, autodetected: .plainText), .plainText)
    }

    func test_languageOverride_isPerTab() {
        // Two tabs of "same" file — independent overrides keyed by Tab.id.
        let c = TabCoordinator()
        let url = URL(fileURLWithPath: "/twice.txt")
        c.append(Tab(url: url))
        let first = c.selected!.id
        c.append(Tab(url: url))
        let second = c.selected!.id
        XCTAssertNotEqual(first, second)
        c.setSelectedTabLanguage(.json, autodetected: .plainText)
        XCTAssertEqual(c.effectiveLanguage(forTabID: second, autodetected: .plainText), .json)
        XCTAssertEqual(c.effectiveLanguage(forTabID: first, autodetected: .plainText), .plainText)
    }

    // MARK: - Formatted tab flag + cache

    func test_toggleFormatForSelected_flipsFlag() {
        let c = TabCoordinator()
        c.append(Tab(url: URL(fileURLWithPath: "/a.json")))
        XCTAssertFalse(c.isSelectedTabFormatted)
        c.toggleFormatForSelected()
        XCTAssertTrue(c.isSelectedTabFormatted)
        c.toggleFormatForSelected()
        XCTAssertFalse(c.isSelectedTabFormatted)
    }

    func test_formattedCache_roundTripAndEvictsOldest() {
        let c = TabCoordinator()
        // Fill cache to its cap (8), then push one more — oldest should evict.
        var ids: [UUID] = []
        let mtime = Date(timeIntervalSince1970: 1_000)
        for i in 0..<8 {
            let id = UUID()
            ids.append(id)
            c.cacheFormatted("R\(i)", forTabID: id, sourceLength: 10,
                             modifiedTime: mtime, formattedLength: 2)
        }
        XCTAssertEqual(c.formattedTextCache.count, 8)
        // Push a 9th to trigger eviction.
        let extra = UUID()
        c.cacheFormatted("R9", forTabID: extra, sourceLength: 10,
                         modifiedTime: mtime, formattedLength: 2)
        // Eviction strategy drops to 2/3 of cap (=5) so the cache
        // contains 5 most recent entries (plus the new one = 6).
        // Specifically the OLDEST should be gone.
        XCTAssertNil(c.formattedTextCache[ids[0]],
                     "oldest entry must be evicted by insertion-order policy")
        XCTAssertNotNil(c.formattedTextCache[extra],
                        "freshly inserted entry must survive eviction")
    }

    func test_formattedHit_mismatchedLength_returnsNil() {
        let c = TabCoordinator()
        let id = UUID()
        let mtime = Date(timeIntervalSince1970: 1_000)
        c.cacheFormatted("R", forTabID: id, sourceLength: 10,
                         modifiedTime: mtime, formattedLength: 1)
        XCTAssertEqual(
            c.formattedHit(forTabID: id, sourceLength: 10, modifiedTime: mtime)?.formatted,
            "R")
        XCTAssertNil(
            c.formattedHit(forTabID: id, sourceLength: 11, modifiedTime: mtime),
            "length change invalidates the cached pretty-print")
    }

    // RWC-2 / TD-09: a same-byte-length reload (mtime changed, length
    // unchanged) must MISS so we don't serve pretty-printed output of
    // the prior bytes. The pre-fix length-only guard returned the stale
    // value here.
    func test_formattedHit_sameLengthNewMtime_returnsNil() {
        let c = TabCoordinator()
        let id = UUID()
        let oldMtime = Date(timeIntervalSince1970: 1_000)
        let newMtime = Date(timeIntervalSince1970: 2_000)
        c.cacheFormatted("OLD", forTabID: id, sourceLength: 10,
                         modifiedTime: oldMtime, formattedLength: 3)
        // Same length, same id, but the file was rewritten (new mtime).
        XCTAssertNil(
            c.formattedHit(forTabID: id, sourceLength: 10, modifiedTime: newMtime),
            "same-byte reload (new mtime) must invalidate the formatted cache")
        // Original mtime still hits.
        XCTAssertEqual(
            c.formattedHit(forTabID: id, sourceLength: 10, modifiedTime: oldMtime)?.formatted,
            "OLD")
    }

    // PERF-04: the formatted-output byte length is cached so the
    // highlight path forms its key without re-walking the string.
    func test_formattedHit_carriesFormattedLength() {
        let c = TabCoordinator()
        let id = UUID()
        let mtime = Date(timeIntervalSince1970: 1_000)
        c.cacheFormatted("hello world", forTabID: id, sourceLength: 5,
                         modifiedTime: mtime, formattedLength: 11)
        let hit = c.formattedHit(forTabID: id, sourceLength: 5, modifiedTime: mtime)
        XCTAssertEqual(hit?.formattedLength, 11)
    }

    // MARK: - Editor buffer

    func test_editorBuffer_returnsNilForBinaryTab() {
        let c = TabCoordinator()
        let bin = BinaryFile(url: URL(fileURLWithPath: "/x"), data: Data(),
                             totalByteCount: 0, isTruncated: false)
        c.append(Tab(url: bin.url, state: .binary(bin)))
        let id = c.selected!.id
        XCTAssertNil(c.editorBuffer(forTabID: id))
    }

    func test_editorBuffer_seedsLazilyFromLoadedState() {
        let c = TabCoordinator()
        let url = URL(fileURLWithPath: "/a.swift")
        let file = TextFile(url: url, contents: "let x = 1\n", encoding: .utf8,
                            byteCount: 10, modifiedTime: nil)
        c.append(Tab(url: url, state: .loaded(file)))
        let id = c.selected!.id
        let buf = c.editorBuffer(forTabID: id)
        XCTAssertNotNil(buf)
        XCTAssertEqual(buf?.text, "let x = 1\n")
        // Idempotent — second call returns the same cached instance.
        XCTAssertNotNil(c.editorBuffer(forTabID: id))
    }

    func test_ensureEditorBuffer_doesNotClobberExisting() {
        let c = TabCoordinator()
        let url = URL(fileURLWithPath: "/a.swift")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        c.append(Tab(url: url, state: .loaded(file)))
        let id = c.selected!.id
        var buf = c.editorBuffer(forTabID: id)!
        buf.setText("dirty edit")
        c.setEditorBuffer(buf, forTabID: id)
        // Calling ensure with the original file must NOT discard the
        // dirty edit (or any future Save / Discard prompt would
        // silently lose the user's work).
        c.ensureEditorBuffer(for: file, tabID: id)
        XCTAssertEqual(c.editorBuffers[id]?.text, "dirty edit")
    }

    func test_discardEditorBuffer_drops() {
        let c = TabCoordinator()
        let url = URL(fileURLWithPath: "/a.swift")
        let file = TextFile(url: url, contents: "x", encoding: .utf8,
                            byteCount: 1, modifiedTime: nil)
        c.append(Tab(url: url, state: .loaded(file)))
        let id = c.selected!.id
        _ = c.editorBuffer(forTabID: id)
        XCTAssertNotNil(c.editorBuffers[id])
        c.discardEditorBuffer(forTabID: id)
        XCTAssertNil(c.editorBuffers[id])
    }

    // MARK: - Materialize tasks

    func test_materializeTask_setGetClear() async {
        let c = TabCoordinator()
        let id = UUID()
        XCTAssertNil(c.materializeTask(forTabID: id))
        let task = Task<Void, Never> { /* no-op */ }
        c.setMaterializeTask(task, forTabID: id)
        XCTAssertNotNil(c.materializeTask(forTabID: id))
        await task.value
        c.clearMaterializeTask(forTabID: id)
        XCTAssertNil(c.materializeTask(forTabID: id))
    }

    func test_cancelMaterialize_cancelsAndClears() async {
        let c = TabCoordinator()
        let id = UUID()
        let task = Task<Void, Never> {
            // Sleep long enough to verify cancel takes effect.
            try? await Task.sleep(nanoseconds: 100_000_000_000)
        }
        c.setMaterializeTask(task, forTabID: id)
        c.cancelMaterialize(forTabID: id)
        XCTAssertNil(c.materializeTask(forTabID: id))
        // Cancelled task still completes (the sleep returns immediately
        // on cancel), and the slot is empty.
        await task.value
    }

    // MARK: - Split pane

    func test_splitURL_setAndClose() {
        let c = TabCoordinator()
        let a = URL(fileURLWithPath: "/a")
        c.openInSplit(a)
        XCTAssertEqual(c.splitURL, a.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(c.isSplitOpen)
        c.closeSplit()
        XCTAssertNil(c.splitURL)
        XCTAssertFalse(c.isSplitOpen)
    }
}
