import XCTest
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// Tests for `DocumentModel.languageOverrides` — the per-tab manual
/// language picker added in commit 332521e.
///
/// Contract:
///   - `effectiveLanguage(forTabID:url:)` returns the auto-detected
///     language when no override is set.
///   - `setCurrentLanguage(_:)` stores an override keyed by the
///     selected tab's UUID.
///   - Setting the override to the auto-detected language clears it
///     (so subsequent renames still pick up the new natural type).
///   - `hasLanguageOverride` reflects the current tab's state.
///   - Two tabs of the same file have independent overrides (keyed
///     by Tab.id, not URL).
@MainActor
final class DocumentModelLanguageOverrideTests: XCTestCase {

    private var tmpRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    private var bookmarksStoreURL: URL!

    override func setUp() async throws {
        // No super.setUp — @MainActor strict-concurrency.
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelLanguageOverrideTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        suiteName = "DocumentModelLanguageOverrideTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpRoot.appendingPathComponent("history.json")
        bookmarksStoreURL = tmpRoot.appendingPathComponent("bookmarks.json")
    }

    override func tearDown() async throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            bookmarks: BookmarksStore(storeURL: bookmarksStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "hi\n") throws -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Auto-detect baseline

    func test_effectiveLanguage_noOverride_returnsAutoDetected() throws {
        let m = makeModel()
        let url = try writeFile("config.json", "{}")
        m.open(url: url)
        let id = m.tabs.selected!.id
        XCTAssertEqual(m.effectiveLanguage(forTabID: id, url: url), .json)
    }

    func test_hasLanguageOverride_falseByDefault() throws {
        let m = makeModel()
        let url = try writeFile("a.txt")
        m.open(url: url)
        XCTAssertFalse(m.hasLanguageOverride)
    }

    // MARK: - Set / clear

    func test_setCurrentLanguage_storesOverride() throws {
        let m = makeModel()
        // .txt auto-detects as plainText. Force it to JSON.
        let url = try writeFile("notes.txt", "{\"a\": 1}")
        m.open(url: url)
        let id = m.tabs.selected!.id
        XCTAssertEqual(m.effectiveLanguage(forTabID: id, url: url), .plainText)

        m.setCurrentLanguage(.json)
        XCTAssertEqual(m.effectiveLanguage(forTabID: id, url: url), .json)
        XCTAssertTrue(m.hasLanguageOverride)
    }

    func test_setCurrentLanguage_clearsWhenSetToAutoDetected() throws {
        // The "clear" path: passing the natural language drops the
        // override so a subsequent rename still works as expected.
        let m = makeModel()
        let url = try writeFile("data.json", "{}")
        m.open(url: url)
        let id = m.tabs.selected!.id

        // Override to swift.
        m.setCurrentLanguage(.swift)
        XCTAssertTrue(m.hasLanguageOverride)
        XCTAssertEqual(m.effectiveLanguage(forTabID: id, url: url), .swift)

        // Set back to the auto-detected value (.json) — should clear.
        m.setCurrentLanguage(.json)
        XCTAssertFalse(m.hasLanguageOverride)
        XCTAssertEqual(m.effectiveLanguage(forTabID: id, url: url), .json)
    }

    // MARK: - Per-tab isolation

    func test_overrideIsPerTab_notPerURL() throws {
        // Open the same file in two tabs. Override on one must NOT
        // bleed into the other.
        let m = makeModel()
        let url = try writeFile("twice.txt")
        m.open(url: url)
        let firstID = m.tabs.selected!.id

        m.openInNewTab(url)
        let secondID = m.tabs.selected!.id
        XCTAssertNotEqual(firstID, secondID,
                          "openInNewTab must produce a fresh Tab.id")

        // Override the active (second) tab to JSON. The first tab
        // must stay on its auto-detected plainText.
        m.setCurrentLanguage(.json)
        XCTAssertEqual(m.effectiveLanguage(forTabID: secondID, url: url), .json)
        XCTAssertEqual(m.effectiveLanguage(forTabID: firstID, url: url), .plainText)
    }

    // MARK: - currentEffectiveLanguage (TSK-753 — the Language Mode menu checkmark)

    func test_currentEffectiveLanguage_nilWhenNoTab_andTracksDetectThenOverride() throws {
        let m = makeModel()
        XCTAssertNil(m.currentEffectiveLanguage,
                     "no tab open ⇒ nil (the menu shows a disabled 'No file open')")

        let url = try writeFile("config.json", "{}")
        m.open(url: url)
        XCTAssertEqual(m.currentEffectiveLanguage, .json,
                       "open .json ⇒ the Language Mode menu checkmarks JSON (auto-detected)")

        m.setCurrentLanguage(.swift)
        XCTAssertEqual(m.currentEffectiveLanguage, .swift,
                       "after an override the checkmark follows it")
    }
}
