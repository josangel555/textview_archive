import XCTest
import Foundation
@testable import ViewerCore

/// TSK-789 — the data behind the Settings "Language servers (LSP)" availability
/// list. The resolver is injected so this is host-testable without shelling out
/// to xcrun/which or depending on which servers happen to be installed.
final class LSPLanguageStatusTests: XCTestCase {

    func test_languageStatuses_reflectTheResolver() {
        // Only Swift "installed" in this fake environment.
        let fakePath = URL(fileURLWithPath: "/opt/fake/sourcekit-lsp")
        let statuses = LSPLanguageRegistry.languageStatuses { lang in
            lang == .swift ? fakePath : nil
        }
        // One status per known LSP language — the list is complete.
        XCTAssertEqual(Set(statuses.map(\.language)), Set(LSPLanguage.allCases),
                       "every LSPLanguage must appear exactly once")

        let swift = statuses.first { $0.language == .swift }
        XCTAssertEqual(swift?.available, true, "Swift resolved → available")
        XCTAssertEqual(swift?.resolvedPath, fakePath.path, "available status carries the binary path")

        for st in statuses where st.language != .swift {
            XCTAssertFalse(st.available, "\(st.language) unresolved → not available")
            XCTAssertNil(st.resolvedPath, "missing server has no path")
        }
    }

    func test_missingServers_haveAnInstallHint_exceptSwift() {
        // Swift's server ships with the toolchain (no install step); the rest
        // must surface an actionable install hint when not found — the point of
        // the Settings section.
        for lang in LSPLanguage.allCases where lang != .swift {
            XCTAssertNotNil(lang.installHint,
                            "\(lang) must offer an install hint for the 'Not found' state")
        }
        XCTAssertNil(LSPLanguage.swift.installHint, "Swift ships with the toolchain")
    }
}
