import XCTest
import Foundation

/// Page Object for the ⇧⌘G "Go to file or folder" overlay
/// (`mdv.goto.panel`). Wraps the panel/field/button identifiers
/// declared at the top of `Sources/ViewerUI/GoToPathPrompt.swift`.
///
/// Visibility is read from the model (`isGoToPathPresented`), which is
/// authoritative even when the SwiftUI overlay's a11y identifier
/// doesn't propagate to the realised NSView. The error-text accessor
/// reads from `dump.model.lastGoToError` (populated by the
/// `goto-commit` script verb's call to `DocumentModel.commitGoToPath`)
/// rather than chasing the SwiftUI `@State` error inside the view,
/// which the script runner can't reach.
struct GoToPathPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    /// Whether the prompt is currently presented. Authoritative —
    /// reads `model.isGoToPathPresented`.
    var isPresented: Bool {
        (model["isGoToPathPresented"] as? Bool) ?? false
    }

    /// Subtree rooted at `mdv.goto.panel`. May be nil even when
    /// `isPresented` is true if the SwiftUI a11y id didn't propagate;
    /// `assertPresented()` uses the model flag so callers don't have
    /// to disambiguate.
    var panelSubtree: [String: Any]? { subtree(withIdentifier: "mdv.goto.panel") }

    var fieldSubtree: [String: Any]? { subtree(withIdentifier: "mdv.goto.field") }
    var openButtonSubtree: [String: Any]? { subtree(withIdentifier: "mdv.goto.openButton") }
    var openNewSessionButtonSubtree: [String: Any]? {
        subtree(withIdentifier: "mdv.goto.openNewSessionButton")
    }
    var cancelButtonSubtree: [String: Any]? { subtree(withIdentifier: "mdv.goto.cancelButton") }
    var historyHintSubtree: [String: Any]? { subtree(withIdentifier: "mdv.goto.historyHint") }

    /// Last error from a model-level commit (`DocumentModel.commitGoToPath`).
    /// Empty string when the previous commit succeeded or no commit
    /// has run yet.
    var lastError: String {
        (model["lastGoToError"] as? String) ?? ""
    }

    // MARK: - Assertions

    func assertPresented(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(isPresented,
            "Expected Go-to-path prompt to be presented, isGoToPathPresented=false",
            file: file, line: line)
    }

    func assertDismissed(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(isPresented,
            "Expected Go-to-path prompt to be dismissed, isGoToPathPresented=true",
            file: file, line: line)
    }

    func assertNoError(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lastError, "",
            "Expected no lastGoToError, got '\(lastError)'",
            file: file, line: line)
    }

    func assertError(
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(lastError.contains(needle),
            "Expected lastGoToError to contain '\(needle)', got '\(lastError)'",
            file: file, line: line)
    }
}
