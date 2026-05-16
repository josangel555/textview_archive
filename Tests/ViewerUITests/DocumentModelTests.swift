import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1 main-actor tests for the top-level app model.
///
/// We don't mock the controller / loader — they're already fast and exercising
/// the real file path catches more bugs (the "vanishing tabs" bug surfaced
/// here was about how `tabs` republished, not anything mockable).
@MainActor
final class DocumentModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Initial state

    func test_initial_isEmpty() {
        let model = makeModel()
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.currentURL)
        if case .empty = model.currentState {} else {
            XCTFail("expected .empty initial state")
        }
        // App was renamed to TextView (commit dab1759); ensure the
        // default window title matches what users see in Finder.
        XCTAssertEqual(model.windowTitle, "TextView")
    }

    // MARK: Opening files

    func test_open_addsLoadedTab() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# hi")
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
        if case .loaded(let file) = model.currentState {
            XCTAssertEqual(file.contents, "# hi")
        } else {
            XCTFail("expected .loaded")
        }
        XCTAssertEqual(model.recents.count, 1)
    }

    func test_open_sameURLTwice_doesNotCreateDuplicateTab() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        let b = try writeFile("b.md")
        model.open(url: a)
        model.open(url: b)
        model.open(url: a)  // re-open a
        XCTAssertEqual(model.tabs.tabs.count, 2,
                       "re-opening an already-open file should switch, not append")
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    func test_open_missingFile_keepsExistingTabAndAppendsError() throws {
        let model = makeModel()
        let existing = try writeFile("ok.md")
        model.open(url: existing)
        XCTAssertEqual(model.tabs.tabs.count, 1)

        let ghost = tmpDir.appendingPathComponent("never.md")
        model.open(url: ghost)

        // The original tab is still there — this is the regression that read
        // as "all tabs vanished" before the fix.
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertEqual(model.tabs.tabs[0].url?.lastPathComponent, "ok.md")
        if case .error = model.tabs.tabs[1].state {} else {
            XCTFail("expected .error in second tab")
        }
    }

    func test_open_failedLoad_isNotRecordedInRecents() throws {
        let model = makeModel()
        let ghost = tmpDir.appendingPathComponent("never.md")
        model.open(url: ghost)
        XCTAssertTrue(model.recents.isEmpty, "failed opens should not pollute recents")
    }

    // MARK: Tab management

    func test_newTab_appendsBlank() throws {
        let model = makeModel()
        model.newTab()
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertTrue(model.tabs.tabs[0].isBlank)
    }

    func test_open_reusesBlankTab() throws {
        let model = makeModel()
        model.newTab()
        let url = try writeFile("a.md")
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1,
                       "blank tab should host the new file rather than appending")
        XCTAssertEqual(model.tabs.tabs[0].url, url.standardizedFileURL.resolvingSymlinksInPath())
    }

    func test_closeCurrentTab_dropsAndShiftsSelection() throws {
        let model = makeModel()
        try [("a.md","a"), ("b.md","b"), ("c.md","c")].forEach {
            let url = try writeFile($0.0, $0.1)
            model.open(url: url)
        }
        XCTAssertEqual(model.tabs.tabs.count, 3)
        model.selectTab(at: 1)  // /b
        model.closeCurrentTab()
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "c.md",
                       "closing the middle tab should select its right neighbor")
    }

    func test_selectNextTab_wraps() throws {
        let model = makeModel()
        for name in ["a", "b", "c"] {
            let url = try writeFile("\(name).md")
            model.open(url: url)
        }
        // selected = 2 (c). Next should wrap to 0 (a).
        model.selectNextTab()
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    func test_selectPreviousTab_wraps() throws {
        let model = makeModel()
        for name in ["a", "b", "c"] {
            let url = try writeFile("\(name).md")
            model.open(url: url)
        }
        model.selectTab(at: 0)
        model.selectPreviousTab()
        XCTAssertEqual(model.currentURL?.lastPathComponent, "c.md")
    }

    // MARK: View mode

    func test_toggleViewMode_flipsCurrentTabOnly() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        let b = try writeFile("b.md")
        model.open(url: a)
        model.open(url: b)
        model.selectTab(at: 0)
        XCTAssertEqual(model.currentViewMode, .rendered)
        model.toggleViewMode()
        XCTAssertEqual(model.currentViewMode, .source)
        // Switching to the other tab still shows .rendered (default).
        model.selectTab(at: 1)
        XCTAssertEqual(model.currentViewMode, .rendered)
        // And switching back preserves the per-tab mode.
        model.selectTab(at: 0)
        XCTAssertEqual(model.currentViewMode, .source)
    }

    func test_supportsViewModeToggle_onlyForMarkdown() throws {
        let model = makeModel()
        let txt = try writeFile("notes.txt")
        let md  = try writeFile("readme.md")
        model.open(url: txt)
        XCTAssertFalse(model.supportsViewModeToggle)
        model.open(url: md)
        XCTAssertTrue(model.supportsViewModeToggle)
    }

    // MARK: Reload

    func test_reloadCurrentFile_picksUpDiskChanges() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "v1")
        model.open(url: url)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        model.reloadCurrentFile()
        if case .loaded(let f) = model.currentState {
            XCTAssertEqual(f.contents, "v2")
        } else {
            XCTFail("expected .loaded")
        }
    }

    // MARK: Folder

    func test_openFolder_setsSidebarRoot() throws {
        let model = makeModel()
        let folder = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        XCTAssertEqual(model.sidebar.rootURL?.resolvingSymlinksInPath(),
                       folder.resolvingSymlinksInPath())
        XCTAssertTrue(model.sidebar.isVisible)
    }

    // MARK: Sidebar width

    func test_sidebarWidth_isClampedAndPersisted() {
        let model = makeModel()
        model.setSidebarWidth(50)  // below the 160 floor
        XCTAssertEqual(model.sidebarWidth, PreferencesStore.minSidebarWidth)
        // Reloading the model from the same defaults reads back the clamped value.
        let model2 = makeModel()
        XCTAssertEqual(model2.sidebarWidth, PreferencesStore.minSidebarWidth)
    }

    func test_setSidebarWidthLive_doesNotPersistUntilPersist() {
        let model = makeModel()
        model.setSidebarWidthLive(300)
        XCTAssertEqual(model.sidebarWidth, 300)
        // A fresh model from the same defaults still reads the original value
        // because we never called persist.
        let model2 = makeModel()
        XCTAssertNotEqual(model2.sidebarWidth, 300)

        // Now persist and the next model picks it up.
        model.persistSidebarWidth()
        let model3 = makeModel()
        XCTAssertEqual(model3.sidebarWidth, 300)
    }

    // MARK: Context-menu commands (Close Others / Close to the Right / Open in New Tab)

    func test_closeOtherTabs_keepsOne() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        XCTAssertEqual(model.tabs.tabs.count, 3)
        model.closeOtherTabs(keeping: 1)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "b.md")
    }

    func test_closeTabsToRight_removesTrailing() throws {
        let model = makeModel()
        for n in ["a", "b", "c", "d"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.selectTab(at: 1)
        model.closeTabsToRight(of: 1)
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent },
                       ["a.md", "b.md"])
        XCTAssertEqual(model.currentURL?.lastPathComponent, "b.md")
    }

    func test_openInNewTab_doesNotReuseExistingTab() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        model.open(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        // Standard open() reuses the existing tab; openInNewTab forces append.
        model.openInNewTab(a)
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    // MARK: Move-tab shortcuts

    func test_moveCurrentTabLeft() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        // Selected = c (last).
        model.moveCurrentTabLeft()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent },
                       ["a.md", "c.md", "b.md"])
        // Selection follows the moved tab.
        XCTAssertEqual(model.currentURL?.lastPathComponent, "c.md")
    }

    func test_moveCurrentTabRight() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.selectTab(at: 0)  // select /a
        model.moveCurrentTabRight()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent },
                       ["b.md", "a.md", "c.md"])
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    func test_moveTabLeft_atFirst_isNoOp() throws {
        let model = makeModel()
        for n in ["a", "b"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.selectTab(at: 0)
        let before = model.tabs.tabs.map { $0.url?.lastPathComponent }
        model.moveCurrentTabLeft()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent }, before)
    }

    func test_moveTabRight_atLast_isNoOp() throws {
        let model = makeModel()
        for n in ["a", "b"] {
            model.open(url: try writeFile("\(n).md"))
        }
        // Selected = b (last).
        let before = model.tabs.tabs.map { $0.url?.lastPathComponent }
        model.moveCurrentTabRight()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent }, before)
    }

    // MARK: T7 — watcher rotates on tab select

    func test_selectTab_rotatesFileWatcher() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "v1-a")
        let b = try writeFile("b.md", "v1-b")
        model.open(url: a)
        model.open(url: b)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "b.md")

        // Mutate `a` while `b` is selected — no reload should happen on `b`
        // (CRIT-4: watcher events for `a` must not corrupt `b`'s state).
        try "v2-a".write(to: a, atomically: true, encoding: .utf8)
        let preB: String
        if case .loaded(let f) = model.tabs.tabs[0].state { preB = f.contents } else { preB = "" }
        // Note: tabs.tabs[0] is `a`, tabs.tabs[1] is `b`. Check b stays unchanged.
        Thread.sleep(forTimeInterval: 0.2)
        if case .loaded(let f) = model.tabs.tabs[1].state {
            XCTAssertEqual(f.contents, "v1-b")  // /b unchanged
        }
        _ = preB  // silence unused warning if compiler complains

        // Now switch to `a` and reload — should pick up the new contents.
        model.selectTab(at: 0)
        model.reloadCurrentFile()
        if case .loaded(let f) = model.currentState {
            XCTAssertEqual(f.contents, "v2-a")
        } else {
            XCTFail("expected .loaded")
        }
    }

    // MARK: - UI scale (Batch B, commit 2457015)

    func test_uiScale_seeds_from_preferences() {
        let prefs = PreferencesStore(defaults: defaults)
        prefs.uiScale = 1.30
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: prefs
        )
        XCTAssertEqual(model.uiScale, 1.30, accuracy: 0.001)
    }

    func test_uiScale_setter_persists_via_preferences() {
        let prefs = PreferencesStore(defaults: defaults)
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: prefs
        )
        model.uiScale = 1.15
        XCTAssertEqual(prefs.uiScale, 1.15, accuracy: 0.001)
    }

    func test_uiSize_multiplies_base_by_uiScale() {
        let model = makeModel()
        model.uiScale = 1.5
        XCTAssertEqual(model.uiSize(10), 15, accuracy: 0.001)
        XCTAssertEqual(model.uiSize(12), 18, accuracy: 0.001)
    }

    // MARK: - showInvisibleChars (Batch A)

    func test_showInvisibleChars_seeds_and_persists() {
        let prefs = PreferencesStore(defaults: defaults)
        prefs.showInvisibleChars = true
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: prefs
        )
        XCTAssertTrue(model.showInvisibleChars)
        model.toggleShowInvisibleChars()
        XCTAssertFalse(model.showInvisibleChars)
        XCTAssertFalse(prefs.showInvisibleChars,
                       "didSet should write through to preferences")
    }

    // MARK: - Find bar regex flag (Batch B)

    func test_sourceFindIsRegex_defaultsOff() {
        let model = makeModel()
        XCTAssertFalse(model.sourceFindIsRegex)
    }

    func test_sourceFindIsRegex_isWritable() {
        let model = makeModel()
        model.sourceFindIsRegex = true
        XCTAssertTrue(model.sourceFindIsRegex)
    }

    // MARK: - HEX state routing (Batch A, commit d175548)

    /// Picking HEX on a text-loaded tab must request a binary load.
    /// Pre-Batch-A this only fired from `.loaded` state; the new code
    /// also handles `.preview` and `.error`. Verify the loaded path
    /// still works (regression guard).
    func test_setHex_on_loadedText_kicks_binaryLoad() throws {
        let model = makeModel()
        let url = try writeFile("file.txt", "hello world")
        model.open(url: url)
        XCTAssertTrue(isLoaded(model.currentState))
        model.setCurrentViewMode(.hex)
        // The picker reflects the user's pick immediately; the
        // state-swap is async via Task.detached. Spin until the
        // tab's state flips to .binary (cap to keep failures fast).
        let switched = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertTrue(switched, "expected state to flip to .binary after HEX")
        XCTAssertEqual(model.currentViewMode, .hex)
    }

    /// Switching from .hex back to .source must request a text reload.
    func test_setSource_on_binary_kicks_textLoad() throws {
        let model = makeModel()
        let url = try writeFile("file.txt", "hello")
        model.open(url: url)
        model.setCurrentViewMode(.hex)
        _ = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        model.setCurrentViewMode(.source)
        let switched = waitFor(timeout: 2.0) {
            if case .loaded = model.currentState { return true }
            return false
        }
        XCTAssertTrue(switched, "expected state to flip back to .loaded after Source")
        XCTAssertEqual(model.currentViewMode, .source)
    }

    /// Regression for the "HEX is selected but a different file shows
    /// in preview mode after switching" bug. Opening a file with HEX
    /// already current on the tab must kick a binary load for the new
    /// file too.
    func test_openFile_with_hex_active_triggers_binaryLoad_for_newFile() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        model.open(url: a)
        model.setCurrentViewMode(.hex)
        _ = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertEqual(model.currentViewMode, .hex)

        model.open(url: b)
        // We expect the new tab to also end up in .binary because
        // currentViewMode was .hex when openOrReveal carried it across.
        // Picker first reflects the user's mode; the binary load fires
        // asynchronously.
        XCTAssertEqual(model.currentViewMode, .hex)
        let bIsBinary = waitFor(timeout: 2.0) {
            guard model.currentURL?.lastPathComponent == "b.txt" else { return false }
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertTrue(bIsBinary,
                      "HEX must persist across file switch — bug fixed in d175548")
    }

    // MARK: - Bookmark folder support (Batch A item)

    func test_bookmarkTargetURL_prefers_currentFile_over_folder() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "x")
        model.openFolder(tmpDir)
        model.open(url: url)
        XCTAssertEqual(model.bookmarkTargetURL?.lastPathComponent, "a.md")
    }

    func test_bookmarkTargetURL_falls_back_to_folder_when_no_file_open() {
        let model = makeModel()
        model.openFolder(tmpDir)
        XCTAssertEqual(model.bookmarkTargetURL, tmpDir.standardizedFileURL.resolvingSymlinksInPath())
    }

    func test_bookmarkTargetURL_nil_when_neither_set() {
        let model = makeModel()
        XCTAssertNil(model.bookmarkTargetURL)
    }

    // MARK: - Helpers

    /// Synchronously spin the main run loop until `predicate` becomes
    /// true or the timeout elapses. Returns whether it became true.
    /// Used for the async loadBinary path on the main actor.
    private func waitFor(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    private func isLoaded(_ state: DocumentState) -> Bool {
        if case .loaded = state { return true }
        return false
    }
}
