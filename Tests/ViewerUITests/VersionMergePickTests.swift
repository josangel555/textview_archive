import XCTest
import ViewerCore
@testable import ViewerUI

/// I-08 — `DocumentModel.beginVersionMergePick`: the version-history "Merge
/// into Current…" flow end-to-end at the model layer — session opens with the
/// right sides, Apply lands as a dirty buffer edit (never a disk write),
/// identical version short-circuits, and the viewer wiring is pinned.
@MainActor
final class VersionMergePickTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionMergePick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_mergePick_opensSession_andApplyBringsBackChosenHunks() throws {
        // The live-incident shape: disk/buffer lost a block that the history
        // version still holds; the buffer also has NEWER content to keep.
        let url = try writeFile("doc.md", "head\nnewer-edit\ntail\n")
        let model = DocumentModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        let version = "head\nold-line\ntail\nlost-1\nlost-2\n"

        XCTAssertTrue(model.beginVersionMergePick(
            versionText: version, url: url, versionLabel: "12:30 version"))
        let session = try XCTUnwrap(model.activeConflictResolution,
            "merge-pick must open the 3-pane session")
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.model.oursLabel, "Current")
        XCTAssertEqual(session.model.theirsLabel, "12:30 version")
        XCTAssertEqual(session.model.result.conflictCount, 2,
            "changed middle line + lost trailing block = two pickable hunks")

        // Keep the newer edit, take back the lost block — then Apply.
        session.model.select(.ours, at: 0)
        session.model.select(.theirs, at: 1)
        let resolved = try XCTUnwrap(session.model.resolvedText)
        model.applyActiveConflictResolution(resolved)

        XCTAssertEqual(model.editor.editorBuffers[id]?.text,
                       "head\nnewer-edit\ntail\nlost-1\nlost-2\n",
            "Apply = newer edit kept + lost block recovered")
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true,
            "the merge lands as an UNSAVED buffer edit")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "head\nnewer-edit\ntail\n",
            "nothing touches the disk until the user saves")
        XCTAssertNil(model.activeConflictResolution, "Apply closes the session")
    }

    func test_identicalVersion_declinesWithoutASession() throws {
        let url = try writeFile("same.md", "alpha\nbeta\n")
        let model = DocumentModel()
        model.open(url: url)
        _ = model.editor.editorBuffer(forTabID: model.tabs.selected!.id)

        XCTAssertFalse(model.beginVersionMergePick(
            versionText: "alpha\nbeta\n", url: url))
        XCTAssertNil(model.activeConflictResolution)
    }

    func test_closedFile_isOpenedFirst_thenPicked() throws {
        let url = try writeFile("closed.md", "one\ntwo\n")
        let model = DocumentModel()   // nothing open

        XCTAssertTrue(model.beginVersionMergePick(
            versionText: "one\nTWO\n", url: url))
        XCTAssertNotNil(model.activeConflictResolution)
        XCTAssertEqual(model.tabs.selected?.url?.standardizedFileURL,
                       url.standardizedFileURL,
            "open-then-apply: the file opens as a tab first")
    }

    /// Wiring pin: the viewer offers both new affordances and the Local
    /// History hosts route Merge into `beginVersionMergePick`.
    func test_viewer_andHosts_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewer = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ViewerUI/Git/UnifiedHistoryView.swift"),
            encoding: .utf8)
        XCTAssertTrue(viewer.contains("mdv.history.mergePick"))
        XCTAssertTrue(viewer.contains("mdv.history.copyVersion"))
        let hosts = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ViewerUI/DocumentModel+FileHistory.swift"),
            encoding: .utf8)
        XCTAssertEqual(
            hosts.components(separatedBy: "beginVersionMergePick").count - 1, 2,
            "BOTH Local History entry points wire onMergePick")
    }
}
