import XCTest
@testable import ViewerCore

/// BUG-027: SessionStore.defaultDirectory must honor the clean-room env
/// overrides so T4/host session smokes redirect off the user's real
/// `~/Library/Application Support/MarkdownViewer/Sessions` store. (The
/// AppLauncher harness sets `MDV_SESSIONS_DIR` to per-run scratch.)
final class SessionStoreDirOverrideTests: XCTestCase {

    func test_MDV_SESSIONS_DIR_redirectsStoreVerbatim() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dir = SessionStore.defaultDirectory(environment: ["MDV_SESSIONS_DIR": scratch.path])
        XCTAssertEqual(dir.standardizedFileURL.path, scratch.standardizedFileURL.path)
    }

    func test_MDV_APP_SUPPORT_redirectsUnderMarkdownViewerSessions() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = SessionStore.defaultDirectory(environment: ["MDV_APP_SUPPORT": root.path])
        XCTAssertEqual(dir.standardizedFileURL.path,
                       root.appendingPathComponent("MarkdownViewer/Sessions").standardizedFileURL.path)
    }

    func test_noOverride_usesRealApplicationSupport_notScratch() {
        // TEETH: without the override the store falls back to the real
        // Application Support path (the bug is that tests hit THIS).
        let dir = SessionStore.defaultDirectory(environment: [:])
        XCTAssertTrue(dir.path.hasSuffix("MarkdownViewer/Sessions"))
        XCTAssertTrue(dir.path.contains("Application Support"))
    }
}
