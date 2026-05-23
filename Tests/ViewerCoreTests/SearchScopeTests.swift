import XCTest
@testable import ViewerCore

/// Pure-logic tests for the `SearchScope` resolver. No UI, no
/// DocumentModel. Runs on host.
final class SearchScopeTests: XCTestCase {

    // MARK: - resolve

    func test_resolve_activeFile_returnsActiveFile() {
        let file = URL(fileURLWithPath: "/tmp/a.md")
        XCTAssertEqual(
            SearchScopeResolver.resolve(.activeFile, activeFile: file, activeFolder: nil),
            file
        )
    }

    func test_resolve_activeFile_nilWhenNoActiveFile() {
        XCTAssertNil(
            SearchScopeResolver.resolve(
                .activeFile,
                activeFile: nil,
                activeFolder: URL(fileURLWithPath: "/tmp")
            )
        )
    }

    func test_resolve_activeFolder_returnsActiveFolder() {
        let folder = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(
            SearchScopeResolver.resolve(.activeFolder, activeFile: nil, activeFolder: folder),
            folder
        )
    }

    func test_resolve_pickedFile_ignoresAmbientContext() {
        let picked = URL(fileURLWithPath: "/elsewhere/x.md")
        let amb = URL(fileURLWithPath: "/somewhere/y.md")
        XCTAssertEqual(
            SearchScopeResolver.resolve(.pickedFile(picked), activeFile: amb, activeFolder: nil),
            picked
        )
    }

    func test_resolve_pickedFolder_ignoresAmbientContext() {
        let picked = URL(fileURLWithPath: "/elsewhere")
        XCTAssertEqual(
            SearchScopeResolver.resolve(
                .pickedFolder(picked),
                activeFile: nil,
                activeFolder: URL(fileURLWithPath: "/somewhere")
            ),
            picked
        )
    }

    // MARK: - isFolder

    func test_isFolder_classification() {
        XCTAssertFalse(SearchScope.activeFile.isFolder)
        XCTAssertTrue(SearchScope.activeFolder.isFolder)
        XCTAssertFalse(SearchScope.pickedFile(URL(fileURLWithPath: "/x")).isFolder)
        XCTAssertTrue(SearchScope.pickedFolder(URL(fileURLWithPath: "/x")).isFolder)
    }

    // MARK: - needsFolderFallback

    func test_needsFolderFallback_fileScopeUnderFolderMode() {
        XCTAssertTrue(
            SearchScopeResolver.needsFolderFallback(
                scope: .activeFile,
                modeRequiresFolder: true
            )
        )
    }

    func test_needsFolderFallback_folderScopeUnderFolderMode_noFallback() {
        XCTAssertFalse(
            SearchScopeResolver.needsFolderFallback(
                scope: .activeFolder,
                modeRequiresFolder: true
            )
        )
    }

    func test_needsFolderFallback_fileScopeUnderFileMode_noFallback() {
        XCTAssertFalse(
            SearchScopeResolver.needsFolderFallback(
                scope: .activeFile,
                modeRequiresFolder: false
            )
        )
    }

    func test_needsFolderFallback_pickedFileUnderFolderMode_fallback() {
        let picked = URL(fileURLWithPath: "/somewhere/x.md")
        XCTAssertTrue(
            SearchScopeResolver.needsFolderFallback(
                scope: .pickedFile(picked),
                modeRequiresFolder: true
            )
        )
    }
}
