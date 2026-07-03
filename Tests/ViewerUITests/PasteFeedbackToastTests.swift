import XCTest
import AppKit
import ViewerCore
@testable import ViewerUI

/// TSK-1479 — "Pasted as X — Undo" feedback. Universal paste used to be
/// invisible magic (clipboard silently becomes a tab). Pins, on the host:
/// the pure outcome→description mapping, the toast posted after a real
/// `universalPaste(from:)` (injected pasteboard + injected ToastCenter — the
/// command path, no window), and the Undo action closing exactly the tab the
/// paste created (safe no-op when it's already gone).
@MainActor
final class PasteFeedbackToastTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteFeedbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "PasteFeedbackTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func makeModel(toasts: ToastCenter) -> DocumentModel {
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
        model.toasts = toasts
        return model
    }

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("PasteFeedbackTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    // MARK: - Outcome description (pure)

    func test_humanDescription_coversEveryOutcome() {
        XCTAssertEqual(UniversalPastePlan.humanDescription(for: .plainText), "Pasted as text")
        XCTAssertEqual(UniversalPastePlan.humanDescription(for: .table), "Pasted as table")
        XCTAssertEqual(UniversalPastePlan.humanDescription(for: .image), "Pasted as image")
        XCTAssertEqual(UniversalPastePlan.humanDescription(for: .richText), "Pasted as rich text")
        XCTAssertEqual(UniversalPastePlan.humanDescription(for: .fileURL), "Opened pasted file")
        XCTAssertEqual(
            UniversalPastePlan.humanDescription(for: .richText, convertedToMarkdown: true),
            "Pasted as Markdown",
            "the TSK-1327 HTML→Markdown path announces what ACTUALLY happened")
    }

    // MARK: - Toast after a real paste (command path)

    func test_plainTextPaste_postsSuccessToastWithUndo() {
        let center = ToastCenter(now: { 0 })
        let model = makeModel(toasts: center)
        let pb = freshPasteboard()
        pb.setString("hello", forType: .string)

        XCTAssertTrue(model.universalPaste(from: pb))
        XCTAssertEqual(center.toasts.count, 1, "every successful paste announces itself")
        XCTAssertEqual(center.toasts[0].kind, .success)
        XCTAssertEqual(center.toasts[0].message, "Pasted as text")
        XCTAssertEqual(center.toasts[0].actionLabel, "Undo")
    }

    func test_richHTMLPaste_announcesMarkdownConversion() {
        let center = ToastCenter(now: { 0 })
        let model = makeModel(toasts: center)
        let pb = freshPasteboard()
        pb.setData(Data("<h1>T</h1>".utf8), forType: .html)

        XCTAssertTrue(model.universalPaste(from: pb))
        XCTAssertEqual(center.toasts.first?.message, "Pasted as Markdown")
    }

    func test_failedPaste_postsNothing() {
        let center = ToastCenter(now: { 0 })
        let model = makeModel(toasts: center)
        XCTAssertFalse(model.universalPaste(from: freshPasteboard()))
        XCTAssertTrue(center.toasts.isEmpty, "no outcome → nothing to announce")
    }

    // MARK: - Undo

    func test_undo_closesTheCreatedTab() {
        let center = ToastCenter(now: { 0 })
        let model = makeModel(toasts: center)
        let pb = freshPasteboard()
        pb.setString("undo me", forType: .string)

        XCTAssertTrue(model.universalPaste(from: pb))
        let createdID = model.tabs.selected?.id
        XCTAssertNotNil(createdID)
        XCTAssertEqual(model.tabs.tabs.count, 1)

        center.runAction(for: center.toasts[0].id)
        XCTAssertFalse(model.tabs.tabs.contains { $0.id == createdID },
            "Undo closes exactly the tab the paste created")
    }

    func test_undo_afterTabAlreadyClosed_isSafeNoOp() {
        let center = ToastCenter(now: { 0 })
        let model = makeModel(toasts: center)
        let pb = freshPasteboard()
        pb.setString("gone", forType: .string)
        XCTAssertTrue(model.universalPaste(from: pb))
        let toastID = center.toasts[0].id

        // User closes the pasted tab themselves, then clicks Undo.
        model.closeTab(at: 0)
        let remaining = model.tabs.tabs
        center.runAction(for: toastID)
        XCTAssertEqual(model.tabs.tabs, remaining, "stale Undo must not close anything else")
    }

    func test_undo_targetsThePastedTab_notTheCurrentOne() throws {
        let center = ToastCenter(now: { 0 })
        let model = makeModel(toasts: center)
        let pb = freshPasteboard()
        pb.setString("first paste", forType: .string)
        XCTAssertTrue(model.universalPaste(from: pb))
        let pastedID = try XCTUnwrap(model.tabs.selected?.id)
        let toastID = center.toasts[0].id

        // Open ANOTHER file and select it — Undo must still close the pasted
        // tab, not the newly selected one.
        let other = tmpDir.appendingPathComponent("other.txt")
        try "other".write(to: other, atomically: true, encoding: .utf8)
        model.open(url: other)
        let otherID = try XCTUnwrap(model.tabs.selected?.id)
        XCTAssertNotEqual(pastedID, otherID)

        center.runAction(for: toastID)
        XCTAssertFalse(model.tabs.tabs.contains { $0.id == pastedID }, "pasted tab closed")
        XCTAssertTrue(model.tabs.tabs.contains { $0.id == otherID }, "other tab untouched")
    }
}
