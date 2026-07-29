import AppKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1597 — select → right-click → "Compare with Clipboard". Host pins for
/// the model action the menu item invokes (the exact-closure rule): the pure
/// diff-text builder, the ephemeral preview open in the `.diff` lens, and the
/// identical-content no-op. The NSMenu popUp itself is interactive (VM/AX).
@MainActor
final class ClipboardCompareTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardCompareTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ClipboardCompareTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // A private named pasteboard so the test never clobbers the user's
        // clipboard (same pattern as the paste-dispatch suites).
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipboardCompareTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
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

    private func setClipboard(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    // MARK: pure diff-text builder

    func test_diffText_identical_isEmpty() {
        XCTAssertEqual(
            DocumentModel.clipboardCompareDiffText(selection: "same\n", clipboard: "same\n"),
            "")
    }

    func test_diffText_different_isParseableUnifiedDiff() {
        let text = DocumentModel.clipboardCompareDiffText(
            selection: "alpha\nbeta\n", clipboard: "alpha\ngamma\n")
        XCTAssertTrue(text.contains("-beta") && text.contains("+gamma"),
                      "unified diff must carry the change: \(text)")
        // Round-trips through the SAME parser the diff view renders from.
        let files = RustDiffAdapter.parse(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hunks.flatMap(\.lines).contains { $0.kind == .added && $0.content == "gamma" })
    }

    // MARK: the menu action's model behavior

    func test_compare_opensEphemeralDiffPreview() {
        let m = makeModel()
        setClipboard("alpha\nCHANGED\n")
        m.compareSelectionWithClipboard(selection: "alpha\nbeta\n", pasteboard: pasteboard, scratchDirectory: tmpDir)

        XCTAssertEqual(m.tabs.tabs.count, 1, "the comparison opens exactly one tab")
        let tab = m.tabs.tabs[0]
        XCTAssertEqual(tab.url?.lastPathComponent, DocumentModel.clipboardCompareFileName)
        XCTAssertTrue(tab.isPreview,
                      "a throwaway comparison uses the EPHEMERAL preview slot (TSK-1594)")
        XCTAssertEqual(tab.viewMode, .diff,
                       "the .diff scratch file lands in the diff lens")
        if case .loaded(let f) = tab.state {
            XCTAssertTrue(f.contents.contains("+CHANGED"),
                          "tab holds the selection→clipboard diff")
        } else {
            XCTFail("comparison tab must be .loaded")
        }
    }

    func test_compare_identicalContents_opensNothing() {
        let m = makeModel()
        setClipboard("same\n")
        m.compareSelectionWithClipboard(selection: "same\n", pasteboard: pasteboard, scratchDirectory: tmpDir)
        XCTAssertTrue(m.tabs.tabs.isEmpty,
                      "identical selection/clipboard posts a toast instead of an empty diff")
    }

    func test_compare_emptySelectionOrNoTextClipboard_opensNothing() {
        let m = makeModel()
        setClipboard("something")
        m.compareSelectionWithClipboard(selection: "", pasteboard: pasteboard, scratchDirectory: tmpDir)
        XCTAssertTrue(m.tabs.tabs.isEmpty, "empty selection is a no-op")

        pasteboard.clearContents()   // clipboard now has no string
        m.compareSelectionWithClipboard(selection: "text", pasteboard: pasteboard, scratchDirectory: tmpDir)
        XCTAssertTrue(m.tabs.tabs.isEmpty, "text-less clipboard degrades to a toast")
    }

    func test_recompare_reusesTheSameTab() {
        let m = makeModel()
        setClipboard("v1\n")
        m.compareSelectionWithClipboard(selection: "v0\n", pasteboard: pasteboard, scratchDirectory: tmpDir)
        XCTAssertEqual(m.tabs.tabs.count, 1)
        setClipboard("v2\n")
        m.compareSelectionWithClipboard(selection: "v0\n", pasteboard: pasteboard, scratchDirectory: tmpDir)
        XCTAssertEqual(m.tabs.tabs.count, 1,
                       "the deterministic scratch URL dedups — no tab stacking")
        if case .loaded(let f) = m.tabs.tabs[0].state {
            XCTAssertTrue(f.contents.contains("+v2"), "tab shows the LATEST comparison")
        } else {
            XCTFail("comparison tab must be .loaded")
        }
    }
}
