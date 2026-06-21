import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1109 — teeth for wiring PackageManifestParser into a reachable "Package
/// Dependencies" explorer. `showPackageExplorer()` parses the ACTIVE manifest
/// (package.json / Cargo.toml) and opens a hosted tab (returning the dependency
/// count); a non-manifest file is a no-op. (The list render is VM/review; the
/// parse is covered by PackageManifest's own tests.)
@MainActor
final class PackageExplorerWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PkgExpWiring-\(UUID().uuidString)")
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
                suiteName: "PkgExp-\(UUID().uuidString)")!))
    }

    func test_showPackageExplorer_opensTabWithDeclaredDeps() throws {
        let url = tmp.appendingPathComponent("package.json")
        try #"{"name":"app","dependencies":{"react":"^18.0.0"},"devDependencies":{"jest":"^29.0.0"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: url)
        let before = model.tabs.tabs.count

        let count = model.showPackageExplorer()
        XCTAssertEqual(count, 2, "react (dep) + jest (dev) parsed")
        XCTAssertGreaterThan(model.tabs.tabs.count, before, "opens the dependencies hosted tab")
    }

    func test_showPackageExplorer_nonManifest_isNoOp() throws {
        let url = tmp.appendingPathComponent("notes.txt")
        try "just notes".write(to: url, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: url)
        let before = model.tabs.tabs.count
        XCTAssertEqual(model.showPackageExplorer(), 0, "not a recognized manifest → 0")
        XCTAssertEqual(model.tabs.tabs.count, before, "no spurious tab")
    }
}
