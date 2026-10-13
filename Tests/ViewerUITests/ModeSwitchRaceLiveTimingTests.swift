import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Bug C, live-timing variant — the gap the existing `ModeSwitchRaceTests`
/// miss.
///
/// `ModeSwitchRaceTests.test_sourceHexEditorToggle_endsLoadedNotBinary`
/// fires `setCurrentViewMode(.hex)` then `setCurrentViewMode(.editor)`
/// SYNCHRONOUSLY on the same main-actor turn, so the `.hex` switch's
/// `loadBinaryAsync` has not even started its detached Task before
/// `.editor` is set. The binary load therefore lands when `viewMode` is
/// already `.editor` and the ac4fcee guard correctly drops it.
///
/// The LIVE app does not switch synchronously — there is a real gap
/// (a user's clicks; the `--script` runner sleeps 300 ms between verbs).
/// In that gap the `.hex` switch's `loadBinaryAsync` LANDS `.binary`
/// while `viewMode` is still `.hex` (so the guard admits it). THEN the
/// `.editor` switch runs: it reads a STALE local snapshot `var t =
/// tabs.tabs[i]` whose `.state` it captured, mutates only `viewMode`,
/// and writes the whole struct back with `replace(at:i:with:t)` —
/// clobbering nothing here, but the editor arm's `case .binary = t.state`
/// guard fires on the now-current `.binary`, kicks `loadTextAsync`...
///
/// This test injects the live gap with a real `Task.sleep` between the
/// two switches so the binary load lands FIRST, reproducing the live
/// "Editor shows HEX" desync that the synchronous test cannot.
@MainActor
final class ModeSwitchRaceLiveTimingTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModeSwitchRaceLiveTimingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ModeSwitchRaceLiveTimingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(loader: TextFileLoader()),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func awaitNotLoading(_ model: DocumentModel) async {
        for _ in 0..<400 {
            if let s = model.tabs.selected?.state {
                if case .loading = s {} else { return }
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    /// Let queued async loads land between switches.
    private func settle(_ ms: UInt64 = 60) async {
        for _ in 0..<30 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: ms * 1_000_000 / 30)
        }
    }

    /// Source → HEX → (gap; binary load lands) → Editor.
    /// With the live gap the tab ends `.binary` under an `.editor` picker.
    func test_sourceHexEditor_withGap_endsLoadedNotBinary() async throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "import Foundation\nlet x = 1\n")
        model.open(url: url)
        await awaitNotLoading(model)

        model.setCurrentViewMode(.hex)
        await settle()   // the live gap: loadBinaryAsync lands .binary here
        model.setCurrentViewMode(.editor)
        await settle()

        XCTAssertEqual(model.currentViewMode, .editor)
        if case .binary = model.tabs.selected?.state {
            XCTFail("Editor picker but state=.binary — content pane shows HexView under Editor (live-timing desync)")
        }
    }

    /// Source → HEX → (gap) → Source. The classic "Editor again shows HEX"
    /// is the editor variant; this is the source variant.
    func test_sourceHexSource_withGap_endsLoadedNotBinary() async throws {
        let model = makeModel()
        let url = try writeFile("doc.txt", "hello world\n")
        model.open(url: url)
        await awaitNotLoading(model)

        model.setCurrentViewMode(.hex)
        await settle()
        model.setCurrentViewMode(.source)
        await settle()

        XCTAssertEqual(model.currentViewMode, .source)
        if case .binary = model.tabs.selected?.state {
            XCTFail("Source picker but state=.binary — content pane shows HexView under Source (live-timing desync)")
        }
    }
}
