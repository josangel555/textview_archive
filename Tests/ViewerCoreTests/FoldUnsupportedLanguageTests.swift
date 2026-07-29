import XCTest
import RustCore
import ViewerKit
@testable import ViewerCore

/// TSK-1609 (owner 2026-07-26, reported log line:
/// `fold DEGRADED (twin deleted): decode("fold_regions: unsupported language
/// 'plain'")`) — a language with no fold engine is a NORMAL answer, not a
/// bridge fault.
///
/// Plain text can't have syntax folds, yet every fold pass in a plain-text
/// buffer threw, degraded, and logged an alarm — false noise that also buried
/// real bridge faults, plus a wasted FFI round-trip per text change.
final class FoldUnsupportedLanguageTests: XCTestCase {

    func test_plainText_hasNoFoldSupport_soNoFFICallIsMade() {
        XCTAssertTrue(RustFoldAdapter.hasNoFoldSupport(.plainText),
                      "plain text cannot have syntax folds")
        // The production entry short-circuits — quiet, empty, no alarm.
        let folds = RustFoldAdapter.foldRegions(
            "just some notes\n  indented\n    deeper\n", language: .plainText)
        XCTAssertTrue(folds.isEmpty, "plain text yields no fold regions")
    }

    func test_realLanguagesStillGoThroughTheEngine() {
        XCTAssertFalse(RustFoldAdapter.hasNoFoldSupport(.swift))
        XCTAssertFalse(RustFoldAdapter.hasNoFoldSupport(.json))
        // A foldable document must still produce regions (the engine is live).
        let swiftSrc = """
        struct A {
            func b() {
                let c = 1
                print(c)
            }
        }
        """
        let folds = RustFoldAdapter.foldRegions(swiftSrc, language: .swift)
        XCTAssertFalse(folds.isEmpty,
                       "the rust fold engine must still run for supported languages")
    }

    /// The classifier that keeps "no fold support" off the DEGRADED path —
    /// pinned so a reworded client message can't silently restore the noise.
    func test_unsupportedLanguageErrorIsClassified_notTreatedAsBridgeFault() {
        let unsupported = CoreError.decode("fold_regions: unsupported language 'plain'")
        XCTAssertTrue(RustFoldAdapter.isUnsupportedLanguage(unsupported))

        // A REAL fault must NOT be swallowed by that classifier.
        for real in [
            CoreError.decode("empty fold_regions response frame"),
            CoreError.decode("missing 'regions'"),
        ] {
            XCTAssertFalse(RustFoldAdapter.isUnsupportedLanguage(real),
                           "a genuine bridge fault must still degrade loudly: \(real)")
        }
    }
}
