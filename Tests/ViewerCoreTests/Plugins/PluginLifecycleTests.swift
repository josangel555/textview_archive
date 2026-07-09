import XCTest
@testable import ViewerCore

/// TSK-1478 — install/remove lifecycle round-trips on temp dirs (the
/// ticket's validate bar; enable/disable/grants are the registry's, tested
/// in PluginRegistryTests). @MainActor because the full-lifecycle test
/// drives the real (MainActor-isolated) PluginRegistry.
@MainActor
final class PluginLifecycleTests: XCTestCase {

    private var pluginsDir: URL!
    private var staging: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-lifecycle-\(UUID().uuidString)")
        pluginsDir = base.appendingPathComponent("Plugins")
        staging = base.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: pluginsDir.deletingLastPathComponent())
    }

    /// A minimal valid plugin folder in staging (the "downloaded" source).
    private func stagePlugin(folderName: String, id: String,
                             manifest: String? = nil) throws -> URL {
        let folder = staging.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = manifest ?? #"""
        {
          "id": "\#(id)", "name": "T", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": [], "contributes": []
        }
        """#
        try json.write(to: folder.appendingPathComponent("plugin.json"),
                       atomically: true, encoding: .utf8)
        try "payload".write(to: folder.appendingPathComponent("data.txt"),
                            atomically: true, encoding: .utf8)
        return folder
    }

    func test_install_copiesValidatedPlugin() throws {
        let src = try stagePlugin(folderName: "ok-plugin", id: "com.t.ok")
        let outcome = PluginLifecycle.install(from: src, into: pluginsDir)
        guard case .installed(let id, let folder) = outcome else {
            return XCTFail("expected installed, got \(outcome)")
        }
        XCTAssertEqual(id, "com.t.ok")
        // The whole folder (payload included) landed in the plugins dir.
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: folder)
                .appendingPathComponent("data.txt"), encoding: .utf8),
            "payload")
    }

    func test_install_refusesInvalid_beforeAnyCopy() throws {
        // No plugin.json at all.
        let bare = staging.appendingPathComponent("no-manifest")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        guard case .refusedInvalid = PluginLifecycle.install(from: bare, into: pluginsDir) else {
            return XCTFail("missing manifest must refuse")
        }
        // Unparseable manifest.
        let broken = try stagePlugin(folderName: "broken", id: "x", manifest: "{ not json")
        guard case .refusedInvalid = PluginLifecycle.install(from: broken, into: pluginsDir) else {
            return XCTFail("bad JSON must refuse")
        }
        // Unsupported manifestVersion.
        let v9 = try stagePlugin(folderName: "v9", id: "com.t.v9", manifest: #"""
        {"id":"com.t.v9","name":"T","version":"1.0.0","author":{"name":"t"},
         "hostVersion":"0","manifestVersion":9,"capabilities":[],"contributes":[]}
        """#)
        guard case .refusedInvalid = PluginLifecycle.install(from: v9, into: pluginsDir) else {
            return XCTFail("future manifestVersion must refuse")
        }
        // NOTHING was copied by any refusal.
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsDir.path),
                       "no copy may happen before validation passes")
    }

    func test_install_refusesDuplicateFolder_andDuplicateID() throws {
        let src = try stagePlugin(folderName: "dup", id: "com.t.dup")
        guard case .installed = PluginLifecycle.install(from: src, into: pluginsDir) else {
            return XCTFail("first install must succeed")
        }
        // Same folder name again → refuse (never overwrite).
        guard case .refusedDuplicate = PluginLifecycle.install(from: src, into: pluginsDir) else {
            return XCTFail("same folder must refuse")
        }
        // Same ID under a DIFFERENT folder name → refuse (one id, one folder).
        let clone = try stagePlugin(folderName: "dup-renamed", id: "com.t.dup")
        guard case .refusedDuplicate = PluginLifecycle.install(from: clone, into: pluginsDir) else {
            return XCTFail("same id in another folder must refuse")
        }
    }

    func test_remove_routesThroughInjectedRemover() throws {
        let src = try stagePlugin(folderName: "gone", id: "com.t.gone")
        _ = PluginLifecycle.install(from: src, into: pluginsDir)

        var trashed: [String] = []
        let outcome = PluginLifecycle.remove(id: "com.t.gone", from: pluginsDir) { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        guard case .removed(let id, _) = outcome else {
            return XCTFail("expected removed, got \(outcome)")
        }
        XCTAssertEqual(id, "com.t.gone")
        XCTAssertEqual(trashed, ["gone"], "the remover received the plugin folder")
        XCTAssertNil(PluginLifecycle.installedFolder(forID: "com.t.gone", in: pluginsDir))
    }

    func test_remove_notFound_and_removerFailure() throws {
        XCTAssertEqual(PluginLifecycle.remove(id: "com.t.absent", from: pluginsDir) { _ in },
                       .notFound(id: "com.t.absent"))
        let src = try stagePlugin(folderName: "sticky", id: "com.t.sticky")
        _ = PluginLifecycle.install(from: src, into: pluginsDir)
        struct Boom: Error {}
        guard case .failed = PluginLifecycle.remove(id: "com.t.sticky", from: pluginsDir,
                                                    using: { _ in throw Boom() }) else {
            return XCTFail("a throwing remover must surface .failed")
        }
        // The folder survives a failed removal.
        XCTAssertNotNil(PluginLifecycle.installedFolder(forID: "com.t.sticky", in: pluginsDir))
    }

    func test_fullLifecycle_installThenRegistryLoadsThenRemove() throws {
        // install → the REAL registry load sees it → remove → gone.
        let src = try stagePlugin(folderName: "cycle", id: "com.t.cycle")
        guard case .installed = PluginLifecycle.install(from: src, into: pluginsDir) else {
            return XCTFail("install failed")
        }
        let results = PluginRegistry.shared.loadAll(from: pluginsDir)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.pluginID, "com.t.cycle")

        guard case .removed = PluginLifecycle.remove(id: "com.t.cycle", from: pluginsDir,
                                                     using: { try FileManager.default.removeItem(at: $0) })
        else { return XCTFail("remove failed") }
        XCTAssertTrue(PluginRegistry.shared.loadAll(from: pluginsDir).isEmpty,
                      "a fresh load after removal sees nothing")
    }

    // MARK: - outcome → banner messages (TSK-1478 pane wiring)

    func test_installOutcome_messages_reflectSuccessAndReason() {
        XCTAssertTrue(PluginLifecycle.InstallOutcome.installed(id: "com.x", folder: "/p").isSuccess)
        XCTAssertTrue(PluginLifecycle.InstallOutcome
            .installed(id: "com.x", folder: "/p").userMessage.contains("com.x"))

        let dup = PluginLifecycle.InstallOutcome.refusedDuplicate(id: "com.x")
        XCTAssertFalse(dup.isSuccess)
        XCTAssertTrue(dup.userMessage.lowercased().contains("already installed"))

        let invalid = PluginLifecycle.InstallOutcome.refusedInvalid(reason: "missing plugin.json")
        XCTAssertFalse(invalid.isSuccess)
        XCTAssertTrue(invalid.userMessage.contains("missing plugin.json"),
                      "the refusal reason is surfaced verbatim")

        XCTAssertFalse(PluginLifecycle.InstallOutcome.failed("io").isSuccess)
    }

    func test_removeOutcome_messages_reflectSuccessAndReason() {
        XCTAssertTrue(PluginLifecycle.RemoveOutcome.removed(id: "com.x", folder: "/p").isSuccess)
        XCTAssertTrue(PluginLifecycle.RemoveOutcome
            .removed(id: "com.x", folder: "/p").userMessage.lowercased().contains("trash"))

        let nf = PluginLifecycle.RemoveOutcome.notFound(id: "com.x")
        XCTAssertFalse(nf.isSuccess)
        let failed = PluginLifecycle.RemoveOutcome.failed("locked")
        XCTAssertFalse(failed.isSuccess)
        XCTAssertTrue(failed.userMessage.contains("locked"))
    }
}
