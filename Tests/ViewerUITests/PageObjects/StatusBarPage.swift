import XCTest
import Foundation

/// Page Object for the bottom status bar (`mdv.statusBar`) with a path
/// crumb at `mdv.statusBar.path`.
///
/// The status bar isn't covered by a dedicated live-app test today,
/// but the identifiers exist in the source and are referenced by the
/// MetadataPanel + LSP follow-ups. This is the minimum surface a new
/// test would need.
struct StatusBarPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    var subtree: [String: Any]? { subtree(withIdentifier: "mdv.statusBar") }
    var pathSubtree: [String: Any]? { subtree(withIdentifier: "mdv.statusBar.path") }

    var isVisible: Bool { subtree != nil }

    // MARK: - Assertions

    func assertVisible(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(subtree,
            "Expected mdv.statusBar to be present",
            file: file, line: line)
    }
}
