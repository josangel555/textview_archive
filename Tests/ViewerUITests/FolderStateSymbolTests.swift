import AppKit
import XCTest
import ViewerKit
@testable import ViewerUI

/// FolderState → SF Symbol mapping (Batch A, commit d175548) and
/// IconCategory palette completeness. Symbol names are an AppKit
/// implicit-API contract: a typo here ships an empty icon, so locking
/// in "every state names a symbol that resolves on this OS" is cheap
/// regression insurance.
final class FolderStateSymbolTests: XCTestCase {

    func test_every_folderState_names_a_valid_SFSymbol() {
        let states: [FolderState] = [.collapsed, .open, .root, .hidden, .locked, .symlink]
        for state in states {
            let symbol = state.symbol
            XCTAssertFalse(symbol.isEmpty, "FolderState \(state) returned empty symbol")
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            XCTAssertNotNil(image,
                            "SF Symbol '\(symbol)' for FolderState.\(state) doesn't resolve")
        }
    }

    func test_folder_symbols_visually_distinguish_each_state() {
        // Different states should not all collapse to the same symbol —
        // that would defeat the icon system. Locked/Open share the
        // 'folder.fill' silhouette and rely on tint (intentional);
        // collapsed/hidden/root/symlink should each be unique.
        let unique: Set<String> = [
            FolderState.collapsed.symbol,
            FolderState.root.symbol,
            FolderState.hidden.symbol,
            FolderState.symlink.symbol,
        ]
        XCTAssertEqual(unique.count, 4,
                       "collapsed/root/hidden/symlink should each pick a unique SF Symbol")
    }

    // MARK: - IconCategory palette

    func test_every_iconCategory_has_a_palette() {
        // Smoke test: each category renders without trapping.
        for cat in IconCategory.allCases {
            let pair = cat.palette
            // Palette pairs are Color values; we can't read RGB without
            // an NSAppearance context. Just make sure we got through.
            _ = pair.background
            _ = pair.foreground
        }
    }
}
