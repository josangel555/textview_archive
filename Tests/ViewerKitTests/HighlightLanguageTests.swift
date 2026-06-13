import XCTest
import Foundation
@testable import ViewerKit

/// TSK-790 — the data behind the Settings "Supported languages" section:
/// `fileExtensions` (lang→exts) and `supportedForDisplay` (the listed set).
/// The round-trip test is the load-bearing guard — it keeps `fileExtensions`
/// in lock-step with `detect(from:)` so the Settings list can't claim an
/// extension the detector doesn't actually route.
final class HighlightLanguageTests: XCTestCase {

    func test_fileExtensions_roundTripThroughDetect() {
        for lang in HighlightLanguage.allCases {
            for ext in lang.fileExtensions {
                let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
                XCTAssertEqual(
                    HighlightLanguage.detect(from: url), lang,
                    "extension '.\(ext)' is listed under \(lang.displayName) but detect() routes it elsewhere — fileExtensions drifted from detect(from:)")
            }
        }
    }

    func test_supportedForDisplay_excludesPlainText_andIsSortedByName() {
        let listed = HighlightLanguage.supportedForDisplay
        XCTAssertFalse(listed.contains(.plainText),
                       "Plain Text is the no-highlight fallback, not a 'supported language'")
        XCTAssertEqual(listed.count, HighlightLanguage.allCases.count - 1,
                       "every real grammar is listed (allCases minus plainText)")
        let names = listed.map(\.displayName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                       "the Settings list is alphabetised by display name")
    }

    func test_everyRealGrammarHasAtLeastOneExtension() {
        for lang in HighlightLanguage.supportedForDisplay {
            XCTAssertFalse(lang.fileExtensions.isEmpty,
                           "\(lang.displayName) is listed as supported but maps from no file extension")
        }
    }
}
