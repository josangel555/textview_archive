import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1588 (owner 2026-07-21/24) — text/code files open EDITABLE by default:
/// the Editor (CM6) lens with the View-Only toggle reading OFF. Pins the three
/// halves of the contract at the DocumentModel boundary:
///   1. the default lens for text/code is `.editor` (View-Only OFF);
///   2. the presentation reads primary=.editor / viewOnly=false;
///   3. the SIZE COERCION — a file past `codeMirrorEditorMaxBytes` opens in
///      read-only Source instead (CM6 has a 50 MiB cap; Source has its own
///      large-file stack), including through the OFF-MAIN open path every
///      >4 MiB file takes.
/// Tier: window-free host (T1).
@MainActor
final class EditorDefaultLensTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorDefaultLensTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorDefaultLensTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
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
            preferences: PreferencesStore(defaults: defaults))
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_textAndCode_openEditable_viewOnlyOff() throws {
        let m = makeModel()
        m.open(url: try writeFile("notes.yaml", "key: value\n"))
        XCTAssertEqual(m.currentViewMode, .editor, "yaml (code) opens in the editable Editor lens")
        XCTAssertEqual(m.viewModePresentation.primary, .editor)
        XCTAssertFalse(m.viewModePresentation.viewOnly, "the View-Only toggle reads OFF by default")

        m.open(url: try writeFile("plain.txt", "hello\n"))
        XCTAssertEqual(m.currentViewMode, .editor, "plain text opens editable too")
    }

    func test_htmlAndMarkdown_keepTheirDefaults() throws {
        let m = makeModel()
        m.open(url: try writeFile("page.html", "<p>x</p>\n"))
        XCTAssertEqual(m.currentViewMode, .source, "html keeps the conservative read-only Source default")
        m.open(url: try writeFile("readme.md", "# t\n"))
        XCTAssertEqual(m.currentViewMode, .rendered, "markdown keeps Rendered")
    }

    func test_sizeCoercion_pureHelper() {
        XCTAssertEqual(DocumentModel.editorDefaultSizeCoercion(
            mode: .editor, byteCount: codeMirrorEditorMaxBytes), .editor,
            "at the cap the editor stays")
        XCTAssertEqual(DocumentModel.editorDefaultSizeCoercion(
            mode: .editor, byteCount: codeMirrorEditorMaxBytes + 1), .source,
            "past the cap the open lands in read-only Source")
        XCTAssertEqual(DocumentModel.editorDefaultSizeCoercion(
            mode: .rendered, byteCount: .max), .rendered,
            "non-editor modes are never touched")
    }

    func test_largeTextFile_opensReadOnlySource_notEditorPlaceholder() throws {
        // The 300MB-log regression guard: a text file past the CM6 cap must
        // open in the Source lens (which has its own large-file rendering
        // stack), NOT dead-end in the editor's LargeEditorPlaceholderView.
        // >50 MiB rides the OFF-MAIN open path (>4 MiB defers), so this pins
        // the coercion at the async landing — the path real big files take.
        let bigURL = tmpDir.appendingPathComponent("big.log")
        let chunk = String(repeating: "x", count: 1024 * 1024)   // 1 MiB
        FileManager.default.createFile(atPath: bigURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bigURL)
        for _ in 0..<(codeMirrorEditorMaxBytes / (1024 * 1024) + 1) {
            handle.write(Data(chunk.utf8))
        }
        try handle.close()

        let m = makeModel()
        m.open(url: bigURL)
        // The off-main read lands asynchronously — poll until the tab leaves
        // `.loading` (bounded; the read is local-disk sequential).
        var loaded = false
        for _ in 0..<200 {
            if case .loaded = m.tabs.tabs.first?.state { loaded = true; break }
            try await_ms(50)
        }
        XCTAssertTrue(loaded, "the off-main open must land within the poll budget")
        XCTAssertEqual(m.currentViewMode, .source,
            "past the CM6 cap the open is coerced to the read-only Source lens")
        XCTAssertTrue(m.viewModePresentation.viewOnly,
            "the View-Only toggle reads ON for the coerced large file")
    }

    /// Main-actor-friendly sleep that services the main queue so the
    /// off-main open's `MainActor.run` completion can land while we wait.
    private func await_ms(_ ms: Int) throws {
        RunLoop.main.run(until: Date().addingTimeInterval(Double(ms) / 1000.0))
    }
}
