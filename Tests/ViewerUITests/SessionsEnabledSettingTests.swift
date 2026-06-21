import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1105 — teeth for surfacing the sessions-enabled pref in Settings. The
/// model knob (`DocumentModel.sessionsEnabled`) reads the pref at init and
/// writes through on change, so the Settings toggle round-trips to the persisted
/// `PreferencesStore.sessionsEnabled` (TSK-264). The Toggle render is review.
@MainActor
final class SessionsEnabledSettingTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessEnabled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel(_ prefs: PreferencesStore) -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: prefs)
    }

    private func freshPrefs() -> PreferencesStore {
        PreferencesStore(defaults: UserDefaults(suiteName: "SessPrefs-\(UUID().uuidString)")!)
    }

    func test_defaultIsOn() {
        XCTAssertTrue(makeModel(freshPrefs()).sessionsEnabled, "sessions default ON")
    }

    func test_modelReadsPrefAtInit() {
        let prefs = freshPrefs()
        prefs.sessionsEnabled = false
        XCTAssertFalse(makeModel(prefs).sessionsEnabled,
                       "the model knob reflects the persisted pref at init")
    }

    func test_settingModel_writesThroughToPref() {
        let prefs = freshPrefs()
        let model = makeModel(prefs)
        model.sessionsEnabled = false
        XCTAssertFalse(prefs.sessionsEnabled,
                       "toggling the model knob persists to the pref")
        model.sessionsEnabled = true
        XCTAssertTrue(prefs.sessionsEnabled)
    }
}
