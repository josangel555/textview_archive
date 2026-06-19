import XCTest
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// UX-A (#224) — headless tests for the content-toolbar's presentation
/// layer on `DocumentModel`: the Render | Editor | HEX × ViewOnly + Format
/// control's mapping onto the underlying `ViewMode` per file type, and the
/// breadcrumb segment → sidebar-navigation wiring.
///
/// TIER: T1m/T2' — a hermetic `DocumentModel` driven in-process (no window,
/// no WebView, no `.app` spawn). The control routes through the UNCHANGED
/// `setCurrentViewMode`, so these assertions pin the mapping the live
/// toolbar uses without re-exercising the brittle load/routing path (which
/// `ViewModeMatrixSmokeTests` covers on the VM/T4 lane).
@MainActor
final class ContentToolbarMappingTests: XCTestCase {

    private var tmpRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentToolbarMappingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        suiteName = "ContentToolbarMappingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpRoot.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpRoot.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "hello\nworld\n") throws -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Control → ViewMode mapping per file type

    func test_markdown_render_mapsToRendered() throws {
        let m = makeModel()
        m.open(url: try writeFile("doc.md", "# Hi\n"))
        m.selectViewPrimary(.render, viewOnly: true)
        XCTAssertEqual(m.currentViewMode, .rendered)
        // Presentation round-trips to Render.
        XCTAssertEqual(m.viewModePresentation.primary, .render)
    }

    func test_markdown_editorViewOnly_mapsToSource() throws {
        let m = makeModel()
        m.open(url: try writeFile("doc.md", "# Hi\n"))
        m.selectViewPrimary(.editor, viewOnly: true)
        XCTAssertEqual(m.currentViewMode, .source, "Editor + ViewOnly ⇒ Source")
        let p = m.viewModePresentation
        XCTAssertEqual(p.primary, .editor)
        XCTAssertTrue(p.viewOnly)
    }

    func test_markdown_editorEdit_mapsToEditor() throws {
        let m = makeModel()
        m.open(url: try writeFile("doc.md", "# Hi\n"))
        m.selectViewPrimary(.editor, viewOnly: false)
        XCTAssertEqual(m.currentViewMode, .editor, "Editor + edit ⇒ editable CM6")
        XCTAssertFalse(m.viewModePresentation.viewOnly)
    }

    func test_setViewOnly_swapsSourceAndEditor() throws {
        let m = makeModel()
        m.open(url: try writeFile("code.swift", "let x = 1\n"))
        // Swift opens in Source by default → Editor primary, ViewOnly on.
        XCTAssertEqual(m.viewModePresentation.primary, .editor)
        XCTAssertTrue(m.viewModePresentation.viewOnly)
        // Turn View Only OFF → editable editor.
        m.setViewOnly(false)
        XCTAssertEqual(m.currentViewMode, .editor)
        // Back ON → read-only source.
        m.setViewOnly(true)
        XCTAssertEqual(m.currentViewMode, .source)
    }

    func test_hex_primary_mapsToHex() throws {
        let m = makeModel()
        m.open(url: try writeFile("code.swift", "let x = 1\n"))
        m.selectViewPrimary(.hex, viewOnly: true)
        XCTAssertEqual(m.currentViewMode, .hex)
        XCTAssertEqual(m.viewModePresentation.primary, .hex)
    }

    // MARK: - HEX View Only toggle arms byte editing (#234 / TSK-467)

    func test_hex_defaultsToReadOnly() throws {
        let m = makeModel()
        m.open(url: try writeFile("code.swift", "let x = 1\n"))
        m.selectViewPrimary(.hex, viewOnly: true)
        // Default: View Only ON, not armed — byte-identical to before.
        XCTAssertTrue(m.viewModePresentation.viewOnly)
        if let id = m.tabs.selected?.id {
            XCTAssertFalse(m.isHexEditArmed(forTabID: id))
        } else { XCTFail("no selected tab") }
    }

    func test_hex_setViewOnlyFalse_armsEditing_withoutChangingMode() throws {
        let m = makeModel()
        m.open(url: try writeFile("code.swift", "let x = 1\n"))
        m.selectViewPrimary(.hex, viewOnly: true)
        guard let id = m.tabs.selected?.id else { return XCTFail("no selected tab") }

        m.setViewOnly(false)   // arm
        XCTAssertFalse(m.viewModePresentation.viewOnly, "toggling View Only off arms HEX editing")
        XCTAssertTrue(m.isHexEditArmed(forTabID: id))
        XCTAssertEqual(m.currentViewMode, .hex, "arming must NOT churn the ViewMode (LOADBUG safety)")

        m.setViewOnly(true)    // disarm
        XCTAssertTrue(m.viewModePresentation.viewOnly)
        XCTAssertFalse(m.isHexEditArmed(forTabID: id))
        XCTAssertEqual(m.currentViewMode, .hex)
    }

    func test_hex_armedState_isPerTab() throws {
        let m = makeModel()
        m.open(url: try writeFile("a.swift", "let a = 1\n"))
        m.selectViewPrimary(.hex, viewOnly: true)
        guard let idA = m.tabs.selected?.id else { return XCTFail("no tab A") }
        m.setViewOnly(false)   // arm tab A

        m.open(url: try writeFile("b.swift", "let b = 2\n"))
        m.selectViewPrimary(.hex, viewOnly: true)
        guard let idB = m.tabs.selected?.id, idB != idA else { return XCTFail("no distinct tab B") }

        XCTAssertTrue(m.isHexEditArmed(forTabID: idA), "tab A stays armed")
        XCTAssertFalse(m.isHexEditArmed(forTabID: idB), "tab B is independently read-only")
        // The current presentation reflects the selected tab (B → read-only).
        XCTAssertTrue(m.viewModePresentation.viewOnly)
    }

    func test_hex_republishesOnArm() async throws {
        let m = makeModel()
        m.open(url: try writeFile("code.swift", "let x = 1\n"))
        m.selectViewPrimary(.hex, viewOnly: true)
        var count = 0
        let sub = m.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        m.setViewOnly(false)
        await Task.yield()
        XCTAssertGreaterThan(count, 0, "arming HEX edit must republish so the toolbar/HexView re-evaluate")
    }

    func test_plainText_render_fallsBackToSource() throws {
        let m = makeModel()
        // .txt has no rich lens; Render must resolve to .source, not reject.
        m.open(url: try writeFile("notes.txt", "plain\n"))
        m.selectViewPrimary(.render, viewOnly: true)
        XCTAssertEqual(m.currentViewMode, .source)
    }

    func test_csv_render_mapsToTable() throws {
        let m = makeModel()
        m.open(url: try writeFile("data.csv", "a,b,c\n1,2,3\n"))
        m.selectViewPrimary(.render, viewOnly: true)
        XCTAssertEqual(m.currentViewMode, .table)
    }

    func test_json_showsFormatButton_and_toggleFormatLens() throws {
        let m = makeModel()
        m.open(url: try writeFile("config.json", "{\"a\":1}"))
        XCTAssertTrue(m.showsFormatButton, "JSON is pretty-printable")
        // The toolbar Format button routes through the view-mode lens so
        // currentViewMode becomes .formatted (authoritative), and the
        // presentation flags Format active.
        m.toggleFormatLens()
        XCTAssertEqual(m.currentViewMode, .formatted)
        XCTAssertTrue(m.viewModePresentation.isFormatted)
        // Tapping again returns to the text source.
        m.toggleFormatLens()
        XCTAssertEqual(m.currentViewMode, .source)
        XCTAssertFalse(m.viewModePresentation.isFormatted)
    }

    func test_plainText_hidesFormatButton() throws {
        let m = makeModel()
        m.open(url: try writeFile("notes.txt", "plain\n"))
        XCTAssertFalse(m.showsFormatButton)
    }

    // MARK: - Button-visibility gating per type

    func test_buttonVisibility_markdown() throws {
        let m = makeModel()
        m.open(url: try writeFile("doc.md", "# Hi\n"))
        XCTAssertTrue(m.showsRenderPrimary)
        XCTAssertTrue(m.showsEditorPrimary)
    }

    func test_buttonVisibility_plainText_noRender() throws {
        let m = makeModel()
        m.open(url: try writeFile("notes.txt", "plain\n"))
        XCTAssertFalse(m.showsRenderPrimary, "plain text has no rich lens")
        XCTAssertTrue(m.showsEditorPrimary)
    }

    // MARK: - TSK-898: segmented mode-control source-of-truth (visibleViewPrimaries)

    /// Markdown offers a rich render lens + a text lens + bytes, so the
    /// segmented group surfaces all three, leftmost Render → Editor → HEX.
    func test_visiblePrimaries_markdown_renderEditorHex() throws {
        let m = makeModel()
        m.open(url: try writeFile("doc.md", "# Hi\n"))
        XCTAssertEqual(m.visibleViewPrimaries, [.render, .editor, .hex])
    }

    /// A plain `.txt` has no rich lens → no Render segment; Editor + HEX only.
    func test_visiblePrimaries_plainText_editorHex_noRender() throws {
        let m = makeModel()
        m.open(url: try writeFile("notes.txt", "plain\n"))
        XCTAssertEqual(m.visibleViewPrimaries, [.editor, .hex])
        XCTAssertFalse(m.visibleViewPrimaries.contains(.render))
    }

    /// CSV has a rich (table) lens + text + bytes → Render + Editor + HEX.
    func test_visiblePrimaries_csv_renderEditorHex() throws {
        let m = makeModel()
        m.open(url: try writeFile("data.csv", "a,b,c\n1,2,3\n"))
        XCTAssertEqual(m.visibleViewPrimaries, [.render, .editor, .hex])
    }

    /// A true binary (NUL-laden, never decodes as text) offers only bytes →
    /// the segmented group collapses to a single HEX segment (no Render, no
    /// Editor).
    func test_visiblePrimaries_binary_hexOnly() throws {
        let m = makeModel()
        var bytes: [UInt8] = []
        for i in 0..<2048 { bytes.append(UInt8((i &* 37) % 256)) }
        bytes[0] = 0x00; bytes[1] = 0xFF
        let url = tmpRoot.appendingPathComponent("blob.bak")
        try Data(bytes).write(to: url)
        m.open(url: url)
        XCTAssertEqual(m.availableViewModes, [.hex], "true binary offers only HEX")
        XCTAssertEqual(m.visibleViewPrimaries, [.hex],
                       "binary → a single HEX segment, no Render/Editor")
    }

    /// HEX is ALWAYS the trailing segment — every file with bytes offers it.
    func test_visiblePrimaries_alwaysIncludeHexLast() throws {
        let m = makeModel()
        for name in ["doc.md", "notes.txt", "code.swift", "data.csv", "config.json"] {
            m.open(url: try writeFile(name))
            let primaries = m.visibleViewPrimaries
            XCTAssertEqual(primaries.last, .hex, "\(name): HEX must be the trailing segment")
            XCTAssertEqual(primaries.filter { $0 == .hex }.count, 1,
                           "\(name): exactly one HEX segment")
        }
    }

    /// Tapping each visible segment routes through selectViewPrimary and the
    /// presentation's primary follows — i.e. selecting a segment sets p.primary.
    func test_segment_selection_setsPresentationPrimary() throws {
        let m = makeModel()
        m.open(url: try writeFile("doc.md", "# Hi\n"))
        for primary in m.visibleViewPrimaries {
            m.selectViewPrimary(primary, viewOnly: m.viewModePresentation.viewOnly)
            XCTAssertEqual(m.viewModePresentation.primary, primary,
                           "selecting the \(primary) segment must select it in the presentation")
        }
    }

    /// While the Format lens is active the Render/Editor segments read as
    /// NOT selected (Format owns the selection) — but HEX selection is
    /// independent of Format. This pins the segment-selection rule the
    /// segmented view's `isSelected(_:_:)` mirrors.
    func test_segment_selection_deselectedUnderFormat() throws {
        let m = makeModel()
        m.open(url: try writeFile("config.json", "{\"a\":1}"))
        m.toggleFormatLens()
        let p = m.viewModePresentation
        XCTAssertTrue(p.isFormatted)
        // Editor primary is reported but isFormatted is set → the segment
        // must render deselected (the toolbar gates on `&& !isFormatted`).
        XCTAssertEqual(p.primary, .editor)
        XCTAssertTrue(p.isFormatted, "Editor segment is NOT highlighted while Format is active")
    }

    // MARK: - LOADBUG SAFETY: control never desyncs picker from an unavailable mode

    func test_render_onSwift_doesNotForceRendered() throws {
        let m = makeModel()
        m.open(url: try writeFile("code.swift", "let x = 1\n"))
        // Tapping Render on a non-renderable type must NOT leave the model
        // in `.rendered` (the SC-MENU-01 desync). It resolves to .source.
        m.selectViewPrimary(.render, viewOnly: true)
        XCTAssertNotEqual(m.currentViewMode, .rendered)
        XCTAssertEqual(m.currentViewMode, .source)
    }

    // MARK: - Breadcrumb

    func test_breadcrumb_segmentsCoverPathToFile() throws {
        let m = makeModel()
        let sub = tmpRoot.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("file.swift")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        m.open(url: file)

        let crumbs = m.pathBreadcrumb
        XCTAssertFalse(crumbs.isEmpty)
        // Last segment is the file itself.
        let last = crumbs.last!
        XCTAssertTrue(last.isFile)
        XCTAssertEqual(last.name, "file.swift")
        XCTAssertEqual(last.url.lastPathComponent, "file.swift")
        // The intermediate folders appear in order.
        let names = crumbs.map(\.name)
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
        // Exactly one file segment.
        XCTAssertEqual(crumbs.filter(\.isFile).count, 1)
    }

    func test_breadcrumb_empty_whenNoFile() throws {
        let m = makeModel()
        XCTAssertTrue(m.pathBreadcrumb.isEmpty)
    }

    func test_navigateToBreadcrumb_folderSegment_revealsInSidebar() throws {
        let m = makeModel()
        let sub = tmpRoot.appendingPathComponent("proj/src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("main.swift")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        m.open(url: file)

        let crumbs = m.pathBreadcrumb
        // Find the "proj" folder segment.
        guard let proj = crumbs.first(where: { $0.name == "proj" }) else {
            return XCTFail("no 'proj' breadcrumb segment")
        }
        XCTAssertFalse(proj.isFile)
        m.navigateToBreadcrumb(proj)
        // revealInSidebar set the root (sidebar had none) to a folder
        // containing the target, and selected it. Compare on the
        // symlink-resolved path (tmp lives under /var → /private/var).
        XCTAssertNotNil(m.sidebar.rootURL)
        XCTAssertEqual(
            m.sidebar.selectedURL?.resolvingSymlinksInPath().path,
            proj.url.resolvingSymlinksInPath().path)
    }

    func test_navigateToBreadcrumb_fileSegment_selectsFile() throws {
        let m = makeModel()
        let file = try writeFile("readme.md", "# Hi\n")
        m.open(url: file)
        let last = m.pathBreadcrumb.last!
        XCTAssertTrue(last.isFile)
        m.navigateToBreadcrumb(last)
        XCTAssertEqual(
            m.sidebar.selectedURL?.resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path)
    }
}
