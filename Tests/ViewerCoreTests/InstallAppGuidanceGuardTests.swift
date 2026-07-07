import XCTest

/// TSK-1498 — install-app.sh guidance must name the app by its USER-FACING
/// name, "TextView", never the legacy "MarkdownViewer" token.
///
/// The app's on-disk bundle, CFBundleName and CFBundleDisplayName are all
/// "TextView"; only the bundle IDENTIFIER (`com.markdownviewer.MarkdownViewer`)
/// and the executable keep the legacy "MarkdownViewer" token — neither of
/// which a user ever types or reads. Guidance that told the user to Spotlight
/// "MarkdownViewer" or open "/Applications/MarkdownViewer.app" pointed at a
/// bundle that does not exist (it installs TextView.app).
///
/// This is a host-safe script-guard test (same shape as `VMSmokePathGuardTests`
/// / `CcacheWrapperScriptTests`): it reads the committed script and asserts the
/// user-facing `echo` guidance, so a regression to the wrong name fails the
/// merge gate with no VM/live dependency.
final class InstallAppGuidanceGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ViewerCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    private static let script = repoRoot.appendingPathComponent("scripts/install-app.sh")

    private func scriptLines() throws -> [String] {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    /// The user-facing guidance is emitted via `echo`. NO such line may name
    /// the legacy "MarkdownViewer" token — that is precisely the bug: the
    /// guidance pointed the user at an app name that is never shown anywhere.
    func test_noEchoGuidanceLineNamesLegacyApp() throws {
        let offenders = try scriptLines().enumerated().filter { _, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("echo ") && line.contains("MarkdownViewer")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "install-app.sh has \(offenders.count) user-facing echo line(s) still naming " +
            "the legacy 'MarkdownViewer' app (users see 'TextView'): " +
            offenders.map { "L\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: " | "))
    }

    /// The corrected guidance must actively point users at "TextView" for the
    /// three discovery paths the script advertises (Spotlight / Finder bundle /
    /// Open With).
    func test_guidanceNamesTextViewForEveryDiscoveryPath() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        XCTAssertTrue(text.contains("type 'TextView'"),
                      "Spotlight guidance must tell the user to type 'TextView'")
        XCTAssertTrue(text.contains("/Applications/TextView.app"),
                      "Finder guidance must reference /Applications/TextView.app")
        XCTAssertTrue(text.contains("Open With → TextView"),
                      "Open-With guidance must name TextView")
    }

    /// The bundle IDENTIFIER legitimately keeps the legacy token — this pins
    /// that we did not over-correct the `duti` default-handler registration
    /// (which must stay `com.markdownviewer.MarkdownViewer`).
    func test_bundleIdentifierUnchanged() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        XCTAssertTrue(text.contains("com.markdownviewer.MarkdownViewer"),
                      "the duti default-handler UTI registration must keep the real bundle id")
    }
}
