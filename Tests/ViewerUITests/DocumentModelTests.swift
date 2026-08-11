import XCTest
import ViewerKit
import ViewerCore
import RustCore
@testable import ViewerUI

/// Tier 1 main-actor tests for the top-level app model.
///
/// We don't mock the controller / loader — they're already fast and exercising
/// the real file path catches more bugs (the "vanishing tabs" bug surfaced
/// here was about how `tabs` republished, not anything mockable).
@MainActor
final class DocumentModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    // MARK: Find availability (TSK-947 — ⌘F gated off in HTML-rendered)

    func test_findIsAvailable_excludesOnlyHtmlRendered() {
        // HTML in rendered mode → NO find: HTMLRenderedView has no find runtime
        // (raw-HTML find is deferred) and hosts no find bar.
        XCTAssertFalse(DocumentModel.findIsAvailable(category: .html, viewMode: .rendered))
        // HTML in non-rendered modes → find available (source/editor host a bar).
        XCTAssertTrue(DocumentModel.findIsAvailable(category: .html, viewMode: .source))
        XCTAssertTrue(DocumentModel.findIsAvailable(category: .html, viewMode: .editor))
        // markdown/mermaid rendered → available (they host MarkdownFindBar).
        XCTAssertTrue(DocumentModel.findIsAvailable(category: .markdown, viewMode: .rendered))
        XCTAssertTrue(DocumentModel.findIsAvailable(category: .mermaid, viewMode: .rendered))
        // any other category → available regardless of mode.
        XCTAssertTrue(DocumentModel.findIsAvailable(category: .code, viewMode: .source))
        XCTAssertTrue(DocumentModel.findIsAvailable(category: .plainText, viewMode: .rendered))
        XCTAssertTrue(DocumentModel.findIsAvailable(category: nil, viewMode: .rendered))
    }

    // TSK-947 (second half): ⌘F gated when the editor is over the CM6 size cap
    // (the LargeEditorPlaceholderView has no CodeMirror → no find runtime).
    func test_findIsAvailable_gatesOverSizeCapEditor() {
        // Over the cap in EDITOR mode → NO find, regardless of category.
        XCTAssertFalse(DocumentModel.findIsAvailable(
            category: .code, viewMode: .editor, editorExceedsSizeCap: true))
        XCTAssertFalse(DocumentModel.findIsAvailable(
            category: .markdown, viewMode: .editor, editorExceedsSizeCap: true))
        // Under the cap → find available.
        XCTAssertTrue(DocumentModel.findIsAvailable(
            category: .code, viewMode: .editor, editorExceedsSizeCap: false))
        // The cap only gates EDITOR mode — a large file's source/rendered still find.
        XCTAssertTrue(DocumentModel.findIsAvailable(
            category: .code, viewMode: .source, editorExceedsSizeCap: true))
        XCTAssertTrue(DocumentModel.findIsAvailable(
            category: .markdown, viewMode: .rendered, editorExceedsSizeCap: true))
    }

    // MARK: Find focus routing (TSK-1248 — ⌘F defers to a focused control field)

    func test_shouldDeferFindToFocusedField_fieldEditorVsDocument() {
        let model = makeModel()
        // A field editor (a control's text field — e.g. the sidebar filter) → defer.
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true
        XCTAssertTrue(model.shouldDeferFindToFocusedField(fieldEditor),
                      "⌘F in a control's field editor must not open the doc find bar")
        // A plain (document) text view → don't defer.
        XCTAssertFalse(model.shouldDeferFindToFocusedField(NSTextView()))
        // nil first responder → don't defer.
        XCTAssertFalse(model.shouldDeferFindToFocusedField(nil))
        // EXCEPTION: a find bar already open → don't defer, so ⌘F still toggles
        // IT closed (the bar's own input is itself a field editor).
        model.isSourceFindBarPresented = true
        XCTAssertFalse(model.shouldDeferFindToFocusedField(fieldEditor),
                       "with a find bar open, ⌘F must still toggle it (not defer)")
    }

    // MARK: Palette focus (TSK-906 — dismiss refocuses the editor)

    func test_dismissPalette_requestsEditorRefocus() {
        let model = makeModel()
        XCTAssertEqual(model.editorFocusRequest, 0)
        model.showPalette()
        XCTAssertTrue(model.isPalettePresented)
        XCTAssertEqual(model.editorFocusRequest, 0, "showing the palette does not bump the refocus nonce")
        model.dismissPalette()
        XCTAssertFalse(model.isPalettePresented)
        XCTAssertEqual(model.editorFocusRequest, 1, "dismiss bumps the refocus nonce (→ editor re-takes focus)")
        model.showPalette(); model.dismissPalette()
        XCTAssertEqual(model.editorFocusRequest, 2, "each dismiss bumps")
    }

    // MARK: Canvas file routing (TSK-1364/M1.S9b)

    /// A .canvas file (the engine's canonical JSON) opens through the STANDARD
    /// text pipeline into the source lens — thereby inheriting autosave,
    /// hot-exit, and TabSnapshot behavior with zero canvas-specific forks.
    /// Uses a REAL engine-produced document (Rust save()), not a hand fake.
    func test_canvasFile_opensLoaded_sourceMode_editableText() throws {
        let session = try CanvasDocSession()
        _ = try session.apply(
            baseRev: 0,
            ops: [
                .insert(
                    id: "nd:t", kind: "text", parent: CanvasDocSession.rootPage,
                    pos: .last, props: [("text", .str("from the engine"))])
            ])
        let json = try session.save()

        let model = makeModel()
        let f = try writeFile("design.canvas", json)
        model.open(url: f)
        guard case .loaded(let doc) = model.tabs.selected?.state else {
            XCTFail("expected .loaded, got \(String(describing: model.tabs.selected?.state))")
            return
        }
        XCTAssertEqual(model.currentViewMode, .rendered, "M3.S7: rendered is the default lens")
        let shown = model.displayedText(for: doc).text
        XCTAssertTrue(shown.contains("\"formatVersion\":1"))
        XCTAssertTrue(shown.contains("from the engine"))
        // The round trip holds: what the editor shows reloads in the engine.
        let reloaded = try CanvasDocSession.load(json: shown)
        XCTAssertTrue(try reloaded.html().contains(">from the engine<"))
    }

    // MARK: Preview focus (TSK-905 — active rendered preview takes first responder)

    /// The active rendered preview requests first-responder focus when it
    /// becomes active (so ↑/↓/PageUp scroll it) — and a redundant refresh of the
    /// SAME preview must NOT re-grab focus (the over-grab guard: this is what a
    /// regression to "bump on every derived refresh" would trip).
    func test_previewFocusRequest_bumpsOnRenderedActivation_notOnRedundantRefresh() throws {
        let model = makeModel()
        XCTAssertEqual(model.previewFocusRequest, 0)

        let a = try writeFile("a.md", "# A\n")
        model.open(url: a)
        model.setCurrentViewMode(.rendered)
        XCTAssertEqual(model.currentViewMode, .rendered, "markdown can show a rendered preview")
        let afterA = model.previewFocusRequest
        XCTAssertGreaterThan(afterA, 0, "activating a rendered preview requests focus")

        // Redundant refresh of the SAME preview → no bump (no focus stealing).
        model.selectTab(at: 0)
        XCTAssertEqual(model.previewFocusRequest, afterA,
                       "re-selecting the same rendered preview must not re-grab focus")

        // A second rendered file = a different active preview → bump.
        let b = try writeFile("b.md", "# B\n")
        model.open(url: b)
        model.setCurrentViewMode(.rendered)
        let afterB = model.previewFocusRequest
        XCTAssertGreaterThan(afterB, afterA,
                             "switching to a different rendered preview requests focus")

        // Switching back to A's preview is again a change → bump.
        model.selectTab(at: 0)
        XCTAssertGreaterThan(model.previewFocusRequest, afterB,
                             "switching back to A's rendered preview requests focus")
    }

    /// Leaving a rendered preview for a non-rendered mode (the editor) does not
    /// request preview focus — only rendered previews are focus targets.
    func test_previewFocusRequest_silentForNonRenderedModes() throws {
        let md = try writeFile("doc.md", "# A\n")
        let model = makeModel()
        model.open(url: md)
        model.setCurrentViewMode(.rendered)
        let afterRendered = model.previewFocusRequest
        XCTAssertGreaterThan(afterRendered, 0)

        model.setCurrentViewMode(.editor)
        XCTAssertEqual(model.previewFocusRequest, afterRendered,
                       "leaving rendered for the editor does not request preview focus")
    }

    // MARK: Esc → return focus to the active document (TSK-938)

    /// In EDITOR mode, an Esc fired while focus is on a tool surface
    /// (`currentFocusIsDocument == false`) bumps the editor focus nonce so the
    /// CM6 editor re-takes first responder; the preview nonce is untouched.
    func test_returnFocusToActiveDocument_editorMode_bumpsEditorNonce() throws {
        let f = try writeFile("note.txt", "hello\n")
        let model = makeModel()
        model.open(url: f)
        model.setCurrentViewMode(.editor)
        let editorBefore = model.editorFocusRequest
        let previewBefore = model.previewFocusRequest

        let handled = model.returnFocusToActiveDocument(currentFocusIsDocument: false)
        XCTAssertTrue(handled, "Esc from a tool surface in editor mode is handled")
        XCTAssertEqual(model.editorFocusRequest, editorBefore + 1,
                       "editor focus nonce bumps → CM6 re-takes first responder")
        XCTAssertEqual(model.previewFocusRequest, previewBefore,
                       "preview nonce is not touched in editor mode")
    }

    /// In RENDERED mode, the same Esc bumps the preview focus nonce instead.
    func test_returnFocusToActiveDocument_renderedMode_bumpsPreviewNonce() throws {
        let md = try writeFile("doc.md", "# A\n")
        let model = makeModel()
        model.open(url: md)
        model.setCurrentViewMode(.rendered)
        let editorBefore = model.editorFocusRequest
        let previewBefore = model.previewFocusRequest

        let handled = model.returnFocusToActiveDocument(currentFocusIsDocument: false)
        XCTAssertTrue(handled, "Esc from a tool surface in rendered mode is handled")
        XCTAssertEqual(model.previewFocusRequest, previewBefore + 1,
                       "preview focus nonce bumps → rendered WKWebView re-takes first responder")
        XCTAssertEqual(model.editorFocusRequest, editorBefore,
                       "editor nonce is not touched in rendered mode")
    }

    /// Over-grab guard (mirrors TSK-905's no-regrab test): when focus is ALREADY
    /// on the document, Esc is a no-op — no nonce moves, so focus is never
    /// stolen from a caret/scroll position the document already holds.
    func test_returnFocusToActiveDocument_noOpWhenAlreadyOnDocument() throws {
        let f = try writeFile("note.txt", "hello\n")
        let model = makeModel()
        model.open(url: f)
        model.setCurrentViewMode(.editor)
        let editorBefore = model.editorFocusRequest
        let previewBefore = model.previewFocusRequest

        let handled = model.returnFocusToActiveDocument(currentFocusIsDocument: true)
        XCTAssertFalse(handled, "already-on-document Esc is not handled (passes through)")
        XCTAssertEqual(model.editorFocusRequest, editorBefore,
                       "no over-grab: editor nonce unchanged when already focused")
        XCTAssertEqual(model.previewFocusRequest, previewBefore,
                       "no over-grab: preview nonce unchanged when already focused")
    }

    /// No active document ⇒ nothing to focus, so Esc is a no-op even from a tool
    /// surface (no tab open, e.g. the welcome screen).
    func test_returnFocusToActiveDocument_noOpWithNoOpenDocument() {
        let model = makeModel()
        XCTAssertNil(model.tabs.selected, "no document open")
        let editorBefore = model.editorFocusRequest
        let previewBefore = model.previewFocusRequest

        let handled = model.returnFocusToActiveDocument(currentFocusIsDocument: false)
        XCTAssertFalse(handled, "no document ⇒ nothing to focus")
        XCTAssertEqual(model.editorFocusRequest, editorBefore)
        XCTAssertEqual(model.previewFocusRequest, previewBefore)
    }

    /// Modes with no nonce-driven document-focus target (Source / HEX, an
    /// NSTextView/byte-grid that owns its own first responder) are not handled by
    /// the model nonce path — the model returns false so the UI key handler can
    /// fall back to its own `makeFirstResponder` rather than the model
    /// pretending it focused something. No nonce is moved.
    func test_returnFocusToActiveDocument_noNonceForSourceOrHexModes() throws {
        let f = try writeFile("data.txt", "hello\n")
        let model = makeModel()
        model.open(url: f)

        for mode in [ViewMode.source, .hex] {
            model.setCurrentViewMode(mode)
            let editorBefore = model.editorFocusRequest
            let previewBefore = model.previewFocusRequest
            let handled = model.returnFocusToActiveDocument(currentFocusIsDocument: false)
            XCTAssertFalse(handled, "\(mode) has no nonce-driven document-focus target")
            XCTAssertEqual(model.editorFocusRequest, editorBefore, "\(mode): no editor bump")
            XCTAssertEqual(model.previewFocusRequest, previewBefore, "\(mode): no preview bump")
        }
    }

    // MARK: Esc focus classifier (TSK-938 — EscFocusMonitor pure helper)

    /// The CM6 editor webview (or a descendant) is a DOCUMENT surface — Esc
    /// there is a no-op. Uses a plain NSView for the "editor" (a WKWebView is
    /// one) so the test needs no live WebView, the same shape SidebarKeyMonitor
    /// uses.
    func test_escClassifier_editorWebviewIsDocument() {
        let editor = NSView()
        let child = NSView()
        editor.addSubview(child)
        XCTAssertTrue(EscFocusMonitor.firstResponderIsDocument(editor, editorViews: [editor]),
                      "the editor view itself is a document surface")
        XCTAssertTrue(EscFocusMonitor.firstResponderIsDocument(child, editorViews: [editor]),
                      "a descendant of the editor is a document surface")
    }

    /// TSK-1280 (same class as the Enter leak): MountedPanesLRU mounts several
    /// editor panes; the focused pane may not be the topmost current(). Esc in
    /// the SECOND (focused) pane must still classify as a document surface.
    func test_escClassifier_secondMountedEditorIsDocument_multiPane() {
        let pane1 = NSView()            // inactive mounted pane (old current())
        let pane2 = NSView()            // focused pane
        let child2 = NSView()
        pane2.addSubview(child2)
        XCTAssertTrue(
            EscFocusMonitor.firstResponderIsDocument(child2, editorViews: [pane1, pane2]),
            "focus inside any mounted editor is a document surface (multi-pane)")
        // Teeth: with only the inactive pane known (the old current() behaviour),
        // the same responder would be mis-classified as a tool surface → Esc
        // mis-routed; the all-editors check closes this.
        XCTAssertFalse(
            EscFocusMonitor.firstResponderIsDocument(child2, editorViews: [pane1]),
            "control: responder outside the only known editor is not a document (old bug)")
    }

    /// A bare NSView first-responder that is neither the editor, a WKWebView, nor
    /// an NSText inside the content root (here: a sidebar/tool view) is NOT a
    /// document surface — Esc returns focus to the document.
    func test_escClassifier_toolViewIsNotDocument() {
        let editor = NSView()
        let toolView = NSView()   // e.g. the sidebar outline view
        XCTAssertFalse(EscFocusMonitor.firstResponderIsDocument(toolView, editorViews: [editor]),
                       "a non-editor non-webview tool view is not a document surface")
        XCTAssertFalse(EscFocusMonitor.firstResponderIsDocument(nil, editorViews: [editor]),
                       "no first responder is not a document surface")
        XCTAssertFalse(EscFocusMonitor.firstResponderIsDocument(toolView, editorViews: []),
                       "no editor registered + a tool view is not a document surface")
    }

    /// An NSText (NSTextView / field editor) counts as a document surface ONLY
    /// when it lives inside the content root: the Source/Formatted pane is a
    /// document NSTextView, but a search field / rename prompt is not.
    func test_escClassifier_nsTextScopedToContentRoot() {
        let editor = NSView()
        let contentRoot = NSView()
        let sourcePane = NSTextView()           // a document NSTextView…
        contentRoot.addSubview(sourcePane)
        XCTAssertTrue(
            EscFocusMonitor.firstResponderIsDocument(
                sourcePane, editorViews: [editor], contentRoot: contentRoot),
            "an NSText inside the content root is a document surface")

        let searchField = NSTextView()          // …vs a tool-surface NSText
        XCTAssertFalse(
            EscFocusMonitor.firstResponderIsDocument(
                searchField, editorViews: [editor], contentRoot: contentRoot),
            "an NSText OUTSIDE the content root is a tool surface, not a document")
    }

    // MARK: Language detection from shebang (TSK-901)

    func test_effectiveLanguage_fallsBackToShebang_forExtensionlessScript() throws {
        let model = makeModel()
        let script = tmpDir.appendingPathComponent("deploy")   // no extension
        try "#!/bin/bash\necho hello\n".write(to: script, atomically: true, encoding: .utf8)
        model.open(url: script)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        // No extension → detect(from:url) is .plainText; the bash shebang upgrades it.
        XCTAssertEqual(model.effectiveLanguage(forTabID: id, url: script), .shell,
                       "an extensionless script with a bash shebang highlights as shell")
    }

    // MARK: Vim mode (TSK-679 — View → Vim Mode preference)

    func test_toggleEditorReadOnly_flips_sessionLevel() {
        let model = makeModel()
        XCTAssertFalse(model.isEditorReadOnly, "defaults to editable")
        model.toggleEditorReadOnly()
        XCTAssertTrue(model.isEditorReadOnly)
        model.toggleEditorReadOnly()
        XCTAssertFalse(model.isEditorReadOnly)
        // Session-level (not persisted): a fresh model over the same defaults is editable.
        model.toggleEditorReadOnly()
        XCTAssertFalse(makeModel().isEditorReadOnly, "read-only is not a sticky default")
    }

    func test_vimModeEnabled_proxiesPreferences_andSeedsOnInit() {
        let model = makeModel()
        XCTAssertFalse(model.vimModeEnabled, "defaults to off (opt-in)")

        model.toggleVimMode()
        XCTAssertTrue(model.vimModeEnabled)
        // didSet persists through PreferencesStore…
        XCTAssertTrue(PreferencesStore(defaults: defaults).vimModeEnabled)
        // …and a fresh model over the same defaults seeds from it on init.
        XCTAssertTrue(makeModel().vimModeEnabled)
    }

    // MARK: Markdown overview (TSK-305 — View → Markdown Overview preference)

    func test_showMarkdownOverview_proxiesPreferences_andSeedsOnInit() {
        let model = makeModel()
        XCTAssertTrue(model.showMarkdownOverview, "on by default")

        // The menu action toggles it OFF; that must persist + reseed.
        model.toggleMarkdownOverview()
        XCTAssertFalse(model.showMarkdownOverview)
        XCTAssertFalse(PreferencesStore(defaults: defaults).showMarkdownOverview)
        XCTAssertFalse(makeModel().showMarkdownOverview,
                       "a fresh model over the same defaults seeds from prefs")

        // Toggling back ON round-trips.
        model.toggleMarkdownOverview()
        XCTAssertTrue(model.showMarkdownOverview)
        XCTAssertTrue(makeModel().showMarkdownOverview)
    }

    func test_setEditorVimMode_normalizesAndClears() {
        let model = makeModel()
        XCTAssertEqual(model.editorVimMode, "", "off by default")
        model.setEditorVimMode("normal")
        XCTAssertEqual(model.editorVimMode, "NORMAL", "uppercased for the footer chip")
        model.setEditorVimMode("visual-block")
        XCTAssertEqual(model.editorVimMode, "VISUAL-BLOCK")
        model.setEditorVimMode("")
        XCTAssertEqual(model.editorVimMode, "", "empty clears the chip")
    }

    // MARK: Audio ffmpeg path (TSK-528/535 — Settings → Audio proxy)

    func test_audioFFmpegPath_proxiesPreferences_andSeedsOnInit() {
        let model = makeModel()
        XCTAssertNil(model.audioFFmpegPath, "defaults to auto-detect (nil)")

        model.audioFFmpegPath = "/opt/homebrew/bin/ffmpeg"
        // didSet persists through PreferencesStore…
        XCTAssertEqual(PreferencesStore(defaults: defaults).audioFFmpegPath,
                       "/opt/homebrew/bin/ffmpeg")
        // …and a fresh model over the same defaults seeds from it on init.
        XCTAssertEqual(makeModel().audioFFmpegPath, "/opt/homebrew/bin/ffmpeg")

        model.audioFFmpegPath = nil   // clearing reverts to auto-detect
        XCTAssertNil(PreferencesStore(defaults: defaults).audioFFmpegPath)
        XCTAssertNil(makeModel().audioFFmpegPath)
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: View Only shows unsaved edits (TSK-729)

    func test_displayedText_showsDirtyEditorBuffer_notDiskContents() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "on disk\n")
        model.open(url: url)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        guard case .loaded(let file) = model.tabs.selected?.state else {
            return XCTFail("tab did not load")
        }
        // Clean buffer (or none): View Only shows the on-disk text.
        XCTAssertEqual(model.displayedText(for: file).text, "on disk\n")

        // Dirty: edit the live buffer, then View Only must show the EDITED text.
        _ = model.editorBuffer(forTabID: id)            // materialize the buffer
        model.updateEditorText("edited live\n", forTabID: id)
        let shown = model.displayedText(for: file)
        XCTAssertEqual(shown.text, "edited live\n",
            "View Only (.source) must reflect unsaved edits, not stale on-disk content")
        XCTAssertEqual(shown.byteLength, "edited live\n".utf8.count,
            "byteLength must match the displayed (edited) text, not the on-disk byteCount")
    }

    // MARK: Split pane shows unsaved edits, keyed by the SPLIT file (TSK-806)

    func test_splitPaneText_showsDirtyBufferOfTheSplitFile_notSelectedTab() throws {
        let model = makeModel()
        let split = try writeFile("split.txt", "split on disk\n")
        let other = try writeFile("other.txt", "other on disk\n")

        // Clean / not-open: fall back to on-disk contents.
        XCTAssertEqual(model.splitPaneText(for: split, fallback: "split on disk\n"),
                       "split on disk\n", "no open/dirty buffer ⇒ on-disk text")

        // Open the split file, dirty its buffer.
        model.open(url: split)
        let splitID = try XCTUnwrap(model.tabs.selected?.id)
        _ = model.editorBuffer(forTabID: splitID)
        model.updateEditorText("split EDITED\n", forTabID: splitID)

        // Open a DIFFERENT file and select it (the active tab is now `other`,
        // with its own dirty edit) — the split must still reflect SPLIT's edits,
        // not the selected tab's (the `displayedText(for:)` cross-file hazard).
        model.open(url: other)
        let otherID = try XCTUnwrap(model.tabs.selected?.id)
        _ = model.editorBuffer(forTabID: otherID)
        model.updateEditorText("other EDITED\n", forTabID: otherID)
        XCTAssertNotEqual(splitID, otherID, "two distinct tabs")

        XCTAssertEqual(model.splitPaneText(for: split, fallback: "split on disk\n"),
                       "split EDITED\n",
                       "split pane shows the SPLIT file's unsaved edits, keyed by URL — not the selected tab's")
    }

    // MARK: Status footer gate — folder-only context (TSK-738)

    func test_hasOpenContext_trueForFolderOnly_whenNoFileTabSelected() throws {
        let model = makeModel()
        XCTAssertFalse(model.hasOpenContext, "nothing open yet")
        let folder = tmpDir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        XCTAssertNil(model.currentURL,
            "openFolder selects no file tab — the OLD `currentURL != nil` gate hid the footer (the bug)")
        XCTAssertTrue(model.hasOpenContext,
            "the status footer must still mount for a folder-only project (TSK-738)")
    }

    func test_hasOpenContext_trueWhenFileOpen() throws {
        let model = makeModel()
        let f = try writeFile("a.txt", "x")
        model.open(url: f)
        XCTAssertNotNil(model.currentURL)
        XCTAssertTrue(model.hasOpenContext)
    }

    // MARK: Initial state

    func test_initial_isEmpty() {
        let model = makeModel()
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.currentURL)
        if case .empty = model.currentState {} else {
            XCTFail("expected .empty initial state")
        }
        // App was renamed to TextView (commit dab1759); ensure the
        // default window title matches what users see in Finder.
        XCTAssertEqual(model.windowTitle, "TextView")
    }

    // MARK: Opening files

    func test_open_addsLoadedTab() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# hi")
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
        if case .loaded(let file) = model.currentState {
            XCTAssertEqual(file.contents, "# hi")
        } else {
            XCTFail("expected .loaded")
        }
        XCTAssertEqual(model.recents.count, 1)
    }

    /// Status-bar data source (TSK-452): switching tabs must surface the
    /// SELECTED tab's loaded file, never a stale or blank one. `StatusBar`
    /// reads `currentState` / `currentURL` (both computed from `tabs.selected`)
    /// and re-bodies on the `@Published tabs` the coordinator fires on select.
    /// This pins the model contract headlessly; the SwiftUI re-body itself is
    /// the only part that needs a live tier.
    func test_selectTab_statusBarDataSourceTracksSelectedFile() throws {
        let model = makeModel()
        let a = try writeFile("three.txt", "l1\nl2\nl3\n")
        let b = try writeFile("one.txt", "single\n")
        model.open(url: a)
        model.open(url: b)

        model.selectTab(at: 0)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "three.txt")
        guard case .loaded(let fa) = model.currentState else {
            return XCTFail("tab 0 should be loaded — status bar would blank otherwise")
        }
        XCTAssertEqual(fa.contents, "l1\nl2\nl3\n")

        model.selectTab(at: 1)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "one.txt")
        guard case .loaded(let fb) = model.currentState else {
            return XCTFail("tab 1 should be loaded — status bar would blank otherwise")
        }
        XCTAssertEqual(fb.contents, "single\n")

        // Switch back — must track the selected file, not stick on the previous.
        model.selectTab(at: 0)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "three.txt")
        if case .loaded(let fa2) = model.currentState {
            XCTAssertEqual(fa2.contents, "l1\nl2\nl3\n")
        } else {
            XCTFail("tab 0 should be loaded again after switching back")
        }
    }

    func test_open_sameURLTwice_doesNotCreateDuplicateTab() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        let b = try writeFile("b.md")
        model.open(url: a)
        model.open(url: b)
        model.open(url: a)  // re-open a
        XCTAssertEqual(model.tabs.tabs.count, 2,
                       "re-opening an already-open file should switch, not append")
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    func test_open_missingFile_keepsExistingTabAndAppendsError() throws {
        let model = makeModel()
        let existing = try writeFile("ok.md")
        model.open(url: existing)
        XCTAssertEqual(model.tabs.tabs.count, 1)

        let ghost = tmpDir.appendingPathComponent("never.md")
        model.open(url: ghost)

        // The original tab is still there — this is the regression that read
        // as "all tabs vanished" before the fix.
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertEqual(model.tabs.tabs[0].url?.lastPathComponent, "ok.md")
        if case .error = model.tabs.tabs[1].state {} else {
            XCTFail("expected .error in second tab")
        }
    }

    func test_open_failedLoad_isNotRecordedInRecents() throws {
        let model = makeModel()
        let ghost = tmpDir.appendingPathComponent("never.md")
        model.open(url: ghost)
        XCTAssertTrue(model.recents.isEmpty, "failed opens should not pollute recents")
    }

    // MARK: Tab management

    func test_newTab_appendsBlank() throws {
        let model = makeModel()
        model.newTab()
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertTrue(model.tabs.tabs[0].isBlank)
    }

    func test_open_reusesBlankTab() throws {
        let model = makeModel()
        model.newTab()
        let url = try writeFile("a.md")
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1,
                       "blank tab should host the new file rather than appending")
        XCTAssertEqual(model.tabs.tabs[0].url, url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Regression: a freshly opened native-preview file (sqlite/image/
    /// audio/video/pdf) must STAY in its `.preview` document state AND
    /// select the first-class `.preview` ViewMode (Bug B). The old
    /// `ViewModeOptions.defaultMode` returned `.hex` for these categories,
    /// so the picker selected HEX even though the content was a native
    /// preview — the byte grid was one click away, and the persisted
    /// snapshot carried `.hex`. The old hex-mode carry block in
    /// `openResolved`/`materializeIfNeeded` could also kick
    /// `loadBinaryAsync` and replace the native viewer with a hex dump.
    /// `controller.open` for a preview category only stats the file (no
    /// parse), so a readable `.db` is enough to exercise the routing.
    func test_open_sqlite_staysPreview_doesNotFlipToHex() async throws {
        let model = makeModel()
        let url = try writeFile("data.db", "SQLite format 3\u{0}")
        model.open(url: url)
        // Bug B: the selected ViewMode must be the native Preview lens, NOT
        // HEX — the content is rendered via the `.preview` document state.
        XCTAssertEqual(model.tabs.selected?.viewMode, .preview,
                       "fresh sqlite open must select Preview mode, not HEX")
        if case .preview(_, let cat) = model.currentState {
            XCTAssertEqual(cat, .sqlite)
        } else {
            XCTFail("expected .preview(sqlite) immediately after open, got \(model.currentState)")
        }
        // Let any detached loadBinaryAsync hop back to the main actor.
        try await Task.sleep(nanoseconds: 200_000_000)
        if case .preview(_, let cat) = model.currentState {
            XCTAssertEqual(cat, .sqlite, "sqlite preview must not be replaced by a hex dump")
        } else {
            XCTFail("expected .preview(sqlite) to persist, got \(model.currentState)")
        }
    }

    func test_closeCurrentTab_dropsAndShiftsSelection() throws {
        let model = makeModel()
        try [("a.md","a"), ("b.md","b"), ("c.md","c")].forEach {
            let url = try writeFile($0.0, $0.1)
            model.open(url: url)
        }
        XCTAssertEqual(model.tabs.tabs.count, 3)
        model.selectTab(at: 1)  // /b
        model.closeCurrentTab()
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "c.md",
                       "closing the middle tab should select its right neighbor")
    }

    func test_selectNextTab_wraps() throws {
        let model = makeModel()
        for name in ["a", "b", "c"] {
            let url = try writeFile("\(name).md")
            model.open(url: url)
        }
        // selected = 2 (c). Next should wrap to 0 (a).
        model.selectNextTab()
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    func test_selectPreviousTab_wraps() throws {
        let model = makeModel()
        for name in ["a", "b", "c"] {
            let url = try writeFile("\(name).md")
            model.open(url: url)
        }
        model.selectTab(at: 0)
        model.selectPreviousTab()
        XCTAssertEqual(model.currentURL?.lastPathComponent, "c.md")
    }

    // MARK: View mode

    func test_toggleViewMode_flipsCurrentTabOnly() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        let b = try writeFile("b.md")
        model.open(url: a)
        model.open(url: b)
        model.selectTab(at: 0)
        XCTAssertEqual(model.currentViewMode, .rendered)
        model.toggleViewMode()
        XCTAssertEqual(model.currentViewMode, .source)
        // Switching to the other tab still shows .rendered (default).
        model.selectTab(at: 1)
        XCTAssertEqual(model.currentViewMode, .rendered)
        // And switching back preserves the per-tab mode.
        model.selectTab(at: 0)
        XCTAssertEqual(model.currentViewMode, .source)
    }

    func test_supportsViewModeToggle_onlyForMarkdown() throws {
        let model = makeModel()
        let txt = try writeFile("notes.txt")
        let md  = try writeFile("readme.md")
        model.open(url: txt)
        XCTAssertFalse(model.supportsViewModeToggle)
        model.open(url: md)
        XCTAssertTrue(model.supportsViewModeToggle)
    }

    // MARK: Reload

    func test_reloadCurrentFile_picksUpDiskChanges() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "v1")
        model.open(url: url)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        model.reloadCurrentFile()
        if case .loaded(let f) = model.currentState {
            XCTAssertEqual(f.contents, "v2")
        } else {
            XCTFail("expected .loaded")
        }
    }

    // MARK: Folder

    func test_openFolder_setsSidebarRoot() throws {
        let model = makeModel()
        let folder = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        XCTAssertEqual(model.sidebar.rootURL?.resolvingSymlinksInPath(),
                       folder.resolvingSymlinksInPath())
        XCTAssertTrue(model.sidebar.isVisible)
    }

    // MARK: Sidebar width

    func test_sidebarWidth_isClampedAndPersisted() {
        let model = makeModel()
        model.setSidebarWidth(50)  // below the 160 floor
        XCTAssertEqual(model.sidebarWidth, PreferencesStore.minSidebarWidth)
        // Reloading the model from the same defaults reads back the clamped value.
        let model2 = makeModel()
        XCTAssertEqual(model2.sidebarWidth, PreferencesStore.minSidebarWidth)
    }

    func test_setSidebarWidthLive_doesNotPersistUntilPersist() {
        let model = makeModel()
        model.setSidebarWidthLive(300)
        XCTAssertEqual(model.sidebarWidth, 300)
        // A fresh model from the same defaults still reads the original value
        // because we never called persist.
        let model2 = makeModel()
        XCTAssertNotEqual(model2.sidebarWidth, 300)

        // Now persist and the next model picks it up.
        model.persistSidebarWidth()
        let model3 = makeModel()
        XCTAssertEqual(model3.sidebarWidth, 300)
    }

    // MARK: Context-menu commands (Close Others / Close to the Right / Open in New Tab)

    func test_closeOtherTabs_keepsOne() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        XCTAssertEqual(model.tabs.tabs.count, 3)
        model.closeOtherTabs(keeping: 1)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "b.md")
    }

    func test_closeTabsToRight_removesTrailing() throws {
        let model = makeModel()
        for n in ["a", "b", "c", "d"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.selectTab(at: 1)
        model.closeTabsToRight(of: 1)
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent },
                       ["a.md", "b.md"])
        XCTAssertEqual(model.currentURL?.lastPathComponent, "b.md")
    }

    func test_openInNewTab_doesNotReuseExistingTab() throws {
        let model = makeModel()
        let a = try writeFile("a.md")
        model.open(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        // Standard open() reuses the existing tab; openInNewTab forces append.
        model.openInNewTab(a)
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    // MARK: Move-tab shortcuts

    func test_moveCurrentTabLeft() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        // Selected = c (last).
        model.moveCurrentTabLeft()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent },
                       ["a.md", "c.md", "b.md"])
        // Selection follows the moved tab.
        XCTAssertEqual(model.currentURL?.lastPathComponent, "c.md")
    }

    func test_moveCurrentTabRight() throws {
        let model = makeModel()
        for n in ["a", "b", "c"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.selectTab(at: 0)  // select /a
        model.moveCurrentTabRight()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent },
                       ["b.md", "a.md", "c.md"])
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.md")
    }

    func test_moveTabLeft_atFirst_isNoOp() throws {
        let model = makeModel()
        for n in ["a", "b"] {
            model.open(url: try writeFile("\(n).md"))
        }
        model.selectTab(at: 0)
        let before = model.tabs.tabs.map { $0.url?.lastPathComponent }
        model.moveCurrentTabLeft()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent }, before)
    }

    func test_moveTabRight_atLast_isNoOp() throws {
        let model = makeModel()
        for n in ["a", "b"] {
            model.open(url: try writeFile("\(n).md"))
        }
        // Selected = b (last).
        let before = model.tabs.tabs.map { $0.url?.lastPathComponent }
        model.moveCurrentTabRight()
        XCTAssertEqual(model.tabs.tabs.map { $0.url?.lastPathComponent }, before)
    }

    // MARK: T7 — watcher rotates on tab select

    func test_selectTab_rotatesFileWatcher() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "v1-a")
        let b = try writeFile("b.md", "v1-b")
        model.open(url: a)
        model.open(url: b)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "b.md")

        // Mutate `a` while `b` is selected — no reload should happen on `b`
        // (CRIT-4: watcher events for `a` must not corrupt `b`'s state).
        // Old version used a fixed Thread.sleep(0.2); on a slow VM the
        // watcher could still fire after that window and the bug would
        // slip through. Instead, poll for ~1.5 s: at every sample point
        // we assert b is still v1-b. The instant the watcher
        // misbehaves, the test catches it.
        try "v2-a".write(to: a, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(1.5)
        var samples = 0
        while Date() < deadline {
            if case .loaded(let f) = model.tabs.tabs[1].state {
                XCTAssertEqual(f.contents, "v1-b",
                    "b must remain v1-b even though a was mutated")
            }
            samples += 1
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(samples, 5,
            "poll budget should fit at least a handful of samples")

        // Now switch to `a` and reload — should pick up the new contents.
        model.selectTab(at: 0)
        model.reloadCurrentFile()
        if case .loaded(let f) = model.currentState {
            XCTAssertEqual(f.contents, "v2-a")
        } else {
            XCTFail("expected .loaded")
        }
    }

    // MARK: - Split pane

    func test_openInSplit_setsSplitURL_andPublishesChange() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "# a\n")
        XCTAssertNil(model.splitURL, "fresh model has no split open")
        XCTAssertFalse(model.isSplitOpen)
        model.openInSplit(a)
        XCTAssertNotNil(model.splitURL,
            "openInSplit must stash the URL on splitURL")
        XCTAssertTrue(model.isSplitOpen,
            "isSplitOpen must reflect splitURL != nil")
        XCTAssertEqual(
            model.splitURL?.standardizedFileURL.resolvingSymlinksInPath(),
            a.standardizedFileURL.resolvingSymlinksInPath(),
            "splitURL must be normalized but content-equal to the input")
    }

    func test_openInSplit_thenClose_resetsSplitURL() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "# a\n")
        model.openInSplit(a)
        XCTAssertNotNil(model.splitURL)
        model.closeSplit()
        XCTAssertNil(model.splitURL,
            "closeSplit must clear splitURL back to nil")
        XCTAssertFalse(model.isSplitOpen)
    }

    func test_toggleSplit_opensWithCurrentFile_thenCloses() throws {
        // I-19 (2026-08-11): the PANE contract now belongs to files without
        // a rendered preview (markdown routes to the per-tab layout —
        // pinned in SplitEditingModeTests/DocumentModelSplitTests).
        let model = makeModel()
        let a = try writeFile("a.txt", "text\n")
        model.open(url: a)
        XCTAssertFalse(model.isSplitOpen)
        model.toggleSplit()
        XCTAssertTrue(model.isSplitOpen,
            "toggleSplit on a model with a current file must open the split")
        XCTAssertEqual(
            model.splitURL?.standardizedFileURL.resolvingSymlinksInPath(),
            a.standardizedFileURL.resolvingSymlinksInPath())
        model.toggleSplit()
        XCTAssertFalse(model.isSplitOpen,
            "toggleSplit on an open split must close it")
    }

    // MARK: - Unified zoom (drives both content + chrome via uiSize)

    func test_uiSize_multiplies_base_by_zoom() {
        let model = makeModel()
        model.zoom = 1.5
        XCTAssertEqual(model.uiSize(10), 15, accuracy: 0.001)
        XCTAssertEqual(model.uiSize(12), 18, accuracy: 0.001)
    }

    func test_uiSize_is_identity_when_zoom_is_one() {
        let model = makeModel()
        model.zoom = 1.0
        XCTAssertEqual(model.uiSize(10), 10, accuracy: 0.001)
        XCTAssertEqual(model.uiSize(7.5), 7.5, accuracy: 0.001)
    }

    /// Cmd++ should scale chrome too — same lever as document content.
    func test_zoomIn_grows_uiSize_proportionally() {
        let model = makeModel()
        model.zoom = 1.0
        let before = model.uiSize(10)
        model.zoomIn()
        let after = model.uiSize(10)
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(after / before, model.zoom, accuracy: 0.001)
    }

    /// TSK-1110: the extracted zoom controls (DocumentModel+Zoom) clamp to the
    /// PreferencesStore bounds and zoomReset returns the 1.0 baseline.
    func test_zoomControls_clampToBounds_andReset() {
        let model = makeModel()
        for _ in 0..<100 { model.zoomIn() }
        XCTAssertEqual(model.zoom, PreferencesStore.maxZoom, accuracy: 0.0001, "zoomIn clamps at maxZoom")
        for _ in 0..<100 { model.zoomOut() }
        XCTAssertEqual(model.zoom, PreferencesStore.minZoom, accuracy: 0.0001, "zoomOut clamps at minZoom")
        model.zoomReset()
        XCTAssertEqual(model.zoom, 1.0, accuracy: 0.0001, "zoomReset returns to 1.0")
    }

    // MARK: - showInvisibleChars (Batch A)

    func test_showInvisibleChars_seeds_and_persists() {
        let prefs = PreferencesStore(defaults: defaults)
        prefs.showInvisibleChars = true
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: prefs
        )
        XCTAssertTrue(model.showInvisibleChars)
        model.toggleShowInvisibleChars()
        XCTAssertFalse(model.showInvisibleChars)
        XCTAssertFalse(prefs.showInvisibleChars,
                       "didSet should write through to preferences")
    }

    // MARK: - editorIndentGuides (TSK-487)

    func test_editorIndentGuides_seeds_and_persists() {
        let prefs = PreferencesStore(defaults: defaults)
        prefs.editorIndentGuides = true
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: prefs
        )
        XCTAssertTrue(model.editorIndentGuides, "seeds from preferences at init")
        model.toggleEditorIndentGuides()
        XCTAssertFalse(model.editorIndentGuides)
        XCTAssertFalse(prefs.editorIndentGuides,
                       "didSet should write through to preferences")
    }

    // MARK: - Find bar regex flag (Batch B)

    func test_sourceFindIsRegex_defaultsOff() {
        let model = makeModel()
        XCTAssertFalse(model.sourceFindIsRegex)
    }

    func test_sourceFindIsRegex_isWritable() {
        let model = makeModel()
        model.sourceFindIsRegex = true
        XCTAssertTrue(model.sourceFindIsRegex)
    }

    // MARK: - HEX state routing (Batch A, commit d175548)

    /// Picking HEX on a text-loaded tab must request a binary load.
    /// Pre-Batch-A this only fired from `.loaded` state; the new code
    /// also handles `.preview` and `.error`. Verify the loaded path
    /// still works (regression guard).
    func test_setHex_on_loadedText_kicks_binaryLoad() throws {
        let model = makeModel()
        let url = try writeFile("file.txt", "hello world")
        model.open(url: url)
        XCTAssertTrue(isLoaded(model.currentState))
        model.setCurrentViewMode(.hex)
        // The picker reflects the user's pick immediately; the
        // state-swap is async via Task.detached. Spin until the
        // tab's state flips to .binary (cap to keep failures fast).
        let switched = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertTrue(switched, "expected state to flip to .binary after HEX")
        XCTAssertEqual(model.currentViewMode, .hex)
    }

    /// Switching from .hex back to .source must request a text reload.
    func test_setSource_on_binary_kicks_textLoad() throws {
        let model = makeModel()
        let url = try writeFile("file.txt", "hello")
        model.open(url: url)
        model.setCurrentViewMode(.hex)
        _ = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        model.setCurrentViewMode(.source)
        let switched = waitFor(timeout: 2.0) {
            if case .loaded = model.currentState { return true }
            return false
        }
        XCTAssertTrue(switched, "expected state to flip back to .loaded after Source")
        XCTAssertEqual(model.currentViewMode, .source)
    }

    /// Regression for the "HEX is selected but a different file shows
    /// in preview mode after switching" bug. Opening a file with HEX
    /// already current on the tab must kick a binary load for the new
    /// file too.
    func test_openFile_with_hex_active_triggers_binaryLoad_for_newFile() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        model.open(url: a)
        model.setCurrentViewMode(.hex)
        _ = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertEqual(model.currentViewMode, .hex)

        model.open(url: b)
        // We expect the new tab to also end up in .binary because
        // currentViewMode was .hex when openOrReveal carried it across.
        // Picker first reflects the user's mode; the binary load fires
        // asynchronously.
        XCTAssertEqual(model.currentViewMode, .hex)
        let bIsBinary = waitFor(timeout: 2.0) {
            guard model.currentURL?.lastPathComponent == "b.txt" else { return false }
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertTrue(bIsBinary,
                      "HEX must persist across file switch — bug fixed in d175548")
    }

    // MARK: - Media file: HEX round-trip restores `.preview` state

    /// Regression: PNG tab opens as `.preview` → user picks HEX (state
    /// flips to `.binary`) → user picks Render/Source again. Before the
    /// fix, `setCurrentViewMode` called `loadTextAsync` for any
    /// `.binary` state, which silently fails for a binary file, leaving
    /// the tab stuck in `.binary` + showing HexView even though the
    /// picker said Source/Rendered. Fix restores `.preview` for media.
    func test_setSource_on_binaryImage_restoresPreview() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("pixel.png")
        try Self.minimalPNG.write(to: url)
        model.open(url: url)
        // Sanity: native preview state.
        if case .preview(_, let cat) = model.currentState {
            XCTAssertEqual(cat, .image)
        } else {
            XCTFail("expected .preview for a PNG, got \(model.currentState)")
        }
        // Flip to HEX. State should swap to .binary (async).
        model.setCurrentViewMode(.hex)
        let toHex = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        XCTAssertTrue(toHex, "expected .binary after HEX")
        XCTAssertEqual(model.currentViewMode, .hex)

        // Flip back to Rendered. Mode must update *and* state must
        // restore to .preview (not stay stuck at .binary).
        model.setCurrentViewMode(.rendered)
        XCTAssertEqual(model.currentViewMode, .rendered)
        if case .preview(_, let cat) = model.currentState {
            XCTAssertEqual(cat, .image)
        } else {
            XCTFail("expected .preview restored after Render, got \(model.currentState)")
        }
    }

    /// Same round-trip via `.source` — picker offers Source for images
    /// (no Rendered button), so this is the realistic user path.
    func test_setSource_on_binaryImage_restoresPreview_viaSource() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("pixel.png")
        try Self.minimalPNG.write(to: url)
        model.open(url: url)
        model.setCurrentViewMode(.hex)
        _ = waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }
        model.setCurrentViewMode(.source)
        XCTAssertEqual(model.currentViewMode, .source)
        if case .preview = model.currentState {
            // ok
        } else {
            XCTFail("expected .preview restored after Source, got \(model.currentState)")
        }
    }

    // MARK: - Bug B: fresh image opens in Preview mode, not HEX

    /// THE Bug-B model-level regression. A fresh `model.open(png)` must
    /// select the first-class `.preview` ViewMode — the layer the owner's
    /// action ("open a PNG") actually hits. Before the fix the selected mode
    /// was `.hex` (no `.preview` ViewMode existed), so the picker said HEX and
    /// the persisted snapshot carried HEX even though content was a preview.
    /// TEETH: pre-fix the selected viewMode is `.hex`, so the `.preview`
    /// assertion FAILS; post-fix it PASSES.
    func test_open_png_defaultsToPreviewMode_notHex() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("pixel.png")
        try Self.minimalPNG.write(to: url)
        model.open(url: url)
        XCTAssertEqual(model.tabs.selected?.viewMode, .preview,
                       "fresh PNG open must select Preview mode, not HEX")
        guard case .preview(_, let cat) = model.currentState, cat == .image else {
            return XCTFail("expected .preview(.image), got \(model.currentState)")
        }
    }

    /// The picker-realistic round-trip now that `.preview` is a first-class
    /// mode: PNG opens in `.preview` → HEX (state → `.binary`) → back to
    /// `.preview` (the actual button the user clicks, not Source/Rendered).
    /// State must restore to `.preview(.image)` and the mode to `.preview`.
    func test_image_previewHexPreview_roundTrip() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("pixel.png")
        try Self.minimalPNG.write(to: url)
        model.open(url: url)
        XCTAssertEqual(model.currentViewMode, .preview)

        model.setCurrentViewMode(.hex)
        XCTAssertTrue(waitFor(timeout: 2.0) {
            if case .binary = model.currentState { return true }
            return false
        }, "expected .binary after HEX")
        XCTAssertEqual(model.currentViewMode, .hex)

        model.setCurrentViewMode(.preview)
        XCTAssertEqual(model.currentViewMode, .preview)
        guard case .preview(_, let cat) = model.currentState, cat == .image else {
            return XCTFail("expected .preview(.image) restored after Preview, got \(model.currentState)")
        }
    }

    /// Carry-mode safety: with an image tab active (mode `.preview`), opening a
    /// TEXT file into the same tab must NOT carry `.preview` (invalid for text)
    /// — it falls back to the text file's natural default and the picker stays
    /// consistent with `availableModes`.
    func test_carryMode_doesNotSmuggle_preview_ontoTextFile() throws {
        let model = makeModel()
        let png = tmpDir.appendingPathComponent("pixel.png")
        try Self.minimalPNG.write(to: png)
        model.open(url: png)
        XCTAssertEqual(model.currentViewMode, .preview)

        let txt = try writeFile("note.txt", "hello\n")
        model.open(url: txt)
        let modes = ViewModeOptions.availableModes(for: txt)
        XCTAssertFalse(modes.contains(.preview),
                       "text file must not offer Preview")
        XCTAssertTrue(modes.contains(model.currentViewMode),
                      "carried/selected mode \(model.currentViewMode) must be in the text file's availableModes \(modes)")
        XCTAssertNotEqual(model.currentViewMode, .preview,
                          "Preview must not be smuggled onto a text file")
    }

    /// SC-CHROME-02 regression: carry-mode must NOT carry `.hex` onto a
    /// native-preview destination. A preview file's `availableModes` are
    /// `[.preview, .hex]`, so membership alone would accept a carried
    /// `.hex` — but the loader returns a `.preview` document state and the
    /// HEX-load block correctly skips it, leaving the picker reading HEX
    /// over a native image lens (picker↔pane desync). Carry must fall back
    /// to the preview file's natural default (`.preview`) so picker == pane.
    func test_carryMode_doesNotCarryHex_ontoNativePreview() throws {
        let model = makeModel()
        // Open a text file and force it into HEX so the active tab carries
        // a non-default, user-picked `.hex`.
        let bin = try writeFile("raw.bin", "\u{0}\u{1}\u{2}rawbytes\n")
        model.open(url: bin)
        model.setCurrentViewMode(.hex)
        XCTAssertEqual(model.currentViewMode, .hex)

        // Now open a native-preview file (image) into the SAME tab (no
        // intervening source tab) — the SC-CHROME-02 repro.
        let png = tmpDir.appendingPathComponent("after.png")
        try Self.minimalPNG.write(to: png)
        model.open(url: png)

        // The picker must track the pane: the file renders via `.preview`,
        // so the selected mode must be `.preview`, NOT the carried `.hex`.
        XCTAssertEqual(model.currentViewMode, .preview,
                       "carried .hex must not leak onto a native-preview file; picker must read Preview")
        guard case .preview(_, let cat) = model.currentState, cat == .image else {
            return XCTFail("expected .preview(.image) state, got \(model.currentState)")
        }
        XCTAssertTrue(ViewModeOptions.availableModes(for: png).contains(model.currentViewMode),
                      "selected mode must be in the destination's availableModes")
    }

    /// Smallest valid PNG: 1×1 transparent. Used by the HEX round-trip
    /// tests to give `FileTypeDetector` a real image with bytes that
    /// `BinaryFileLoader` can actually read.
    private static let minimalPNG: Data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82
    ])

    // MARK: - Bookmark folder support (Batch A item)

    func test_bookmarkTargetURL_prefers_currentFile_over_folder() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "x")
        model.openFolder(tmpDir)
        model.open(url: url)
        XCTAssertEqual(model.bookmarkTargetURL?.lastPathComponent, "a.md")
    }

    func test_bookmarkTargetURL_falls_back_to_folder_when_no_file_open() {
        let model = makeModel()
        model.openFolder(tmpDir)
        XCTAssertEqual(model.bookmarkTargetURL, tmpDir.standardizedFileURL.resolvingSymlinksInPath())
    }

    func test_bookmarkTargetURL_nil_when_neither_set() {
        let model = makeModel()
        XCTAssertNil(model.bookmarkTargetURL)
    }

    // MARK: - Helpers

    /// Synchronously spin the main run loop until `predicate` becomes
    /// true or the timeout elapses. Returns whether it became true.
    /// Used for the async loadBinary path on the main actor.
    private func waitFor(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    private func isLoaded(_ state: DocumentState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    // MARK: openPath(_:atLine:) — search-result jump dispatch

    /// Plain-text file opens in `.source` mode by default; the
    /// line-jump should bump `sourceScrollLineNonce` and stash the
    /// target line. Editor goto is left unset (we're not in `.editor`).
    func test_openPathAtLine_editorDefault_drivesCM6GotoChannel() throws {
        // TSK-1588: plain text now opens EDITABLE (.editor), so an at-line
        // open drives the CM6 goto channel (and still fires scrollSource so a
        // later switch-to-source picks the caret up).
        let model = makeModel()
        let url = try writeFile("notes.txt", "a\nb\nc\nd\n")
        model.openPath(url, atLine: 3)
        XCTAssertEqual(model.currentViewMode, .editor,
                       "plain-text default mode is .editor (TSK-1588)")
        XCTAssertEqual(model.editorGotoLine?.line, 3,
                       "editor mode routes the jump through the CM6 goto channel")
        XCTAssertEqual(model.sourceScrollLineTarget, 3,
                       "the source channel is still seeded for a later lens switch")
    }

    func test_openPathAtLine_sourceMode_setsSourceScrollRequest() throws {
        // html keeps the read-only Source default (TSK-1588 kept it
        // conservative), so it pins the SOURCE scroll channel contract.
        let model = makeModel()
        let url = try writeFile("page.html", "<p>a</p>\n<p>b</p>\n<p>c</p>\n<p>d</p>\n")
        let baselineNonce = model.sourceScrollLineNonce
        model.openPath(url, atLine: 3)
        XCTAssertEqual(model.currentViewMode, .source,
                       "html default mode is .source")
        XCTAssertEqual(model.sourceScrollLineTarget, 3)
        XCTAssertNotEqual(model.sourceScrollLineNonce, baselineNonce,
                          "scrollSource must bump the nonce so the view re-fires")
        XCTAssertNil(model.editorGotoLine,
                     "non-editor modes should not poke the CM6 channel")
    }

    /// Markdown defaults to `.rendered`. Jumping to a line coerces the
    /// mode to `.editor` (2026-08-09, was `.source`: rendered HTML has no
    /// line N, and the CM6 editor can additionally SELECT the matched
    /// span of a search-result jump) and fires both channels.
    func test_openPathAtLine_markdown_coercesRenderedToEditor() throws {
        let model = makeModel()
        let url = try writeFile("readme.md", "# h1\n\npara\n\n## h2\n")
        model.open(url: url)
        XCTAssertEqual(model.currentViewMode, .rendered,
                       "markdown default is .rendered")
        let baselineNonce = model.sourceScrollLineNonce
        model.openPath(url, atLine: 5)
        XCTAssertEqual(model.currentViewMode, .editor,
                       "rendered must be coerced to .editor for line jump")
        XCTAssertEqual(model.editorGotoLine?.line, 5,
                       "the CM6 goto channel carries the jump")
        XCTAssertEqual(model.sourceScrollLineTarget, 5)
        XCTAssertGreaterThan(model.sourceScrollLineNonce, baselineNonce)
    }

    /// A search-result jump carries the matched span: the goto request
    /// selects exactly [column, column+length) instead of the whole line.
    func test_openPathAtLine_matchSpan_ridesTheGotoRequest() throws {
        let model = makeModel()
        let url = try writeFile("code2.swift", "let alpha = 1\nlet beta = 2\n")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        model.openPath(url, atLine: 2, matchColumn: 4, matchLength: 4)
        XCTAssertEqual(model.editorGotoLine?.line, 2)
        XCTAssertEqual(model.editorGotoLine?.column, 4)
        XCTAssertEqual(model.editorGotoLine?.selectLength, 4)
        XCTAssertEqual(model.editorGotoLine?.select, false,
                       "a span selection replaces the whole-line select")
    }

    /// When the active tab is already in `.editor` mode, the jump
    /// must populate `editorGotoLine` (the CM6 surface listens there)
    /// in addition to the source channel.
    func test_openPathAtLine_editorMode_setsEditorGotoLine() throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        XCTAssertEqual(model.currentViewMode, .editor)
        let baselineNonce = model.sourceScrollLineNonce
        model.openPath(url, atLine: 2)
        XCTAssertEqual(model.currentViewMode, .editor,
                       "editor mode must be preserved (not coerced)")
        XCTAssertEqual(model.editorGotoLine?.line, 2)
        XCTAssertEqual(model.editorGotoLine?.select, true,
                       "search result should select the matched line")
        // Source channel still bumped so a mode switch back to source
        // picks up the same caret.
        XCTAssertEqual(model.sourceScrollLineTarget, 2)
        XCTAssertGreaterThan(model.sourceScrollLineNonce, baselineNonce)
    }

    // MARK: - Find menu gates (TSK-946 / TSK-949)

    /// ⌥⌘F (Find & Replace) greys out unless the editor surface is active —
    /// replace can't run on the read-only rendered/source views.
    func test_canFindAndReplace_falseWithNoTab() {
        let model = makeModel()
        XCTAssertFalse(model.canFindAndReplace, "no tab ⇒ replace disabled")
    }

    func test_canFindAndReplace_trueInEditorMode() throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "let a = 1\n")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        XCTAssertEqual(model.currentViewMode, .editor)
        XCTAssertTrue(model.canFindAndReplace, "editor active ⇒ replace enabled")
    }

    func test_canFindAndReplace_falseInSourceMode() throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "let a = 1\n")
        model.open(url: url)
        model.setCurrentViewMode(.source)
        XCTAssertEqual(model.currentViewMode, .source)
        XCTAssertFalse(model.canFindAndReplace, "read-only source ⇒ replace disabled")
    }

    /// ⌘G / ⌥⌘G (Find Next/Prev) only enable while a find bar is open.
    func test_canFindNextPrev_followsOpenBar() {
        let model = makeModel()
        XCTAssertFalse(model.canFindNextPrev, "no bar ⇒ next/prev disabled")
        model.find.showSourceBar()
        XCTAssertTrue(model.canFindNextPrev, "open bar ⇒ next/prev enabled")
        model.find.dismissSourceBar()
        XCTAssertFalse(model.canFindNextPrev, "closed bar ⇒ next/prev disabled again")
    }

    // MARK: - Terminal favorites (TSK-769)

    func test_insertTerminalFavorite_blankIsNoOp() {
        let model = makeModel()
        // A blank command must short-circuit BEFORE opening the terminal pane —
        // returns false, no PTY spawned.
        XCTAssertFalse(model.insertTerminalFavorite("   "))
        XCTAssertFalse(model.insertTerminalFavorite(""))
    }

    func test_terminalFavorites_accessorRoundTrips() {
        let model = makeModel()
        XCTAssertTrue(model.terminalFavorites.add(command: "git status"))
        XCTAssertEqual(model.terminalFavorites.all.first?.command, "git status",
            "the model exposes the favorites store for the menu to list")
    }

    // MARK: - Content auto-detect for misnamed files (TSK-901)

    func test_canMinifyJSON_trueForMisnamedJSONFile() throws {
        let model = makeModel()
        let url = try writeFile("data.txt", "{\n  \"a\": 1,\n  \"b\": [2, 3]\n}\n")
        model.open(url: url)
        XCTAssertTrue(model.canMinifyActiveJSON,
            "a .txt whose content IS JSON must enable the JSON tools (TSK-901)")
    }

    func test_canConvertCSV_trueForMisnamedCSVFile() throws {
        let model = makeModel()
        let url = try writeFile("table.txt", "name,age,city\nAda,36,London\nGrace,40,NYC\n")
        model.open(url: url)
        XCTAssertTrue(model.canConvertActiveCSV,
            "a .txt whose content IS CSV must enable the CSV tools (TSK-901)")
    }

    func test_contentGates_falseForProseTextFile() throws {
        let model = makeModel()
        let url = try writeFile("notes.txt", "Hello world.\nThis is a plain note, with a comma.\n")
        model.open(url: url)
        XCTAssertFalse(model.canMinifyActiveJSON, "prose must not sniff as JSON")
        XCTAssertFalse(model.canConvertActiveCSV, "prose-with-commas must not sniff as CSV")
    }

    func test_canMinifyJSON_stillTrueForRealJSONExtension() throws {
        let model = makeModel()
        let url = try writeFile("real.json", "{\"x\":1}\n")
        model.open(url: url)
        XCTAssertTrue(model.canMinifyActiveJSON, "the .json extension fast-path is unchanged")
    }

    // MARK: - Reload from Disk for an arbitrary file (TSK-916)

    func test_isFileOpenInTab_tracksOpenState() throws {
        let model = makeModel()
        let url = try writeFile("doc.txt", "one\n")
        XCTAssertFalse(model.isFileOpenInTab(url), "not open ⇒ false")
        model.open(url: url)
        XCTAssertTrue(model.isFileOpenInTab(url), "open ⇒ true")
    }

    func test_reloadFileFromDisk_noOpWhenNotOpen() throws {
        let model = makeModel()
        let url = try writeFile("closed.txt", "x\n")
        // File exists on disk but isn't open in any tab → nothing to reload.
        XCTAssertFalse(model.reloadFileFromDisk(url),
            "reload of an unopened file must be a no-op (returns false)")
    }

    func test_reloadFileFromDisk_reloadsOpenTab() throws {
        let model = makeModel()
        let url = try writeFile("open.txt", "x\n")
        model.open(url: url)
        XCTAssertTrue(model.reloadFileFromDisk(url),
            "reload of the open file must find its tab and reload (returns true)")
    }

    /// Two clicks on the same line must each produce a fresh nonce
    /// so the view re-fires the scroll (otherwise a second click on
    /// the same row after the user scrolled away would be a silent
    /// no-op).
    func test_openPathAtLine_repeatedSameLine_bumpsNonceEachCall() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "one\ntwo\nthree\n")
        model.openPath(url, atLine: 2)
        let firstNonce = model.sourceScrollLineNonce
        model.openPath(url, atLine: 2)
        XCTAssertGreaterThan(model.sourceScrollLineNonce, firstNonce,
                             "every search-result click must produce a new nonce")
    }

    /// Repeated `editorGotoLine` requests for the same line must
    /// have distinct `id`s so CM6 actually re-applies (the Equatable
    /// check compares the whole struct).
    func test_openPathAtLine_editorMode_repeatedSameLine_bumpsGotoID() throws {
        let model = makeModel()
        let url = try writeFile("code.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        model.openPath(url, atLine: 2)
        let firstID = model.editorGotoLine?.id
        model.openPath(url, atLine: 2)
        let secondID = model.editorGotoLine?.id
        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID,
                          "each click must mint a fresh CMGotoLineRequest id")
    }

    /// Zero / negative lines are no-ops on the scroll channel — we
    /// still open the file but don't pretend to know where to land.
    func test_openPathAtLine_zeroLine_isNoopForScroll() throws {
        let model = makeModel()
        let url = try writeFile("a.txt")
        let baselineNonce = model.sourceScrollLineNonce
        model.openPath(url, atLine: 0)
        XCTAssertEqual(model.currentURL?.lastPathComponent, "a.txt")
        XCTAssertEqual(model.sourceScrollLineNonce, baselineNonce,
                       "line<=0 must not touch the scroll channel")
    }

    // MARK: - UDC-2: clean editor tab refreshes buffer on reload

    func test_reload_editorMode_cleanBuffer_refreshesFromDisk() throws {
        let model = makeModel()
        let url = try writeFile("e.txt", "v1")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        let id = model.tabs.selected!.id
        // Seed a clean editor buffer reflecting v1.
        let buf0 = model.editorBuffer(forTabID: id)
        XCTAssertEqual(buf0?.text, "v1")
        XCTAssertFalse(buf0?.isDirty ?? true)
        // External edit lands on disk; watcher reloads.
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        model.reloadCurrentFile()
        // The clean buffer must now reflect the reloaded bytes so CM6
        // shows v2 and a subsequent save doesn't clobber the edit.
        let buf1 = model.editorBuffer(forTabID: id)
        XCTAssertEqual(buf1?.text, "v2",
            "UDC-2: clean editor buffer must rebase onto reloaded disk text")
        XCTAssertFalse(buf1?.isDirty ?? true,
            "rebased buffer stays clean (originalText == text)")
    }

    func test_reload_editorMode_dirtyBuffer_isNotClobbered() throws {
        let model = makeModel()
        let url = try writeFile("e2.txt", "v1")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        // User types — buffer now dirty with "mine".
        model.updateEditorText("mine", forTabID: id)
        XCTAssertTrue(model.editorBuffer(forTabID: id)?.isDirty ?? false)
        // A direct reload of the same path must NOT discard the dirty
        // buffer (the dirty external-edit case is gated by the conflict
        // prompt upstream; a plain reload leaves dirty edits intact).
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        model.reloadCurrentFile()
        XCTAssertEqual(model.editorBuffer(forTabID: id)?.text, "mine",
            "UDC-2: a dirty editor buffer must not be clobbered by reload")
    }

    // MARK: - UDC-5: multi-drop with a folder

    func test_openMultiple_folderAmongFiles_doesNotCreateBrokenTab() throws {
        let model = makeModel()
        let f1 = try writeFile("one.md", "# one")
        let folder = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f2 = try writeFile("two.md", "# two")
        // Folder is in the MIDDLE — the pre-fix code lazy-appended it as
        // a file tab that errored on materialize.
        model.openMultiple([f1, folder, f2])
        // Only the two files become tabs; the folder routes to sidebar.
        let tabURLs = model.tabs.tabs.compactMap { $0.url?.lastPathComponent }
        XCTAssertEqual(Set(tabURLs), ["one.md", "two.md"],
            "UDC-5: a dropped folder must not become a tab")
        XCTAssertEqual(model.sidebar.rootURL?.resolvingSymlinksInPath(),
                       folder.resolvingSymlinksInPath(),
            "UDC-5: the dropped folder sets the sidebar root")
        // No tab should be in an error state.
        for tab in model.tabs.tabs {
            if case .error = tab.state {
                XCTFail("UDC-5: no tab should be in .error after multi-drop")
            }
        }
    }

    func test_openMultiple_lastFileIsEagerAndFocused() throws {
        let model = makeModel()
        let f1 = try writeFile("first.md", "# first")
        let f2 = try writeFile("last.md", "# last")
        model.openMultiple([f1, f2])
        // Last file wins focus and is eagerly loaded.
        XCTAssertEqual(model.currentURL?.lastPathComponent, "last.md")
        if case .loaded(let f) = model.currentState {
            XCTAssertEqual(f.contents, "# last")
        } else {
            XCTFail("last file must be eagerly .loaded")
        }
    }

    // MARK: - TD-09 / RWC-2: displayedText reports byte length + mtime

    func test_displayedText_rawPath_reportsFileByteCountAndMtime() throws {
        let model = makeModel()
        let url = try writeFile("plain.txt", "hello")
        model.open(url: url)
        guard case .loaded(let file) = model.currentState else {
            return XCTFail("expected .loaded")
        }
        let info = model.displayedText(for: file)
        XCTAssertEqual(info.text, "hello")
        XCTAssertEqual(info.byteLength, file.byteCount,
            "raw path must report file.byteCount (no utf8 re-walk)")
        XCTAssertEqual(info.modifiedTime, file.modifiedTime,
            "displayedText must surface the source mtime for the cache key")
    }

    // MARK: - Landing "New text file" button (TSK-760)

    func test_newTextFileForLanding_usesWorkspaceFolder_whenOpen() throws {
        let model = makeModel()
        let folder = tmpDir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)

        let url = try XCTUnwrap(model.newTextFileForLanding(), "with a folder open it must create a file")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       folder.standardizedFileURL,
                       "with a folder open, the new file lands IN the workspace folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "created on disk")
        XCTAssertEqual(model.tabs.selected?.url, url, "the new file opens in a tab")
    }

    func test_newTextFileForLanding_fallsBackToTempScratch_whenNothingOpen() throws {
        let model = makeModel()
        // Nothing open ⇒ newFileTargetDirectory is nil; the landing button must
        // STILL work (temp scratch), unlike File→New which disables.
        let url = try XCTUnwrap(model.newTextFileForLanding(),
                                "landing New File must succeed even with no folder open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "created on disk (temp scratch)")
        XCTAssertEqual(model.tabs.selected?.url, url, "the new file opens in a tab")
        // TSK-1294: with NO folder open, the temp-scratch fallback must NOT
        // enumerate/expand the (huge) temp dir into the sidebar — that was a
        // multi-second hang. `createNewFile` now gates the sidebar reload on
        // `sidebar.contains(dir)`, so nothing gets expanded here. (Pre-fix this
        // test took ~13s and `expanded` held the temp dir.)
        XCTAssertTrue(model.sidebar.expanded.isEmpty,
                      "landing scratch (no folder open) must not expand the temp dir")
        XCTAssertNil(model.sidebar.rootURL,
                     "landing scratch must not auto-root the temp dir as a workspace")
        try? FileManager.default.removeItem(at: url)
    }
}
