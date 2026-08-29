import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// Teeth for the Local-History save-path WIRING (TSK-1103): saving an edited
/// text tab records a version in the store, and the owner policy
/// (secret-exclusion, text-only) gates it — so a regression that unwires the
/// snapshot, or that starts retaining `.env` files, fails the HOST gate.
///
/// The snapshot fires on a detached task off the save, so each assertion polls
/// the store briefly.
@MainActor
final class LocalHistorySaveWiringTests: XCTestCase {

    private var tmpDir: URL!
    private var histDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: LocalHistoryStore!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LHSaveWiring-\(UUID().uuidString)")
        histDir = tmpDir.appendingPathComponent("hist")
        try FileManager.default.createDirectory(at: histDir, withIntermediateDirectories: true)
        suiteName = "LHSaveWiring-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Toggle-wired (TSK-1103 merge): gating now lives in the store, so the
        // injected store reads the same suite the toggle test flips.
        store = LocalHistoryStore(
            directory: histDir,
            isEnabled: { [name = suiteName!] in
                LocalHistoryPolicy.isEnabled(defaults: UserDefaults(suiteName: name) ?? .standard)
            })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults),
            localHistory: store)
    }

    /// Owner 2026-08-29 ("Local History of an externally modified file?"):
    /// adopting an external rewrite via the reload path snapshots the content
    /// it REPLACES — so a file that was opened but never saved in-app still
    /// has its pre-rewrite state recoverable. Extends the 2026-07-28
    /// preservation directive to the silent clean-tab adoption.
    func test_externalReload_snapshotsTheReplacedContent() throws {
        let model = makeModel()
        let url = try writeFile("watched.md", "original opened content")
        model.open(url: url)
        XCTAssertTrue(model.localHistoryStore.versions(
            for: url.standardizedFileURL.path).isEmpty,
            "precondition: opening alone records nothing")

        // The external tool rewrites the file; the watcher path adopts it.
        try "external tool overwrote this".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.reloadFileFromDisk(url))

        let versions = model.localHistoryStore.versions(for: url.standardizedFileURL.path)
        XCTAssertEqual(versions.count, 1,
            "the replaced content must land in Local History")
        XCTAssertEqual(
            model.localHistoryStore.contentString(
                of: versions[0], for: url.standardizedFileURL.path),
            "original opened content",
            "the snapshot is the PRE-rewrite state — the external write's casualty")
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "before") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Poll the store until `path` has ≥`count` versions, or fail.
    private func awaitVersions(forPath path: String, atLeast count: Int,
                               file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if store.versions(for: path).count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("store did not reach \(count) version(s) for \(path); has \(store.versions(for: path).count)",
                file: file, line: line)
    }

    func test_saveEditedTextTab_recordsLocalHistoryVersion() async throws {
        let model = makeModel()
        let url = try writeFile("notes.md", "before")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("after edit", forTabID: id)
        XCTAssertTrue(model.saveEditor(forTabID: id))

        let path = url.standardizedFileURL.path
        await awaitVersions(forPath: path, atLeast: 1)
        let versions = store.versions(for: path)
        XCTAssertEqual(store.contentString(of: versions[0], for: path), "after edit",
                       "the saved revision content must be snapshotted")
    }

    func test_savingSecretLikeFile_isNotSnapshotted() async throws {
        let model = makeModel()
        let url = try writeFile(".env", "OLD=1")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("SECRET_TOKEN=abc123", forTabID: id)
        XCTAssertTrue(model.saveEditor(forTabID: id))

        // Give the (suppressed) snapshot task time to NOT run.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let path = url.standardizedFileURL.path
        XCTAssertTrue(store.versions(for: path).isEmpty,
                      ".env content must NEVER be retained in Local History")
    }

    func test_disabledByEnvOrPref_doesNotSnapshot() async throws {
        defaults.set(false, forKey: LocalHistoryPolicy.enabledKey)
        let model = makeModel()
        let url = try writeFile("x.txt", "a")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("b", forTabID: id)
        XCTAssertTrue(model.saveEditor(forTabID: id))

        try? await Task.sleep(nanoseconds: 100_000_000)
        let path = url.standardizedFileURL.path
        XCTAssertTrue(store.versions(for: path).isEmpty,
                      "Local History disabled → no snapshot")
    }

    func test_canShowLocalHistory_requiresFileURL() throws {
        let model = makeModel()
        let url = try writeFile("y.txt", "z")
        model.open(url: url)
        let id = model.tabs.selected!.id
        XCTAssertTrue(model.canShowLocalHistory(forTabID: id))
        XCTAssertFalse(model.canShowLocalHistory(forTabID: UUID()),
                       "unknown tab id → no Local History")
    }

    func test_openLocalHistory_opensHostedTab() throws {
        let model = makeModel()
        let url = try writeFile("h.md", "content")
        model.open(url: url)
        let id = model.tabs.selected!.id
        let beforeCount = model.tabs.tabs.count
        model.openLocalHistory(forTabID: id)
        XCTAssertEqual(model.tabs.tabs.count, beforeCount + 1,
                       "openLocalHistory must add a hosted view tab")
        // The new tab is a hosted view titled "History: …".
        XCTAssertTrue(model.tabs.tabs.contains {
            if case .hostedView(_, let title) = $0.state { return title.contains("History:") }
            return false
        })
    }
}
