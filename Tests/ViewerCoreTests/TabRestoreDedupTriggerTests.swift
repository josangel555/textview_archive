import XCTest
import ViewerKit
@testable import ViewerCore

/// Regression coverage for the ORIGINAL trigger of TRACE #188 — the launch-
/// memory ratchet that grew an active session to ~1951 persisted tabs of only
/// ~35 unique files.
///
/// Root cause (reconstructed from `git log -S` → commit `41e21f2`,
/// "bug1: normalize symlinked URLs in TabsState.openOrReveal dedup —
/// close-1-reopen-2 fix"): before that commit `openOrReveal` deduped on RAW
/// URL equality (`$0.url == url`), while `appendLazyTab` (workspace restore)
/// stored the NORMALIZED form (`standardizedFileURL.resolvingSymlinksInPath`).
/// On macOS the same physical file is reachable as both `/var/…` and
/// `/private/var/…` (the `/var → /private/var` symlink that every
/// `/var/folders/…` scratch root and `/tmp` live under):
///
///   raw URL equality:        /var/…/doc.md  ==  /private/var/…/doc.md  → FALSE
///   normalized dedupKey:     both collapse to /var/…/doc.md            → EQUAL
///
/// So a restored (normalized) tab plus an open via the OTHER form (e.g. an
/// NSOpenPanel / realpath flow that hands back `/private/var/…`) did NOT match
/// under raw equality → a SECOND tab spawned for the same file. `makeSnapshot`
/// re-persisted the now-2 entries; next launch hydrated 2 and re-touched the
/// focused one → 3 → … a one-way ratchet, ~1 step/launch/re-touched file. 35
/// unique files compounding over dozens of launches → 1951.
///
/// The fix funnels BOTH sides through `TabsState.dedupKey`. These tests pin
/// the trigger at the pure-`TabsState` layer (no app launch) using REAL temp
/// files so `resolvingSymlinksInPath` actually collapses the `/private/var ↔
/// /var` pair (it only resolves symlink components that exist on disk).
///
/// Filter: `swift test --filter ViewerCoreTests.TabRestoreDedupTriggerTests`
final class TabRestoreDedupTriggerTests: XCTestCase {

    private var tmp: URL!
    /// A real on-disk file, reachable as `/var/…` (its natural temp path)…
    private var varForm: URL!
    /// …and as `/private/var/…` (the same file via the `/private` prefix).
    private var privateForm: URL!

    override func setUpWithError() throws {
        // `temporaryDirectory` is under /var/folders/… on macOS; create a real
        // file so symlink resolution has something to resolve.
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DedupTrigger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        varForm = tmp.appendingPathComponent("doc.md")
        try "# hi\n".write(to: varForm, atomically: true, encoding: .utf8)
        // The `/private/var/…` twin of the same physical file.
        privateForm = URL(fileURLWithPath: "/private" + varForm.path)

        // Skip if this host's temp dir isn't the /var→/private/var shape the
        // trigger needs (defensive — true on stock macOS).
        try XCTSkipUnless(
            varForm.path.hasPrefix("/var/")
                && FileManager.default.fileExists(atPath: privateForm.path)
                && TabsState.dedupKey(varForm) == TabsState.dedupKey(privateForm),
            "host temp dir is not /var↔/private/var symlinked; trigger can't be reproduced")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func textState(_ url: URL) -> DocumentState {
        .loaded(TextFile(url: url, contents: "x", encoding: .utf8, byteCount: 1))
    }

    // MARK: dedupKey collapses the symlink pair (the asymmetry the bug exploited)

    func test_dedupKey_collapsesVarSymlinkPair() {
        XCTAssertEqual(
            TabsState.dedupKey(varForm), TabsState.dedupKey(privateForm),
            "the /var↔/private/var forms of one real file must produce one dedup key")
        // …and raw equality does NOT — the exact pre-fix comparison that failed.
        XCTAssertNotEqual(varForm, privateForm,
            "raw URL equality treats the two forms as different (the original bug)")
    }

    // MARK: the trigger — opening via the OTHER form must reveal, not duplicate

    /// Reproduce the #188 trigger and assert it no longer fires: a tab
    /// restored under one form, then the SAME file opened via the OTHER form,
    /// must REVEAL the existing tab (one tab) — not spawn a second. Pre-fix
    /// this returned a fresh appended index and left two tabs.
    func test_trigger_otherFormOpenRevealsRestoredTab_noDuplicate() {
        // Simulate restore: a lazy tab carrying the normalized /var form
        // (what `appendLazyTab` stores).
        var state = TabsState(tabs: [
            Tab(url: varForm, state: .empty, viewMode: .source)
        ], selectedIndex: 0)
        XCTAssertEqual(state.tabs.count, 1)

        // User re-opens the same file via the /private/var form.
        let idx = state.openOrReveal(
            url: privateForm, state: textState(privateForm), viewMode: .rendered)

        XCTAssertEqual(state.tabs.count, 1,
            "opening the /private/var twin of an already-open file must NOT append a duplicate (#188 trigger)")
        XCTAssertEqual(idx, 0, "it reveals the existing tab")
        XCTAssertEqual(state.selectedIndex, 0)
    }

    /// The lazy (`.empty`, restored) tab being revealed adopts the freshly
    /// computed view mode rather than its stale persisted one.
    func test_trigger_revealedLazyTab_adoptsNewViewMode() {
        var state = TabsState(tabs: [
            Tab(url: varForm, state: .empty, viewMode: .source)  // stale persisted mode
        ], selectedIndex: 0)
        _ = state.openOrReveal(
            url: privateForm, state: textState(privateForm), viewMode: .rendered)
        XCTAssertEqual(state.tabs.first?.viewMode, .rendered,
            "a revealed lazy/restored tab uses the new computed mode, not its stale persisted one")
    }

    // MARK: idempotence — the ratchet cannot take a single step

    /// Repeatedly re-opening the same file in alternating forms — the exact
    /// across-launch motion that compounded the ratchet — keeps the tab count
    /// pinned at 1.
    func test_ratchet_repeatedAlternatingFormOpens_stayOneTab() {
        var state = TabsState(tabs: [
            Tab(url: varForm, state: .empty, viewMode: .source)
        ], selectedIndex: 0)
        for i in 0..<64 {
            let url = (i % 2 == 0) ? privateForm! : varForm!
            _ = state.openOrReveal(url: url, state: textState(url), viewMode: .rendered)
            XCTAssertEqual(state.tabs.count, 1,
                "open #\(i): the dedup must hold every iteration — no ratchet step")
        }
    }

    /// `dedupedRestoreTabs` collapses the two forms on the RESTORE read side
    /// too, so a snapshot that already accumulated both heals to one entry.
    func test_restoreDedup_collapsesVarAndPrivateVarTwins() {
        let input: [(path: String, viewMode: String)] = [
            (path: varForm.path, viewMode: "source"),
            (path: privateForm.path, viewMode: "rendered"),   // same file, other form
            (path: varForm.path, viewMode: "rendered"),
        ]
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.count, 1,
            "both forms of one file must collapse to a single restored tab")
        XCTAssertEqual(out.first?.viewMode, "source", "first occurrence wins")
    }

    // MARK: cap constant — the defensive ceiling on a malicious/huge snapshot

    /// Pin the exact cap value. A drift here (e.g. a refactor bumping it to
    /// thousands) silently re-opens the unbounded-allocation surface the cap
    /// exists to close, so the magic number is asserted, not assumed.
    func test_cap_isExactly200() {
        XCTAssertEqual(TabsState.maxRestoredTabs, 200,
            "the restore cap must stay at the documented 200-tab ceiling")
    }

    /// The cap clamps a list of all-UNIQUE files (dedup can't help) to exactly
    /// `maxRestoredTabs`, keeping the TAIL (nearest last focus). This is the
    /// limb the per-tab `appendLazyTab` guard cannot cover — only the
    /// restore-side cap bounds a legitimately enormous unique list.
    func test_cap_clampsAllUniqueListToTail() {
        let n = TabsState.maxRestoredTabs + 137
        let input = (0..<n).map { (path: "/u/\($0).md", viewMode: "source") }
        let out = TabsState.dedupedRestoreTabs(input)
        XCTAssertEqual(out.count, TabsState.maxRestoredTabs)
        XCTAssertEqual(out.last?.path, "/u/\(n - 1).md", "tail (last-focused) survives")
        XCTAssertEqual(out.first?.path, "/u/\(n - TabsState.maxRestoredTabs).md",
            "the oldest entries past the cap are dropped from the head")
    }
}
