import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-627 — the response-side glue that the wiring tests can't reach:
/// `formatActiveEditorViaLSP` → pool → REAL fake-server round trip →
/// `LSPTextEditApplier` → `updateEditorText`, including the snapshot
/// guard under a simulated race. Uses the DocumentModel `lspPool`
/// injection seam with a registry routing `.fakelsp` to the
/// `MDVFakeLSPServer` binary (same pattern as `LSPPoolFakeServerTests`).
/// Skips (not fails) when the fake-server binary isn't built.
@MainActor
final class LSPFormatEndToEndTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!
    private var pool: LSPPool!

    override func setUp() async throws {
        try await super.setUp()
        harness = nil
        pool = nil
    }

    override func tearDown() async throws {
        if let pool { await pool.closeAll() }
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    /// Compact copy of `FakeLSPServerHelper.locate` (that helper lives in
    /// the ViewerCoreTests target): walk up from `#filePath` to the
    /// package root, then scan `.build/<triple>/<config>/`.
    private func locateFakeServer() throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/",
              !fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        let build = dir.appendingPathComponent(".build")
        for config in ["debug", "release"] {
            for triple in (try? fm.contentsOfDirectory(
                at: build, includingPropertiesForKeys: nil)) ?? [] {
                let candidate = triple.appendingPathComponent(config)
                    .appendingPathComponent("MDVFakeLSPServer")
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw XCTSkip("MDVFakeLSPServer not built — run swift build --product MDVFakeLSPServer")
    }

    /// Model whose pool routes `.fakelsp` files to the fake server.
    private func makeModelWithFakeLSP() throws -> DocumentModel {
        let binary = try locateFakeServer()
        let env = ProcessInfo.processInfo.environment
        let entry = LSPLanguageEntry(
            language: .swift,
            fileExtensions: ["fakelsp"],
            rootFinder: { $0.deletingLastPathComponent() },
            serverLauncher: { root in
                LSPClient.Config(
                    executable: binary, arguments: [],
                    workspaceRoot: root, environment: env)
            })
        pool = LSPPool(registry: LSPLanguageRegistry(entries: [entry]))
        harness = HeadlessHarness(label: "LSPFormatEndToEndTests", lspPool: pool)
        return harness.model
    }

    /// Wait until `condition()` or time out — the format apply lands on
    /// a MainActor hop after the server round-trip.
    private func waitUntil(
        _ timeout: TimeInterval = 5.0, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func test_formatCommand_appliesServerEditsToTheBuffer() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("doc.fakelsp", "abcdef\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)

        XCTAssertTrue(model.formatActiveEditorViaLSP())
        // Fake server: replace (0,0)-(0,3) with "FMT" + insert header.
        await waitUntil { model.editor.editorBuffers[id]?.text == "// formatted\nFMTdef\n" }
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "// formatted\nFMTdef\n",
            "the server's TextEdits must land in the editor buffer (TSK-627)")
        XCTAssertEqual(model.editor.editorBuffers[id]?.isDirty, true,
            "a formatted buffer is unsaved work — must be dirty")
    }

    func test_formatResponse_droppedWhenBufferChangedSinceDispatch() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("race.fakelsp", "abcdef\n")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)

        XCTAssertTrue(model.formatActiveEditorViaLSP())
        // Simulate a keystroke racing the formatter: mutate the buffer
        // immediately after dispatch, before the response can land.
        model.updateEditorText("user typed this\n", forTabID: id)

        // Give the response time to arrive (and be dropped).
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "user typed this\n",
            "a stale formatter response must NOT clobber text typed during the round trip")
    }
}
