import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1489 — host tests for the new-tab omnibox DISPATCH (resolveOmniInput).
/// The classification table itself is pinned by OmniResolverTests; these pin the
/// routing to the model's in-app actions. The `.openURL`/`.gitRemote` branch is
/// deliberately NOT exercised here — it calls `NSWorkspace.open`, which would
/// launch a real browser during the test; its classification is covered by
/// OmniResolverTests and the dispatch is a one-line hand-off.
@MainActor
final class DocumentModelOmniTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        let defaults = UserDefaults(suiteName: "OmniTests-\(UUID().uuidString)")!
        return DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    func test_searchQuery_routesToCrossFileSearch() {
        let model = makeModel()
        let action = model.resolveOmniInput("needle in the haystack")
        XCTAssertEqual(action, .search("needle in the haystack"))
        XCTAssertEqual(model.crossSearchQuery, "needle in the haystack",
                       "the query seeds the SAME cross-file engine the panel uses")
        XCTAssertTrue(model.isCrossSearchPresented, "the search overlay surfaces")
    }

    func test_emptyInput_isANoop() {
        let model = makeModel()
        let action = model.resolveOmniInput("   \n ")
        XCTAssertEqual(action, .empty)
        XCTAssertFalse(model.isCrossSearchPresented, "blank input opens nothing")
    }

    func test_existingFolderPath_classifiesAsOpenPathDirectory() {
        let model = makeModel()
        // tmp is a real directory → open-path (directory), not a search.
        let action = model.resolveOmniInput(tmp.path)
        XCTAssertEqual(action, .openPath(tmp.path, isDirectory: true))
        XCTAssertNotNil(model.sidebar.rootURL, "opening a folder sets the sidebar root")
    }

    func test_pathShapedMiss_staysAnOpenPath_notASearch() {
        let model = makeModel()
        // A path-shaped string that doesn't exist must NOT silently become a
        // search (OmniResolver contract) — the caller surfaces "no such file".
        let action = model.resolveOmniInput("/no/such/place/at/all.txt")
        guard case .openPath(_, let isDir) = action else {
            return XCTFail("expected .openPath; got \(action)")
        }
        XCTAssertFalse(isDir)
        XCTAssertFalse(model.isCrossSearchPresented, "a missing path is not a search")
    }

    // MARK: - TSK-1572: launchpad sections + git-clone plan bridge

    func test_launchpadSections_splitsRecentsIntoFilesAndFolders() {
        let model = makeModel()
        model.recents = [
            HistoryEntry(url: URL(fileURLWithPath: "/x/notes.md"), kind: .file, lastOpenedAt: Date()),
            HistoryEntry(url: URL(fileURLWithPath: "/x/proj"), kind: .folder, lastOpenedAt: Date()),
        ]
        let sections = model.launchpadSections()
        XCTAssertEqual(sections.map(\.title), ["Recent Files", "Recent Folders"])
        XCTAssertEqual(sections[0].items.map(\.title), ["notes.md"])
        XCTAssertEqual(sections[0].items.map(\.isDirectory), [false])
        XCTAssertEqual(sections[1].items.map(\.title), ["proj"])
        XCTAssertEqual(sections[1].items.map(\.isDirectory), [true])
    }

    func test_gitClonePlan_targetsWorkspaceParent_elseHome() {
        let model = makeModel()
        // No workspace root yet → clone beside HOME.
        let home = model.gitClonePlan(forRemote: "github.com/o/repo")
        XCTAssertEqual(home?.repoName, "repo")
        XCTAssertEqual(home?.targetDirectory, "\(NSHomeDirectory())/repo")
        // Open a workspace folder → clone lands beside it (its parent).
        model.openPath(tmp)
        let beside = model.gitClonePlan(forRemote: "git@github.com:o/thing.git")
        XCTAssertEqual(beside?.repoName, "thing")
        XCTAssertEqual(beside?.targetDirectory,
                       "\(tmp.deletingLastPathComponent().path)/thing")
    }

    func test_gitClonePlan_nilForNonRepo() {
        XCTAssertNil(makeModel().gitClonePlan(forRemote: "github.com/"))
    }
}
