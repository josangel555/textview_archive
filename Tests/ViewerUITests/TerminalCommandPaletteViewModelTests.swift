import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1176 — the Terminal Command Palette controller. Pins the unified favorites-first
/// deduped results, query filtering, and wrapping keyboard selection over the host-built
/// search models (TerminalCommandSearch.unified). The SwiftUI panel is the render companion.
@MainActor
final class TerminalCommandPaletteViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPaletteVMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private func makeStores() -> (TerminalFavoritesStore, TerminalCommandHistory) {
        (TerminalFavoritesStore(storeURL: tmpDir.appendingPathComponent("fav.json")),
         TerminalCommandHistory(storeURL: tmpDir.appendingPathComponent("hist.json")))
    }

    func test_unified_favoritesFirst_deduped() {
        let (fav, hist) = makeStores()
        _ = fav.add(command: "git status", title: "Status")
        _ = hist.record("npm test")
        _ = hist.record("git status")   // also a favorite → must dedup
        let vm = TerminalCommandPaletteViewModel(favorites: fav, history: hist)
        XCTAssertFalse(vm.results.isEmpty, "empty query opens the full list")
        XCTAssertEqual(vm.results.first?.isFavorite, true, "favorites come first")
        XCTAssertEqual(vm.results.filter { $0.command == "git status" }.count, 1, "deduped")
    }

    func test_query_filters_andSelectedCommand() {
        let (fav, hist) = makeStores()
        _ = hist.record("npm test")
        _ = hist.record("git status")
        let vm = TerminalCommandPaletteViewModel(favorites: fav, history: hist)
        vm.query = "npm"
        XCTAssertTrue(vm.results.allSatisfy { $0.command.contains("npm") }, "filtered to npm")
        XCTAssertEqual(vm.selectedCommand, "npm test")
    }

    func test_moveSelection_wraps() {
        let (fav, hist) = makeStores()
        _ = hist.record("alpha")
        _ = hist.record("bravo")
        let vm = TerminalCommandPaletteViewModel(favorites: fav, history: hist)
        XCTAssertGreaterThanOrEqual(vm.results.count, 2)
        XCTAssertEqual(vm.selectedIndex, 0)
        vm.moveSelection(1); XCTAssertEqual(vm.selectedIndex, 1)
        vm.moveSelection(1); XCTAssertEqual(vm.selectedIndex, 0, "wraps forward")
        vm.moveSelection(-1); XCTAssertEqual(vm.selectedIndex, 1, "wraps back")
    }
}
