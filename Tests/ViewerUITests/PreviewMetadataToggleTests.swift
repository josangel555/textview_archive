import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-608: the preview-mode metadata panel (file info / dimensions /
/// table-row counts) used to render unconditionally with no dismiss
/// affordance. It is now gated on `DocumentModel.showPreviewMetadataPanel`,
/// driven by the BottomAttributesBar "Info" toggle and persisted via
/// `PreferencesStore.previewMetadataVisible`. These pin the state machine:
/// default ON (prior behavior), toggle persists, restored on relaunch.
@MainActor
final class PreviewMetadataToggleTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewMetaToggle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "PreviewMetaToggle-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    func test_defaultsOn_matchingPriorBehavior() {
        XCTAssertTrue(PreferencesStore(defaults: defaults).previewMetadataVisible,
                      "fresh defaults must show the panel (pre-TSK-608 behavior)")
        XCTAssertTrue(makeModel().showPreviewMetadataPanel,
                      "model seeds ON from fresh preferences")
    }

    func test_toggleOff_persistsAndRestores() {
        let m = makeModel()
        m.showPreviewMetadataPanel = false

        XCTAssertFalse(PreferencesStore(defaults: defaults).previewMetadataVisible,
                       "toggling the model must write through to preferences")
        XCTAssertFalse(makeModel().showPreviewMetadataPanel,
                       "a fresh model (relaunch) must restore the dismissed state")
    }

    func test_toggleBackOn_persists() {
        let m = makeModel()
        m.showPreviewMetadataPanel = false
        m.showPreviewMetadataPanel = true
        XCTAssertTrue(makeModel().showPreviewMetadataPanel,
                      "re-enabling must persist symmetrically")
    }
}
