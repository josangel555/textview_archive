import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Bug C — view-mode switcher race.
///
/// `setCurrentViewMode` flips the tab's `viewMode` SYNCHRONOUSLY but
/// triggers the matching state transition ASYNCHRONOUSLY and UNGUARDED:
///   - `.hex`  → `loadBinaryAsync` (writes `.binary` when it lands)
///   - text    → `loadTextAsync`  (writes `.loaded`  when it lands)
/// Neither completion re-checks the tab's CURRENT `viewMode` before
/// writing. A rapid HEX→Source toggle therefore lands a STALE
/// `loadBinaryAsync` (`.binary`) into a tab whose picker now says
/// Source — the content pane shows HexView under a "Source" selection
/// (or, with real read latency, strands the tab in `.loading`, which is
/// the endless spinner the user hits; a fresh re-open loads fast because
/// it hits an already-materialized / non-racing path).
///
/// Invariant under test (the fix must hold ALL of these):
///   1. After the switch sequence settles, the tab's STATE must be
///      consistent with its `viewMode`: a `.source`/`.rendered`/`.editor`
///      tab must NOT be left in `.binary`; a `.hex` tab must end `.binary`.
///   2. The tab must never be stranded in `.loading` once quiescent.
///   3. The LATEST switch wins — a superseded async load must not
///      overwrite the state the latest mode wants.
///
/// T1m (headless, hermetic DocumentModel via the DI seam). A tiny
/// `softWarnBytes` routes every text open off-main so the async loaders
/// are exercised, exactly as a multi-MB file would on the host.
@MainActor
final class ModeSwitchRaceTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModeSwitchRaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ModeSwitchRaceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(softWarnBytes: Int = 16) -> DocumentModel {
        DocumentModel(
            controller: DocumentController(
                loader: TextFileLoader(
                    readableMaxBytes: 512 * 1024 * 1024,
                    softWarnBytes: softWarnBytes
                )
            ),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Drain pending async loads. Yields + briefly sleeps so every
    /// `loadBinaryAsync` / `loadTextAsync` / materialize MainActor hop
    /// queued during the switch sequence gets a chance to land — INCLUDING
    /// a stale one. The test asserts the END state, so draining late
    /// completions is the point (a stale `loadBinaryAsync` lands here).
    private func drainAsyncLoads() async {
        for _ in 0..<200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
    }

    /// Wait until the selected tab leaves `.loading`, or time out.
    private func awaitNotLoading(_ model: DocumentModel) async {
        for _ in 0..<400 {
            if let s = model.tabs.selected?.state {
                if case .loading = s {} else { return }
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    private func assertConsistent(
        _ model: DocumentModel,
        _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let tab = model.tabs.selected else {
            return XCTFail("\(context): no selected tab", file: file, line: line)
        }
        // (2) never stranded in .loading once quiescent.
        if case .loading = tab.state {
            XCTFail("\(context): tab STRANDED in .loading (endless spinner) — mode=\(tab.viewMode)",
                    file: file, line: line)
            return
        }
        // (1) state must reconcile with viewMode.
        switch tab.viewMode {
        case .source, .rendered, .editor, .table, .diff, .formatted, .preview:
            // None of these non-HEX modes should leave the pane on .binary
            // (HexView). `.preview` in particular must show the native
            // MediaPreviewView (.preview state), not a stale hex dump.
            if case .binary = tab.state {
                XCTFail("""
                    \(context): mode=\(tab.viewMode) but state=.binary — content pane shows \
                    HexView under a non-HEX picker (stale loadBinaryAsync won the race)
                    """, file: file, line: line)
            }
        case .hex:
            // A text-mode loader must not have clobbered the HEX request.
            switch tab.state {
            case .loaded:
                XCTFail("\(context): mode=.hex but state=.loaded — stale loadTextAsync won the race",
                        file: file, line: line)
            default:
                break
            }
        }
    }

    // MARK: - The core regression: HEX → text rapid toggle strands a stale binary load

    /// Plain-text file. Switch to HEX (kicks loadBinaryAsync) then
    /// immediately back to Source. The Source switch sees state still
    /// `.loaded` (binary load not landed) so kicks nothing; the stale
    /// binary load then lands `.binary` under a Source picker.
    func test_hexThenSourceToggle_doesNotStrandBinaryUnderSource() async throws {
        let model = makeModel()
        let url = try writeFile("doc.txt", String(repeating: "y", count: 4096))
        model.open(url: url)
        await awaitNotLoading(model)

        model.setCurrentViewMode(.hex)
        model.setCurrentViewMode(.source)
        await drainAsyncLoads()

        XCTAssertEqual(model.currentViewMode, .source)
        assertConsistent(model, "after HEX→Source toggle")
    }

    /// Markdown file (the common "switcher" target: Rendered/Source/Editor/HEX).
    /// Rendered → HEX → Rendered. The final Rendered must not be left
    /// showing HexView.
    func test_renderedHexRenderedToggle_markdown_reconciles() async throws {
        let model = makeModel()
        let url = try writeFile("readme.md", String(repeating: "# title\n\ntext\n", count: 200))
        model.open(url: url)
        await awaitNotLoading(model)

        model.setCurrentViewMode(.hex)
        model.setCurrentViewMode(.rendered)
        await drainAsyncLoads()

        XCTAssertEqual(model.currentViewMode, .rendered)
        assertConsistent(model, "after Rendered→HEX→Rendered toggle")
    }

    /// Source → HEX → Editor. Ends in `.editor`, which needs `.loaded`
    /// text — must not be left `.binary`.
    func test_sourceHexEditorToggle_endsLoadedNotBinary() async throws {
        let model = makeModel()
        let url = try writeFile("code.swift", String(repeating: "let x = 1\n", count: 400))
        model.open(url: url)
        await awaitNotLoading(model)

        model.setCurrentViewMode(.hex)
        model.setCurrentViewMode(.editor)
        await drainAsyncLoads()

        XCTAssertEqual(model.currentViewMode, .editor)
        assertConsistent(model, "after Source→HEX→Editor toggle")
    }

    /// Stress: many rapid mode cycles with re-opens interleaved (the
    /// "user mashing the segmented picker" pattern). After everything
    /// settles the tab must be consistent and not stranded.
    func test_rapidModeCycling_neverStrandsOrDesyncs() async throws {
        let model = makeModel()
        let url = try writeFile("big.md", String(repeating: "# h\n\nbody\n", count: 300))
        let cycle: [ViewMode] = [.hex, .source, .rendered, .hex, .editor, .source, .hex, .rendered]
        for round in 0..<40 {
            for mode in cycle {
                model.setCurrentViewMode(mode)
                // Occasionally let a load land MID-sequence so a stale
                // completion can race the next switch.
                if round % 4 == 0 { await Task.yield() }
            }
            if round % 6 == 0 { model.open(url: url) } // re-open interleave
        }
        await awaitNotLoading(model)
        await drainAsyncLoads()
        await awaitNotLoading(model)
        assertConsistent(model, "after 40 rapid mode-cycle rounds")
    }

    /// Direct latest-switch-wins check: switch to HEX, then on the SAME
    /// main turn switch to Source BEFORE draining. The binary load kicked
    /// by the HEX switch is now stale; when it lands it must be discarded.
    func test_latestSwitchWins_staleBinaryLoadDiscarded() async throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", String(repeating: "n", count: 4096))
        model.open(url: url)
        await awaitNotLoading(model)
        guard case .loaded = model.tabs.selected?.state else {
            return XCTFail("precondition: file should be .loaded")
        }

        // HEX kicks loadBinaryAsync; Source supersedes it immediately.
        model.setCurrentViewMode(.hex)
        model.setCurrentViewMode(.source)
        // The stale binary load lands during the drain.
        await drainAsyncLoads()

        XCTAssertEqual(model.currentViewMode, .source)
        if case .binary = model.tabs.selected?.state {
            XCTFail("stale loadBinaryAsync won: latest switch (.source) must win the race")
        }
    }
}
