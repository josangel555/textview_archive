import Foundation
import ViewerCore

/// TSK-492 (Layer 1) — the deterministic UI-scene → model-state mapping.
///
/// `MDV_UI_SCENE` drives the live model into an EXACT state at launch so the
/// visual-eval harness (`scripts/vm-uitest.sh` / `ui-snapshot.sh`) captures a
/// reproducible state without fighting persisted defaults/AX. The scene→model
/// logic lived inline in the `MarkdownViewer` EXECUTABLE target
/// (`Diagnostics.applyUISceneIfRequested`), which the test targets don't link —
/// so the scene catalog the harness depends on had NO regression guard. This
/// extracts the pure mapping into `ViewerUI` (host-testable) with the env/
/// dispatch/stderr shell staying in `Diagnostics`. Behaviour-identical to the
/// pre-extraction inline code; the returned string is what `Diagnostics` writes
/// to stderr (`ui-scene: …`).
///
/// Inputs are passed in (not read from the environment here) so a host test can
/// drive it: `previewFile` is `MDV_PREVIEW_FILE`; `tabsBaseDir` is where the
/// `tabs-<N>` scene writes its throwaway markdown (the per-pid tmp dir in the
/// app; a test tmp dir under test).
@MainActor
public enum UISceneApplier {

    /// Apply `scene` (already lowercased) to `model`. Returns the status line
    /// describing what was applied (or the error/unknown message).
    ///
    /// Recognition is single-sourced through `UISceneRegistry` (ViewerCore): an
    /// id the registry doesn't enumerate is REJECTED here (loud "unknown scene"
    /// status, no model mutation) rather than silently falling through to a
    /// baseline — which would make the visual-eval harness capture the wrong
    /// pixels (a false green). The registry's `SceneSpec` is the deterministic
    /// CONTRACT; this method performs the corresponding LIVE-model mutation.
    @discardableResult
    public static func apply(
        scene: String,
        to model: DocumentModel,
        previewFile: URL?,
        tabsBaseDir: URL
    ) -> String {
        // Reject unknown ids up front against the enumerated registry so the
        // recognised-scene set is single-sourced (and a typo can't slip through
        // to a baseline capture). DEBUG-only scenes (code-action picker seam)
        // resolve only in DEBUG builds — a release build rejects them loudly.
        guard let spec = UISceneRegistry.resolve(scene) else {
            return "ui-scene: unknown scene '\(scene)'"
        }
        #if !DEBUG
        if spec.isDebugOnly {
            return "ui-scene: unknown scene '\(scene)'"
        }
        #endif
        _ = spec  // the spec is the validated contract; mutation follows below.

        let parts = scene.split(separator: "-").map(String.init)

        // Empty-state landing (EmptyStateView): no file open. A deliberate no-op
        // — the app launches into the empty state; this scene NAMES it for the
        // harness (TSK-760: capture the New File button / recents launcher on the
        // landing) so it isn't misreported as an "unknown scene".
        if scene == "landing" {
            return "ui-scene: applied 'landing' (empty state, no tabs)"
        }

        // LSP rename PROMPT scene (TSK-640 render tail): present the rename
        // prompt sheet over an editor backdrop so the VM harness can capture it
        // and assert the `mdv.lspRename.*` elements are actually VISIBLE on
        // screen (the open validation gap — the CLAUDE.md "present ≠ visible"
        // rule). The trigger path (command → `canRenameActiveEditorSymbol`
        // gate → present) is host-tested by `LSPGotoCommandTests`; this scene's
        // sole job is to put the SHEET on screen, so it presents DIRECTLY rather
        // than re-deriving the enablement gate (which would couple the capture
        // to a live LSP server the spawned app may lack).
        if scene == "lsp-rename" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("rename-target.swift")
            try? "let oldName = 1\n".write(to: f, atomically: true, encoding: .utf8)
            model.open(url: f)
            model.isLSPRenamePromptPresented = true
            return "ui-scene: applied 'lsp-rename' tabs=\(model.tabs.tabs.count) renamePrompt=\(model.isLSPRenamePromptPresented)"
        }

        // Folder-only / no-file scene (TSK-738 render validation): the status
        // footer regressed-HIDDEN when a folder is open but NO file tab is
        // selected (currentURL nil → the old `currentURL != nil` gate). The
        // aqua-runner always launches with a file open, so reach the reported
        // state explicitly — close every open tab, then open a folder root.
        // `hasOpenContext` becomes true via `sidebar.rootURL` while `currentURL`
        // stays nil → the broadened gate (TSK-738) must KEEP the footer
        // (`mdv.statusBar`) on screen.
        if scene == "folder-only" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.openFolder(tabsBaseDir)
            return "ui-scene: applied 'folder-only' tabs=\(model.tabs.tabs.count) root=\(model.sidebar.rootURL != nil) hasContext=\(model.hasOpenContext)"
        }

        // Unsupported-video scene (TSK-1474 render tail): FileCategory.video
        // routes mkv/webm/wmv/flv here but AVFoundation can't decode them — the
        // old code showed a BLACK AVPlayerView. Open a .mkv so MediaPreviewView
        // takes the VideoPlayability.unsupported branch → VideoFallbackCard.
        // The VM harness asserts mdv.video.fallbackCard is VISIBLE (a black
        // player would fail the a11y-presence check). VideoPlayability is
        // extension-based, so the file content is irrelevant.
        if scene == "video-unsupported" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("sample.mkv")
            try? Data("not a real mkv".utf8).write(to: f)
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.open(url: f)
            return "ui-scene: applied 'video-unsupported' tabs=\(model.tabs.tabs.count) selected=\(model.tabs.selected?.url?.lastPathComponent ?? "nil")"
        }

        // Archive-preview scene (TSK-1469 render tail): open a real .zip so
        // ArchiveBrowserView's master/detail list + preview pane render. The
        // embedded base64 is a valid stored-mode zip with readme.txt + data.csv
        // (ArchiveCatalog.list needs a real archive). The VM harness reads the
        // PNG (ax-reader doesn't surface content-view a11y ids — see TSK-1474).
        if scene == "archive-preview" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("sample.zip")
            let b64 = "UEsDBAoAAAAAAEUr6Vx0RKWRFgAAABYAAAAKAAAAcmVhZG1lLnR4dGhlbGxvIGZyb20gdGhlIGFyY2hpdmVQSwMECgAAAAAARSvpXJqADc4OAAAADgAAAAgAAABkYXRhLmNzdmNvbDEsY29sMgoxLDIKUEsBAh4DCgAAAAAARSvpXHREpZEWAAAAFgAAAAoAAAAAAAAAAQAAAKSBAAAAAHJlYWRtZS50eHRQSwECHgMKAAAAAABFK+lcmoANzg4AAAAOAAAACAAAAAAAAAABAAAApIE+AAAAZGF0YS5jc3ZQSwUGAAAAAAIAAgBuAAAAcgAAAAAA"
            if let data = Data(base64Encoded: b64) { try? data.write(to: f) }
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.open(url: f)
            return "ui-scene: applied 'archive-preview' tabs=\(model.tabs.tabs.count) selected=\(model.tabs.selected?.url?.lastPathComponent ?? "nil")"
        }

        // Notebook scene (TSK-1440 render tail): enable NotebookGate (persisted
        // key, read at render time) + open a .ipynb with stream/result/error
        // outputs so NotebookCellListView renders the OUTPUTS below each cell
        // source (the tail this scene guards). VM harness reads the PNG.
        if scene == "notebook" {
            UserDefaults.standard.set(true, forKey: NotebookGate.defaultsKey)
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("sample.ipynb")
            let ipynb = """
            {"cells":[
             {"cell_type":"markdown","metadata":{},"source":["# Demo notebook\\n","Rendered **outputs** below."]},
             {"cell_type":"code","execution_count":1,"metadata":{},"outputs":[{"output_type":"stream","name":"stdout","text":["hello from stdout\\n"]}],"source":["print('hello from stdout')"]},
             {"cell_type":"code","execution_count":2,"metadata":{},"outputs":[{"output_type":"execute_result","execution_count":2,"data":{"text/plain":["42"]},"metadata":{}}],"source":["6 * 7"]},
             {"cell_type":"code","execution_count":3,"metadata":{},"outputs":[{"output_type":"error","ename":"ValueError","evalue":"bad value","traceback":["Traceback (most recent call last):","ValueError: bad value"]}],"source":["raise ValueError('bad value')"]}
            ],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """
            try? ipynb.write(to: f, atomically: true, encoding: .utf8)
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.open(url: f)
            return "ui-scene: applied 'notebook' tabs=\(model.tabs.tabs.count) selected=\(model.tabs.selected?.url?.lastPathComponent ?? "nil") gate=\(NotebookGate.isEnabled())"
        }

        // Dependency-graph scene (TSK-1470 render tail): DependencyGraphView was
        // built-but-unreachable; showDependencyGraph() opens it as a hosted tab.
        // importGraph resolves `import Foo` → a file `Foo.swift`, so write three
        // files that chain Alpha → Beta → Gamma to produce a REAL 3-node/2-edge
        // graph (an empty folder would draw the unavailable placeholder, not the
        // canvas the tail guards). openFolder sets sidebar.rootURL (the guard in
        // showDependencyGraph); the extraction + hosted-tab open run async, so
        // the VM harness (which captures ~60-90s later) sees the painted canvas.
        if scene == "depgraph" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let files: [(String, String)] = [
                ("Alpha.swift", "import Foundation\nimport Beta\n\nstruct Alpha { let b = Beta() }\n"),
                ("Beta.swift", "import Foundation\nimport Gamma\n\nstruct Beta { let g = Gamma() }\n"),
                ("Gamma.swift", "import Foundation\n\nstruct Gamma {}\n"),
            ]
            for (name, body) in files {
                try? body.write(
                    to: tabsBaseDir.appendingPathComponent(name),
                    atomically: true, encoding: .utf8)
            }
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            // A restored session can leave the terminal occupying the content
            // area + a very wide sidebar, hiding the hosted graph tab — the
            // scene must fully specify its layout so the canvas is on screen for
            // the VM capture. Close the terminal; narrow the sidebar.
            model.terminalPane.setOpen(false)
            model.setSidebarWidth(240)
            model.openFolder(tabsBaseDir)
            model.showDependencyGraph()
            return "ui-scene: applied 'depgraph' root=\(model.sidebar.rootURL != nil) tabs=\(model.tabs.tabs.count) terminalOpen=\(model.terminalPane.isOpen)"
        }

        // Markdown outline scene (TSK-1438 render tail): the .markdownOutline
        // sidebar panel is now MOUNTED (registry/presence/body); this scene
        // drives it on screen. Open a single .md with ≥6 headings (no folder →
        // the accordion is short: bookmarks + the outline + plugins, so the
        // panel isn't scrolled below the fold), force the sidebar open, and
        // close any restored terminal. The panel self-gates to markdown via
        // presence, so it lists exactly MarkdownOutline.headings() (UAT U1).
        if scene == "outline" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("outline-doc.md")
            let md = """
            # Introduction
            Intro prose for the outline panel.

            ## Getting Started
            Setup steps.

            ## Configuration
            Options you can set.

            ### Advanced Options
            Deep configuration knobs.

            ## Usage
            How to drive it.

            ## Troubleshooting
            Common issues and fixes.

            ## Résumé Section
            A diacritic heading for the filter test.
            """
            try? md.write(to: f, atomically: true, encoding: .utf8)
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.terminalPane.setOpen(false)
            model.sidebar.isVisible = true
            // The always-on Bookmarks panel (persisted entries) otherwise fills
            // the accordion and pushes the outline below the fold — force the
            // outline SHOWN and the noisy sibling panels HIDDEN so the mounted
            // panel is actually ON SCREEN (present-in-tree ≠ visible). These are
            // overrides on the throwaway test instance only.
            let hide: [SidebarPanelKind] = [
                .bookmarks, .searchAnywhere, .git, .claudeTimeline, .lspOutline,
                .lspNavigation, .lspProblems, .recentlyOpened, .pluginSections,
            ]
            for k in hide { model.panelLayout.setOverride(k, .hidden) }
            model.panelLayout.setOverride(.markdownOutline, .shown)
            model.open(url: f)
            return "ui-scene: applied 'outline' tabs=\(model.tabs.tabs.count) sidebar=\(model.sidebar.isVisible) outline=\(model.panelLayout.override(for: .markdownOutline).rawValue) selected=\(model.tabs.selected?.url?.lastPathComponent ?? "nil")"
        }

        // Terminal-favorites editor scene (TSK-1475 render tail): the Manage
        // Favorites… editor is now MOUNTED (menu → openTerminalFavoritesEditor →
        // .sheet). Seed a deterministic favorites list, then open the sheet so
        // the VM harness captures TerminalFavoritesEditor listing them in stored
        // order (UAT U1). add() inserts at index 0, so seed in reverse for a
        // natural top→bottom order.
        if scene == "favorites" {
            let store = model.terminalFavorites
            store.removeAll()
            _ = store.add(command: "make build", title: "Build")
            _ = store.add(command: "npm test", title: "Run tests")
            _ = store.add(command: "git status", title: "Git status")
            model.openTerminalFavoritesEditor()
            return "ui-scene: applied 'favorites' show=\(model.showTerminalFavoritesEditor) vm=\(model.terminalFavoritesEditorVM != nil) count=\(store.all.count)"
        }

        // Secret warn-badge scene (TSK-1496 render slice): open a doc with an AWS
        // key + a GitHub token (both high-precision SecretDetector shapes) plus a
        // benign UUID (false-positive-guard negative). With the default treatment
        // (warn), SecretWarningBanner flags the two secrets and leaves the UUID
        // quiet. Reset the treatment default to warn (0) in case a prior run left
        // it off. VM harness reads the banner pixels (values stay redacted).
        if scene == "secrets" {
            UserDefaults.standard.set(0, forKey: SecretDetector.treatmentDefaultsKey)
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("config.env")
            let body = """
            # Example config (fixture — not real credentials)
            AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
            GH_PAT=ghp_1234567890abcdefghijklmnopqrstuvwxyz12
            NORMAL_UUID=550e8400-e29b-41d4-a716-446655440000
            """
            try? body.write(to: f, atomically: true, encoding: .utf8)
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.terminalPane.setOpen(false)
            model.open(url: f)
            return "ui-scene: applied 'secrets' tabs=\(model.tabs.tabs.count) selected=\(model.tabs.selected?.url?.lastPathComponent ?? "nil")"
        }

        // Chrome theming scene (TSK-641 stage-4 render validation): apply the
        // dark built-in theme so the VM lane can assert the CHROME surface
        // actually PAINTS dark (the stale-chrome / non-republishing-view risk —
        // host tests prove Palette consults the theme; only the painted pixels
        // were unproven). Setting the @Published `selectedThemeID` is a LIVE
        // change → its didSet updates `ChromeTheme.current` + the chrome views
        // re-body (the stage-4 repaint mechanism), so this also exercises the
        // reactivity, not just a launch-time paint. Keeps the default file open
        // so the content + chrome both tint dark (a high window dark-fraction).
        if scene == "theme-dark" {
            model.selectedThemeID = "xcode-dark"
            return "ui-scene: applied 'theme-dark' selectedThemeID=\(model.selectedThemeID ?? "nil")"
        }

        // File-info checksum scene (TSK-748 render validation): the MetadataPanel
        // (with the multi-algo checksum Picker + compute/copy buttons) renders
        // only for a MEDIA file with `showPreviewMetadataPanel` on, so reach that
        // state — write a tiny valid PNG, open it (→ image category), and show
        // the panel. The VM lane then asserts mdv.metadata.checksum* are VISIBLE.
        // The checksum ENGINE/MODEL (CRC32/MD5/SHA-*, algo-switch, copy) is
        // host-tested; this proves the section actually paints.
        if scene == "metadata-checksum" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("sample.png")
            // 1×1 transparent PNG (valid, ~68 bytes) so the media branch renders.
            if let png = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") {
                try? png.write(to: f)
            }
            // Close the aqua-runner's auto-opened DESIGN.md first so the PNG
            // becomes the SOLE, ACTIVE tab (else the markdown stays foreground
            // and the media-preview MetadataPanel never shows).
            while !model.tabs.tabs.isEmpty { model.closeTab(at: 0) }
            model.open(url: f)
            model.showPreviewMetadataPanel = true
            return "ui-scene: applied 'metadata-checksum' tabs=\(model.tabs.tabs.count) selected=\(model.tabs.selected?.url?.lastPathComponent ?? "nil") panel=\(model.showPreviewMetadataPanel)"
        }

        #if DEBUG
        // LSP code-action PICKER scene (TSK-640 render tail): present the picker
        // with canned actions over an editor backdrop so the VM harness can
        // capture it + assert mdv.codeActions.* are VISIBLE. The picker's real
        // flow is async-LSP (private(set) state, no server in the spawned app),
        // so this uses the DEBUG harness present-seam. #if DEBUG: scenes are a
        // debug/test affordance (the VM dist is built debug); a release build
        // returns "unknown scene" → the a11y assertion fails loudly, never a
        // false green.
        if scene == "code-actions" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("codeaction-target.swift")
            try? "let x = 1\n".write(to: f, atomically: true, encoding: .utf8)
            model.open(url: f)
            let noEdit = LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                                end: LSPPosition(line: 0, character: 0)),
                newText: "")
            model._presentCodeActionsForHarness([
                // An edit-bearing action (enabled row) + a command-only action
                // (listed-but-disabled row) — exercises both row states.
                LSPCodeAction(title: "Organize Imports", kind: "source.organizeImports",
                              isPreferred: true, edit: ["file:///codeaction-target.swift": [noEdit]]),
                LSPCodeAction(title: "Convert to async", kind: "quickfix",
                              isPreferred: false, edit: [:]),
            ])
            return "ui-scene: applied 'code-actions' tabs=\(model.tabs.tabs.count) picker=presenting"
        }
        #endif

        // Preview-tab scenes (TSK-306 / TSK-272): drive the ONE ephemeral preview
        // slot. `preview-promoted` then promotes it to a permanent (upright) tab.
        if parts.first == "preview" {
            guard let url = previewFile else {
                return "ui-scene: 'preview' needs MDV_PREVIEW_FILE"
            }
            model.openPreview(url: url)
            if parts.contains("promoted") {
                model.open(url: url)   // the Enter / double-click commit path
            }
            return "ui-scene: applied '\(scene)' tabs=\(model.tabs.tabs.count) preview=\(model.tabs.previewTabID != nil)"
        }

        // Canvas WYSIWYG scene (M3.S7, TSK-1378): a deterministic .canvas doc
        // opened into the rendered lens with #title SELECTED — the T5 pixel
        // test asserts the selection overlay actually composites on screen
        // (and its negative control asserts the committed break goes RED).
        if scene == "canvas-demo" {
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            let f = tabsBaseDir.appendingPathComponent("scene.canvas")
            do {
                let store = model.automationCanvasStore
                let doc = try store.create()
                _ = try doc.adapter.applyDSL(baseRev: 0, "frame #col gap=8 padding=24 {\n  text #title \"Canvas pixel scene\" font=$font.h1\n  text #body \"supporting copy for the capture\"\n}")
                _ = try store.save(doc.id, to: f)
                store.close(CanvasDocumentStore.docID(for: f))
                model.open(url: f)
                if let tabID = model.tabs.selected?.id {
                    let controller = model.canvasController(forTab: tabID, fileURL: f)
                    // Select once mounted (the runtime needs a beat; the delay
                    // keeps the overlay deterministic for the capture).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        controller.select("nd:title")
                    }
                }
                return "ui-scene: applied 'canvas-demo'"
            } catch {
                return "ui-scene: canvas-demo FAILED: \(error)"
            }
        }

        // FILE tab-strip scenes (TSK-261/268/331): `tabs-<N>` opens N throwaway
        // markdown files as PERMANENT tabs so the top TabBar is on screen with a
        // deterministic population. Files live under `tabsBaseDir` (never
        // ~/Documents — see CLAUDE.md).
        if parts.first == "tabs" {
            let count = max(1, parts.compactMap { Int($0) }.first ?? 3)
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            for i in 1...count {
                let f = tabsBaseDir.appendingPathComponent(String(format: "tab-%02d.md", i))
                try? "# tab \(i)\n".write(to: f, atomically: true, encoding: .utf8)
                model.open(url: f)
            }
            // Select the FIRST tab: the strip starts unscrolled, and the last
            // tab carries no selection tint (which would mask a missing trailing
            // divider in the pixel tests).
            model.selectTab(at: 0)
            return "ui-scene: applied '\(scene)' tabs=\(model.tabs.tabs.count)"
        }

        guard parts.first == "terminal" else {
            return "ui-scene: unknown scene '\(scene)'"
        }
        let pane = model.terminalPane
        pane.setOpen(true)                      // open FIRST so height applies to the live pane
        if parts.contains("top") { pane.setTabPosition(.top) }
        else if parts.contains("right") { pane.setTabPosition(.right) }
        else { pane.setTabPosition(.left) }
        // Pane DOCK edge (TSK-491) — distinct tokens from the tab-strip position.
        // ALWAYS set it (default .bottom) so a scene is DETERMINISTIC and doesn't
        // inherit a persisted edge from a prior launch.
        if parts.contains("paneright") { pane.setPaneEdge(.right) }
        else if parts.contains("paneleft") { pane.setPaneEdge(.left) }
        else { pane.setPaneEdge(.bottom) }
        pane.setHeight(320)
        pane.setWidth(360)
        let count = max(1, parts.compactMap { Int($0) }.first ?? 2)
        while pane.tabs.count < count { pane.addTab() }
        return "ui-scene: applied '\(scene)' tabs=\(pane.tabs.count) height=\(pane.height) edge=\(pane.paneEdge.rawValue) width=\(pane.sideWidth)"
    }
}
