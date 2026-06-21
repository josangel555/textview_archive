import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1122 — teeth for the folder-stats card's treemap launch: the resolved
/// folder must match the card's scope (whole-repo → root, subdir → subfolder).
/// The "Show Treemap" button hands this to the host-tested showFolderTreemap().
@MainActor
final class FolderStatsModelTests: XCTestCase {

    func test_treemapFolder_resolvesScope() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let cache = RepoStatsCache()
        let repoModel = FolderStatsModel(repoRoot: root, scope: .repo, cache: cache, title: "t")
        XCTAssertEqual(repoModel.treemapFolder, root, "repo scope → root")

        let folderModel = FolderStatsModel(
            repoRoot: root, scope: .folder(relativePath: "src/app"), cache: cache, title: "t")
        XCTAssertEqual(folderModel.treemapFolder, root.appendingPathComponent("src/app"),
                       "folder scope → subfolder")
    }
}
