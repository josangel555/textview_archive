import XCTest
import Foundation

/// L4 live-app coverage for the ⇧⌘G Go-to-path prompt
/// (`Sources/ViewerUI/GoToPathPrompt.swift`).
///
/// The script runner cannot type into the prompt's local `@State`
/// TextField, so the validation/open paths are exercised through the
/// `goto-commit` and `goto-commit-new-session` script verbs which
/// call `DocumentModel.commitGoToPath(_:newSession:)` (the headless
/// mirror of `GoToPathPrompt.submit`). That method populates the
/// model-side `lastGoToError` field surfaced by `GoToPathPage`.
@MainActor
final class GoToPathUITests: MultiScenarioTestCase {

    override class var harnessLabel: String { "GoToPathUI" }
    override class var defaultScenarioTimeout: TimeInterval { 20 }

    private func writeFixture() throws -> URL {
        try harness.writeFile("seed.md", "# seed\n")
    }

    // MARK: - Tests

    func test_showAndDismissLifecycle() throws {
        let seed = try writeFixture()
        try runScenarios([
            // `show-goto` flips isGoToPathPresented = true; the
            // overlay container appears in the contentView tree.
            Scenario(
                name: "shows-on-script-verb",
                argFile: seed,
                script: """
                    show-goto
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 1, file: file, line: line)
                let page = Pages(dump: dumps[0]).goToPath
                page.assertPresented(file: file, line: line)
                page.assertNoError(file: file, line: line)
            },

            // `dismiss-goto` flips isGoToPathPresented = false; the
            // overlay leaves the tree (and the model-side error
            // mirror clears).
            Scenario(
                name: "dismisses-on-cancel-script-verb",
                argFile: seed,
                script: """
                    show-goto
                    dismiss-goto
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let shown = Pages(dump: dumps[0]).goToPath
                let dismissed = Pages(dump: dumps[1]).goToPath
                shown.assertPresented(file: file, line: line)
                dismissed.assertDismissed(file: file, line: line)
                dismissed.assertNoError(file: file, line: line)
            },
        ])
    }

    func test_validPathOpensFile() throws {
        let seed = try writeFixture()
        let target = try harness.writeFile("target/file.md", "# target\n")

        try runScenarios([
            // Happy path: a valid absolute path is opened via the
            // model's commit method, dismisses the prompt, and shows
            // up as the current tab (window title carries the
            // filename).
            Scenario(
                name: "valid-absolute-path-opens-file",
                argFile: seed,
                script: """
                    show-goto
                    goto-commit \(target.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let presented = Pages(dump: dumps[0])
                let committed = Pages(dump: dumps[1])
                presented.goToPath.assertPresented(file: file, line: line)
                committed.goToPath.assertDismissed(file: file, line: line)
                committed.goToPath.assertNoError(file: file, line: line)
                // The tab system tracks the opened URL; the window
                // title is the most stable proxy that the open
                // actually landed on the right file.
                committed.tabBar.assertActiveTab(named: "file.md",
                                                 file: file, line: line)
            },

            // The `goto-commit` verb works even when the prompt
            // wasn't explicitly shown first — the model method is
            // idempotent on the presented flag (clears it on
            // success). This guards against the "prompt was already
            // open from another shortcut" path.
            Scenario(
                name: "commit-without-explicit-show",
                argFile: seed,
                script: """
                    goto-commit \(target.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 1, file: file, line: line)
                let page = Pages(dump: dumps[0])
                page.goToPath.assertDismissed(file: file, line: line)
                page.goToPath.assertNoError(file: file, line: line)
                page.tabBar.assertActiveTab(named: "file.md",
                                            file: file, line: line)
            },
        ])
    }

    func test_invalidPathProducesError() throws {
        let seed = try writeFixture()

        try runScenarios([
            // notFound: an absolute path that doesn't exist surfaces
            // the user-facing error string and KEEPS the prompt open
            // (the contract of GoToPathPrompt — user gets a chance
            // to correct).
            Scenario(
                name: "non-existent-path-shows-error",
                argFile: seed,
                script: """
                    show-goto
                    goto-commit /var/empty/no-such-mdv-file-XYZ123.md
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let after = Pages(dump: dumps[1]).goToPath
                after.assertPresented(file: file, line: line)
                after.assertError(contains: "No file or folder",
                                  file: file, line: line)
            },

            // relative: paths must start with `/` or `~` per the
            // GoToPathExpansion contract. The error message is
            // distinct so users learn the rule.
            Scenario(
                name: "relative-path-shows-error",
                argFile: seed,
                script: """
                    show-goto
                    goto-commit ./not-absolute.md
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let after = Pages(dump: dumps[1]).goToPath
                after.assertPresented(file: file, line: line)
                after.assertError(contains: "absolute",
                                  file: file, line: line)
            },
        ])
    }
}
