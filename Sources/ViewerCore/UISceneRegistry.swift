import Foundation
import CoreGraphics

/// TSK-492 (Foundation) — the deterministic UI-scene REGISTRY + selection
/// contract.
///
/// WHY: `MDV_UI_SCENE` drives the live app into an exact state so the visual-
/// eval harness (`scripts/ui-snapshot.sh`, `scripts/vm-uitest.sh`,
/// `PixelTestCase`/T5) captures a byte-reproducible frame. Before this, the
/// scene catalog was an ad-hoc set of strings parsed inline in
/// `ViewerUI.UISceneApplier` (a chain of `scene.split("-")` / `parts.contains`
/// checks) with no single enumerated source of truth: each test, each script
/// (`vm-uitest.sh` `scene_expect`/`scene_color`, `ui-snapshot.sh`,
/// `vm-diagnose.sh`) re-spelled the scene ids by hand, and an unknown id could
/// only be discovered at the very end of the apply fall-through.
///
/// This consolidates the catalog into ONE pure, host-testable unit:
///
///   * `SceneSpec` — a value type that FULLY and DECLARATIVELY specifies a
///     scene's deterministic target state (which fixture, the surface/view
///     mode, docked panels, terminal edge + tab strip + tab count + size, the
///     theme, any overlay). NO randomness, NO timestamps, NO process state →
///     a given scene id is byte-reproducible across resolutions and processes.
///   * `UISceneRegistry` — maps a (lowercased) `MDV_UI_SCENE` string to its
///     `SceneSpec`, ENUMERATES every known id (`allSceneIDs`), and REJECTS an
///     unknown id (`resolve` returns nil) rather than silently defaulting.
///
/// The pure registry is the deterministic control SURFACE the pixel-eval/diff
/// loop builds on; the actual capture/diff stays VM-coupled (`PixelTestCase`).
/// `ViewerUI.UISceneApplier` performs the LIVE-model mutation and consults this
/// registry so recognition is single-sourced — an id absent from the registry
/// is rejected uniformly instead of falling through ad-hoc branch checks.
public enum UISceneRegistry {

    /// The fixture a scene opens, declared abstractly so the spec carries NO
    /// absolute paths or per-process tmp dirs (those would defeat byte-
    /// reproducibility). The applier resolves these against a per-launch base
    /// dir / the `MDV_PREVIEW_FILE` env at apply time.
    public enum Fixture: Equatable, Sendable {
        /// No file open — the empty-state landing surface.
        case none
        /// The default document the harness launches with (e.g. `DESIGN.md`),
        /// left untouched.
        case defaultDocument
        /// `count` throwaway markdown files opened as PERMANENT tabs.
        case throwawayMarkdown(count: Int)
        /// A single throwaway source file (named) opened as the editor backdrop.
        case throwawaySource(name: String)
        /// A single throwaway media file (a tiny valid PNG) opened so the media
        /// preview / metadata path renders.
        case throwawayImage(name: String)
        /// A folder root opened with NO file tab selected.
        case folderRoot
        /// The ephemeral preview slot, fed by `MDV_PREVIEW_FILE`.
        case previewFromEnv
    }

    /// An overlay surface a scene presents on top of its backdrop, so the
    /// harness can capture a sheet/picker that has no standalone scene.
    public enum Overlay: Equatable, Sendable {
        case none
        /// The LSP rename prompt sheet (`isLSPRenamePromptPresented`).
        case lspRenamePrompt
        /// The LSP code-action picker, driven into `.presenting` with canned
        /// actions (DEBUG-only seam).
        case codeActionPicker
        /// The media-file metadata panel (`showPreviewMetadataPanel`).
        case metadataPanel
    }

    /// The terminal-pane portion of a scene's target state. `nil` (via the
    /// optional on `SceneSpec`) means the terminal stays CLOSED.
    public struct TerminalState: Equatable, Sendable {
        /// Which window edge the pane docks to.
        public let edge: TerminalPaneEdge
        /// Where the tab strip sits inside the pane.
        public let tabPosition: TerminalTabPosition
        /// How many terminal tabs to seed (≥ 1).
        public let tabCount: Int
        /// Deterministic pane height (bottom band).
        public let height: CGFloat
        /// Deterministic pane width (side column).
        public let width: CGFloat

        public init(
            edge: TerminalPaneEdge,
            tabPosition: TerminalTabPosition,
            tabCount: Int,
            height: CGFloat,
            width: CGFloat
        ) {
            self.edge = edge
            self.tabPosition = tabPosition
            self.tabCount = max(1, tabCount)
            self.height = height
            self.width = width
        }
    }

    /// A FULLY-specified, deterministic description of a scene's target state.
    /// Every field is value-typed and derived only from the scene id (plus
    /// declared fixtures), so two resolutions of the same id are `==`.
    public struct SceneSpec: Equatable, Sendable {
        /// The canonical scene id (lowercased) this spec was resolved from.
        public let id: String
        /// What file/fixture the scene opens.
        public let fixture: Fixture
        /// Whether all pre-existing tabs are closed before opening the fixture
        /// (so the fixture is the SOLE, foreground surface).
        public let closesExistingTabs: Bool
        /// The terminal-pane target, or `nil` if the terminal stays closed.
        public let terminal: TerminalState?
        /// An overlay sheet/picker to present on top, or `.none`.
        public let overlay: Overlay
        /// The built-in theme id to select, or `nil` to leave the theme alone.
        public let themeID: String?
        /// A scene is `DEBUG`-only when it relies on a debug-only present seam;
        /// a release build must REJECT it (loud failure, never a false green).
        public let isDebugOnly: Bool
        /// A human-facing one-line description (no dynamic data → stable).
        public let summary: String

        public init(
            id: String,
            fixture: Fixture,
            closesExistingTabs: Bool = false,
            terminal: TerminalState? = nil,
            overlay: Overlay = .none,
            themeID: String? = nil,
            isDebugOnly: Bool = false,
            summary: String
        ) {
            self.id = id
            self.fixture = fixture
            self.closesExistingTabs = closesExistingTabs
            self.terminal = terminal
            self.overlay = overlay
            self.themeID = themeID
            self.isDebugOnly = isDebugOnly
            self.summary = summary
        }
    }

    // MARK: - Deterministic constants (shared with the applier)

    /// Deterministic terminal-pane height for `terminal-*` scenes — tall enough
    /// that a vertical chip rail is visible. Pinned by host test.
    public static let terminalHeight: CGFloat = 320
    /// Deterministic terminal side-column width for `terminal-*` scenes.
    public static let terminalWidth: CGFloat = 360
    /// Default terminal tab seed count when a `terminal-*` id omits `-<N>`.
    public static let defaultTerminalTabCount = 2
    /// Default file-tab count when a `tabs` id omits `-<N>`.
    public static let defaultFileTabCount = 3

    // MARK: - Static (non-parametric) scenes

    /// The fixed, fully-enumerated scenes whose id is a literal (no numeric or
    /// directional parameter). Parametric families (`terminal-*`, `tabs-<N>`,
    /// `preview[-promoted]`) are resolved by `resolve` below; their canonical
    /// representatives are listed in `allSceneIDs` for enumeration tests.
    private static let staticScenes: [SceneSpec] = [
        SceneSpec(
            id: "landing",
            fixture: .none,
            summary: "Empty-state landing (New File / recents); no tabs, terminal closed"),
        SceneSpec(
            id: "folder-only",
            fixture: .folderRoot,
            closesExistingTabs: true,
            summary: "A folder root open with NO file tab selected (TSK-738 footer gate)"),
        SceneSpec(
            id: "theme-dark",
            fixture: .defaultDocument,
            themeID: "xcode-dark",
            summary: "Dark built-in theme selected over the default doc (TSK-641 chrome paint)"),
        SceneSpec(
            id: "theme-light",
            fixture: .defaultDocument,
            closesExistingTabs: true,
            themeID: "xcode-light",
            summary: "Light theme + aqua appearance, RENDERED markdown tour (table/tasks/mermaid/math/alert/footnote) + file nav + sessions (marketing + light chrome paint)"),
        SceneSpec(
            id: "mktg-docs",
            fixture: .defaultDocument,
            closesExistingTabs: true,
            summary: "Marketing: welcome sample in Source lens + bottom terminal running top (native-drawn surfaces only — WebView lenses capture blank, TSK-1247)"),
        SceneSpec(
            id: "mktg-split",
            fixture: .defaultDocument,
            closesExistingTabs: true,
            themeID: "xcode-dark",
            summary: "Marketing: welcome sample split — editor + rendered preview, FILE NAV sidebar, dark theme (also the on-screen proof for the split themed-CSS fix)"),
        SceneSpec(
            id: "mktg-code",
            fixture: .defaultDocument,
            closesExistingTabs: true,
            themeID: "xcode-dark",
            summary: "Marketing: file nav on a git root + bookmarks, 3 tabs, Swift source highlighting, command palette overlay"),
        SceneSpec(
            id: "mktg-git",
            fixture: .defaultDocument,
            closesExistingTabs: true,
            themeID: "xcode-dark",
            summary: "Marketing: git panel on the LOG tab (real repo graph) + file nav, repo file in Source"),
        SceneSpec(
            id: "lsp-rename",
            fixture: .throwawaySource(name: "rename-target.swift"),
            overlay: .lspRenamePrompt,
            summary: "LSP rename prompt sheet over an editor backdrop (TSK-640)"),
        SceneSpec(
            id: "metadata-checksum",
            fixture: .throwawayImage(name: "sample.png"),
            closesExistingTabs: true,
            overlay: .metadataPanel,
            summary: "Media file + metadata panel with the checksum section (TSK-748)"),
        SceneSpec(
            id: "code-actions",
            fixture: .throwawaySource(name: "codeaction-target.swift"),
            overlay: .codeActionPicker,
            isDebugOnly: true,
            summary: "LSP code-action picker over an editor backdrop (TSK-640, DEBUG)"),
        SceneSpec(
            id: "math-render",
            fixture: .throwawaySource(name: "math-sample.md"),
            closesExistingTabs: true,
            summary: "Markdown with inline + display LaTeX in Rendered mode — "
                + "MathML must paint real glyphs (2026-07-29 pulldown-latex)"),
        SceneSpec(
            id: "md-split",
            fixture: .throwawaySource(name: "split-sample.md"),
            closesExistingTabs: true,
            summary: "Markdown in the mode bar's Split segment: editor left, "
                + "live rendered preview right (2026-07-29)"),
        SceneSpec(
            id: "conflict-merge",
            fixture: .throwawaySource(name: "conflict-sample.md"),
            closesExistingTabs: true,
            summary: "The 3-pane conflict-resolution sheet over a dirty tab "
                + "whose file diverged on disk (TSK-1171, first mounted 2026-07-29)"),
        SceneSpec(
            id: "tab-session-drop",
            fixture: .throwawaySource(name: "drag-sample.md"),
            closesExistingTabs: true,
            summary: "Two sessions; the second pill lit as the drop target of a "
                + "live tab drag (tab→session move, 2026-07-31)"),
        SceneSpec(
            id: "video-unsupported",
            fixture: .throwawaySource(name: "sample.mkv"),
            closesExistingTabs: true,
            summary: "Unsupported video container (.mkv) → VideoFallbackCard, not a black AVPlayerView (TSK-1474)"),
        SceneSpec(
            id: "archive-preview",
            fixture: .throwawaySource(name: "sample.zip"),
            closesExistingTabs: true,
            summary: "Zip archive → ArchiveBrowserView master/detail list + preview (TSK-1469)"),
        SceneSpec(
            id: "notebook",
            fixture: .throwawaySource(name: "sample.ipynb"),
            closesExistingTabs: true,
            summary: "Jupyter .ipynb → NotebookCellListView with rendered outputs (TSK-1440); enables NotebookGate"),
        SceneSpec(
            id: "depgraph",
            fixture: .folderRoot,
            closesExistingTabs: true,
            summary: "Import-dependency graph over a 3-file folder (Alpha→Beta→Gamma) → DependencyGraphView hosted tab (TSK-1470)"),
        SceneSpec(
            id: "outline",
            fixture: .throwawaySource(name: "outline-doc.md"),
            closesExistingTabs: true,
            summary: "Markdown doc with ≥6 headings + sidebar open → the mounted .markdownOutline panel lists them (TSK-1438)"),
        SceneSpec(
            id: "favorites",
            fixture: .none,
            summary: "Seeded favorites + the Manage Favorites… editor sheet open → TerminalFavoritesEditor lists them in order (TSK-1475)"),
        SceneSpec(
            id: "secrets",
            fixture: .throwawaySource(name: "config.env"),
            closesExistingTabs: true,
            summary: "Doc with an AWS key + GitHub token (+ a benign UUID) → the SecretWarningBanner flags the secrets, UUID stays quiet (TSK-1496)"),
        SceneSpec(
            id: "omni",
            fixture: .none,
            closesExistingTabs: true,
            summary: "Empty-state new-tab launchpad with the omnibox field (path/URL/git/search) + New… buttons (TSK-1489)"),
        SceneSpec(
            id: "structural-search",
            fixture: .throwawaySource(name: "sample.swift"),
            closesExistingTabs: true,
            summary: "Structural Search panel over a Swift file → query field w/ help placeholder + Examples button (TSK-1476)"),
        SceneSpec(
            id: "terminal-header",
            fixture: .none,
            summary: "Terminal pane (top strip) → the header row 'Terminal — <name> [<cwd>, pid <n>]' above the surface (TSK-1249)"),
        SceneSpec(
            id: "terminal-dock-right",
            fixture: .none,
            summary: "Terminal docked to the RIGHT edge (the owner's 'can't get the terminal to the right' pain) with the new Dock control in the strip (TSK-1123)"),
        SceneSpec(
            id: "recover-deleted",
            fixture: .none,
            closesExistingTabs: true,
            summary: "A deleted-but-has-history file → the Recover Deleted File sheet lists it with a Recreate action (TSK-1500)"),
        SceneSpec(
            id: "first-run",
            fixture: .none,
            closesExistingTabs: true,
            summary: "The first-run sample tour ('Welcome to TextView.md') opened rendered — headings/table/mermaid demo the lenses (TSK-1448)"),
        SceneSpec(
            id: "lsp-status",
            fixture: .throwawaySource(name: "sample.swift"),
            closesExistingTabs: true,
            summary: "A Swift file open → the footer LSP status chip (mdv.statusBar.lsp) shows the language-server state; MDV_LSP_STATUS_FAKE forces a deterministic state (TSK-1444)"),
        SceneSpec(
            id: "git-panel",
            fixture: .folderRoot,
            closesExistingTabs: true,
            summary: "A fixture git repo (staged + unstaged + untracked) open with Git ▸ Status focused → the three groups + per-row stage/unstage + the commit bar render (TSK-1443/1577)"),
    ]

    /// Every CANONICAL scene id the registry knows — the static scenes plus one
    /// representative of each parametric family. Used by the harness scripts and
    /// the enumeration host tests (uniqueness, full coverage). Stable order.
    public static let allSceneIDs: [String] =
        staticScenes.map(\.id) + [
            "terminal",          // terminal family, default left strip / bottom edge
            "terminal-left",
            "terminal-top",
            "terminal-right",
            "terminal-paneleft",
            "terminal-paneright",
            "tabs",              // file-tab family, default count
            "preview",           // preview family (needs MDV_PREVIEW_FILE)
            "preview-promoted",
        ]

    // MARK: - Resolution

    /// Resolve a (case-insensitive) `MDV_UI_SCENE` string to its fully-specified
    /// `SceneSpec`, or `nil` if the id is UNKNOWN. An unknown id is REJECTED
    /// here — callers must surface it loudly rather than silently default to
    /// some baseline scene (which would make the harness capture the wrong
    /// pixels: a false green).
    ///
    /// Deterministic: the returned spec depends ONLY on `rawScene` — no
    /// randomness, no timestamps, no environment, no process state — so
    /// `resolve(x) == resolve(x)` always holds (byte-reproducible).
    public static func resolve(_ rawScene: String) -> SceneSpec? {
        let scene = rawScene.lowercased()
        guard !scene.isEmpty else { return nil }

        // Static (literal-id) scenes.
        if let fixed = staticScenes.first(where: { $0.id == scene }) {
            return fixed
        }

        let parts = scene.split(separator: "-").map(String.init)
        guard let head = parts.first else { return nil }

        switch head {
        case "terminal":
            // terminal[-left|-top|-right][-paneleft|-paneright][-<N>]
            // Every non-head token must be a known strip/edge keyword or an
            // integer; a stray token (e.g. `terminal-foo`) is REJECTED.
            let knownTokens: Set<String> =
                ["left", "top", "right", "paneleft", "paneright"]
            for tok in parts.dropFirst() where knownTokens.contains(tok) == false && Int(tok) == nil {
                return nil
            }
            let tabPosition: TerminalTabPosition =
                parts.contains("top") ? .top
                : parts.contains("right") ? .right
                : .left
            let edge: TerminalPaneEdge =
                parts.contains("paneright") ? .right
                : parts.contains("paneleft") ? .left
                : .bottom
            let count = parts.compactMap { Int($0) }.first ?? defaultTerminalTabCount
            return SceneSpec(
                id: scene,
                fixture: .defaultDocument,
                terminal: TerminalState(
                    edge: edge,
                    tabPosition: tabPosition,
                    tabCount: count,
                    height: terminalHeight,
                    width: terminalWidth),
                summary: "Terminal pane (edge=\(edge.rawValue), strip=\(tabPosition.rawValue), tabs=\(max(1, count)))")

        case "tabs":
            // tabs[-<N>] — N permanent file tabs, first selected. Only an
            // optional integer token is allowed; `tabs-foo` is REJECTED.
            guard parts.count <= 2 else { return nil }
            if parts.count == 2, Int(parts[1]) == nil { return nil }
            let count = parts.compactMap { Int($0) }.first ?? defaultFileTabCount
            return SceneSpec(
                id: scene,
                fixture: .throwawayMarkdown(count: max(1, count)),
                summary: "\(max(1, count)) permanent file tabs, first selected")

        case "preview":
            // preview | preview-promoted — the ephemeral preview slot from
            // MDV_PREVIEW_FILE. Strict allowlist: a stray trailing token (e.g.
            // `preview-bogus`) is REJECTED, not silently treated as a plain
            // preview — recognition must be exact so a typo can't false-green.
            switch parts.count {
            case 1:
                return SceneSpec(
                    id: scene,
                    fixture: .previewFromEnv,
                    summary: "Ephemeral preview slot (needs MDV_PREVIEW_FILE)")
            case 2 where parts[1] == "promoted":
                return SceneSpec(
                    id: scene,
                    fixture: .previewFromEnv,
                    summary: "Preview slot promoted to a permanent tab (needs MDV_PREVIEW_FILE)")
            default:
                return nil
            }

        default:
            return nil
        }
    }

    /// True iff `rawScene` is a recognised scene id.
    public static func isKnown(_ rawScene: String) -> Bool {
        resolve(rawScene) != nil
    }
}
