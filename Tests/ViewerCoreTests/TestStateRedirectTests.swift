import XCTest
@testable import ViewerCore

/// TSK-1288 — under XCTest, the on-disk-state default-dir helpers MUST redirect to
/// a per-process temp dir so HOST tests never read/write the developer's REAL
/// `~/Library/Application Support/MarkdownViewer` state (tests had polluted the real
/// history.json + bloated the real LocalHistory to ~132 MB).
final class TestStateRedirectTests: XCTestCase {

    func test_appSupportBase_redirectsUnderXCTest() throws {
        let base = try XCTUnwrap(TestStateRedirect.appSupportBase(), "redirect must be active under XCTest")
        XCTAssertTrue(base.path.contains("MDVTestState-"),
                      "expected a per-process temp base, got \(base.path)")
        XCTAssertFalse(base.path.contains("Library/Application Support/MarkdownViewer"),
                       "must NOT point at the real app-support dir")
    }

    // TEETH: if the redirect regresses, these return the real ~/Library path.
    func test_storageDefaults_doNotPointAtRealState() {
        let lh = LocalHistoryStore.defaultDirectory().path
        let hs = HistoryStore.defaultStoreURL().path
        XCTAssertTrue(lh.contains("MDVTestState-"),
                      "LocalHistory default must redirect under XCTest, got \(lh)")
        XCTAssertTrue(hs.contains("MDVTestState-"),
                      "history.json default must redirect under XCTest, got \(hs)")
        XCTAssertTrue(lh.hasSuffix("MarkdownViewer/LocalHistory"), "subpath preserved, got \(lh)")
        XCTAssertTrue(hs.hasSuffix("MarkdownViewer/history.json"), "subpath preserved, got \(hs)")
    }

    // markdownViewerDir honors the pre-existing MDV_APP_SUPPORT override (session
    // tests / sandbox), taking precedence over the XCTest auto-redirect.
    func test_markdownViewerDir_honorsAppSupportOverride() {
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDV-override-\(UUID().uuidString)")
        let dir = TestStateRedirect.markdownViewerDir(environment: ["MDV_APP_SUPPORT": custom.path])
        XCTAssertEqual(dir, custom.appendingPathComponent("MarkdownViewer", isDirectory: true),
                       "MDV_APP_SUPPORT must override the redirect, got \(dir.path)")
        let bid = TestStateRedirect.bundleIDDir(environment: ["MDV_APP_SUPPORT": custom.path])
        XCTAssertEqual(bid, custom.appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true),
                       "MDV_APP_SUPPORT must override bundleIDDir too, got \(bid.path)")
    }

    // Slice 2: the other confirmed-polluted stores also redirect under XCTest.
    @MainActor func test_slice2_stores_redirectUnderXCTest() {
        XCTAssertTrue(ScrollMemoryStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "scroll-memory must redirect, got \(ScrollMemoryStore.defaultStoreURL().path)")
        XCTAssertTrue(BookmarksStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "bookmarks must redirect, got \(BookmarksStore.defaultStoreURL().path)")
        XCTAssertTrue(GoToPathHistoryStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "recent-paths must redirect, got \(GoToPathHistoryStore.defaultStoreURL().path)")
        XCTAssertTrue(AuditLog().logURL.path.contains("MDVTestState-"),
                      "audit.jsonl must redirect, got \(AuditLog().logURL.path)")
        XCTAssertTrue(ViewModeLockStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "view-mode-locks must redirect, got \(ViewModeLockStore.defaultStoreURL().path)")
        XCTAssertTrue(LSPTrustStore.defaultStoreURL().path.contains("MDVTestState-"),
                      "lsp-trust must redirect, got \(LSPTrustStore.defaultStoreURL().path)")
        XCTAssertTrue(TerminalFavoritesStore.defaultURL().path.contains("MDVTestState-"),
                      "terminal-favorites must redirect, got \(TerminalFavoritesStore.defaultURL().path)")
        // Slice 4: bundle-id-dir stores (com.markdownviewer.MarkdownViewer) redirect too.
        XCTAssertTrue(PluginRegistry.defaultPluginsDir().path.contains("MDVTestState-"),
                      "plugins must redirect, got \(PluginRegistry.defaultPluginsDir().path)")
        XCTAssertTrue(PluginGrantStore.defaultURL().path.contains("MDVTestState-"),
                      "plugin-grants must redirect, got \(PluginGrantStore.defaultURL().path)")
        XCTAssertTrue(WalkthroughCheckpointStore.defaultDirectory().path.contains("MDVTestState-"),
                      "walkthrough-checkpoints must redirect, got \(WalkthroughCheckpointStore.defaultDirectory().path)")
        XCTAssertTrue(WalkthroughDropTransport.defaultDropDirectory().path.contains("MDVTestState-"),
                      "walkthrough-drop must redirect, got \(WalkthroughDropTransport.defaultDropDirectory().path)")
    }

    /// Structural guard (TSK-1288): no NEW ViewerCore store may compute the real app-support
    /// MarkdownViewer dir without routing through TestStateRedirect (else it pollutes the dev's
    /// real ~/Library state under tests — the bug this whole class fixes). The allowlist is the
    /// KNOWN not-yet-repointed stores; shrink it toward empty as they migrate to
    /// TestStateRedirect.markdownViewerDir(). A brand-new bypasser fails this.
    func test_noNewStoreBypassesTheRedirect() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let dir = root.appendingPathComponent("Sources/ViewerCore")
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("Sources/ViewerCore not reachable from #filePath — path derivation broke"); return
        }
        // Known not-yet-repointed stores (TSK-1288 follow-on batch). NOT actively polluting.
        let allowed: Set<String> = [
            "AppCacheReset.swift", "CLILauncher.swift", "FeedSubscriptionStore.swift",
            "InstanceRegistry.swift", "LSPDiscovery.swift", "ReviewStore.swift",
            "SessionStore.swift", "SnippetStore.swift", "TerminalCommandHistory.swift",
            "ThemeStore.swift", "WalkthroughCatalog.swift", "WalkthroughHistory.swift",
            "WalkthroughStore.swift",
        ]
        var offenders: [String] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let usesAppSupport = text.contains("applicationSupportDirectory")
            let mentionsDir = text.contains("\"MarkdownViewer\"") || text.contains("MarkdownViewer/")
            let routes = text.contains("TestStateRedirect")
            if usesAppSupport, mentionsDir, !routes, !allowed.contains(url.lastPathComponent) {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "NEW app-support store(s) bypass TestStateRedirect — route the default dir through "
            + "TestStateRedirect.markdownViewerDir() so tests don't pollute the dev's real "
            + "~/Library state: \(offenders.sorted())")
    }
}
