import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1112 — teeth for surfacing the extensions inventory in Settings. The
/// model accessor returns the live merged inventory (plugins from the shared
/// registry; walkthroughs are a follow-on), which the Settings ▸ Extensions
/// section lists. The section render is review; this pins the data accessor.
@MainActor
final class ExtensionsInventorySettingTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtInv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "ExtInv-\(UUID().uuidString)")!))
    }

    func test_modelInventory_isTheLiveInventory() {
        XCTAssertEqual(makeModel().extensionsInventory, ExtensionsInventory.live(),
                       "the model accessor surfaces the live shared-registry inventory")
    }

    func test_pluginItems_isAWellFormedList() {
        // Exercises items(of:) through the model accessor. A bare host registry
        // yields an empty list — the point is it returns a list, not a crash,
        // and matches the live inventory's plugin slice.
        XCTAssertEqual(makeModel().extensionsInventory.items(of: .plugin).count,
                       ExtensionsInventory.live().items(of: .plugin).count)
    }
}
