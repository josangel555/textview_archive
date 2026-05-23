import XCTest
@testable import ViewerCore

/// Extra `SearchScope` corner cases.
final class SearchScopeExtendedTests: XCTestCase {

    // MARK: - Resolution with both context fields nil

    func test_resolve_activeFile_bothContextsNil_returnsNil() {
        XCTAssertNil(SearchScopeResolver.resolve(
            .activeFile, activeFile: nil, activeFolder: nil))
    }

    func test_resolve_activeFolder_bothContextsNil_returnsNil() {
        XCTAssertNil(SearchScopeResolver.resolve(
            .activeFolder, activeFile: nil, activeFolder: nil))
    }

    // MARK: - Equatable contract

    func test_scope_equatable_pickedURLDistinguishes() {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        XCTAssertEqual(SearchScope.pickedFile(a), SearchScope.pickedFile(a))
        XCTAssertNotEqual(SearchScope.pickedFile(a), SearchScope.pickedFile(b))
        XCTAssertNotEqual(SearchScope.activeFile, SearchScope.activeFolder)
        XCTAssertNotEqual(SearchScope.activeFile, SearchScope.pickedFile(a))
    }

    // MARK: - needsFolderFallback boundary

    func test_needsFolderFallback_pickedFolder_inFolderMode_noFallback() {
        let url = URL(fileURLWithPath: "/somewhere")
        XCTAssertFalse(SearchScopeResolver.needsFolderFallback(
            scope: .pickedFolder(url),
            modeRequiresFolder: true))
    }

    func test_needsFolderFallback_pickedFile_inFileMode_noFallback() {
        let url = URL(fileURLWithPath: "/somewhere/a.md")
        XCTAssertFalse(SearchScopeResolver.needsFolderFallback(
            scope: .pickedFile(url),
            modeRequiresFolder: false))
    }
}
