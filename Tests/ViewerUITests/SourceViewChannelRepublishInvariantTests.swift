import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Perf invariant pin (PERF — the scroll/caret republish cascade).
///
/// `sourceScrollState` + `sourceSelection` (and the scroll-to-line request,
/// `sourceScrollLineTarget`/`Nonce`) moved off `DocumentModel` onto the
/// narrow `SourceViewChannel`. These tick on EVERY scroll wheel event and
/// EVERY caret move. Before the split they were `@Published` directly on
/// `DocumentModel`, so every view observing `DocumentModel` (`ContentView`,
/// `SidebarView` + its every `FileRowView`, `ModeBar`, `TabBar`, …)
/// re-bodied on every scroll tick / caret move — measured at ~249× the
/// no-change layout baseline for a single caret move.
///
/// These tests pin the fix: mutating the source-view scroll/caret/scroll-line
/// state — whether through the `model` forwarders OR directly on the channel
/// — must fire `DocumentModel.objectWillChange` ZERO times. The matching
/// `SourceViewChannel.objectWillChange` MUST fire (so the gutter / status bar
/// / source subtree still re-body).
///
/// Mirrors `FindRepublishInvariantTests`, `EditorRepublishInvariantTests`,
/// `TabRepublishInvariantTests`, etc.
@MainActor
final class SourceViewChannelRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceViewChannelRepublishInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SourceViewChannelRepublishInvariantTests-\(UUID().uuidString)"
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
            goToPathHistory: GoToPathHistoryStore(
                storeURL: tmpDir.appendingPathComponent("goto.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func countDocumentRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    private func countChannelRepublishes(
        of channel: SourceViewChannel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = channel.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    // MARK: - Scroll ticks (the highest-frequency event)

    func test_scrollStateViaForwarder_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let count = await countDocumentRepublishes(of: model) {
            model.sourceScrollState = SourceScrollState(
                offsetY: 1280, viewportHeight: 600, lineHeight: 16,
                lineCount: 300, topInset: 10)
        }
        XCTAssertEqual(count, 0,
            "a scroll tick must not republish DocumentModel (it lives on SourceViewChannel)")
    }

    func test_scrollStateDirectOnChannel_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let count = await countDocumentRepublishes(of: model) {
            model.sourceView.sourceScrollState = SourceScrollState(
                offsetY: 2400, viewportHeight: 600, lineHeight: 16,
                lineCount: 300, topInset: 10)
        }
        XCTAssertEqual(count, 0,
            "a scroll tick on the channel must not republish DocumentModel")
    }

    func test_scrollState_doesRepublishChannel() async throws {
        let model = makeModel()
        let count = await countChannelRepublishes(of: model.sourceView) {
            model.sourceScrollState = SourceScrollState(
                offsetY: 800, viewportHeight: 600, lineHeight: 16,
                lineCount: 300, topInset: 10)
        }
        XCTAssertEqual(count, 1,
            "the gutter / minimap must still re-body on a scroll tick (channel republish)")
    }

    // MARK: - Caret moves

    func test_caretMoveViaForwarder_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let count = await countDocumentRepublishes(of: model) {
            model.sourceSelection = SourceSelection(line: 42, column: 7, length: 0)
        }
        XCTAssertEqual(count, 0,
            "a caret move must not republish DocumentModel (it lives on SourceViewChannel)")
    }

    func test_caretMove_doesRepublishChannel() async throws {
        let model = makeModel()
        let count = await countChannelRepublishes(of: model.sourceView) {
            model.sourceSelection = SourceSelection(line: 42, column: 7, length: 0)
        }
        XCTAssertEqual(count, 1,
            "the status bar L:C readout must still re-body on a caret move (channel republish)")
    }

    // MARK: - Scroll-to-line request

    func test_scrollSourceToLine_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let count = await countDocumentRepublishes(of: model) {
            model.scrollSource(toLine: 17)
        }
        XCTAssertEqual(count, 0,
            "scrollSource(toLine:) must not republish DocumentModel")
    }

    func test_scrollSourceToLine_bumpsNonceAndTargetThroughForwarder() async throws {
        let model = makeModel()
        let baseline = model.sourceScrollLineNonce
        model.scrollSource(toLine: 9)
        XCTAssertEqual(model.sourceScrollLineTarget, 9)
        XCTAssertEqual(model.sourceView.sourceScrollLineTarget, 9,
            "forwarder and channel must agree on the target")
        XCTAssertNotEqual(model.sourceScrollLineNonce, baseline,
            "re-requesting must bump the nonce so the source view re-fires")
    }

    // MARK: - Negative control

    func test_documentModelMutation_doesRepublishDocumentModel() async throws {
        let model = makeModel()
        let count = await countDocumentRepublishes(of: model) {
            model.sidebarWidth = 271
        }
        XCTAssertGreaterThanOrEqual(count, 1,
            "control: a genuine DocumentModel @Published change still republishes it")
    }
}
