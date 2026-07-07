import Foundation

/// TSK-1481 — the Settings INFORMATION ARCHITECTURE as a host-tested model.
/// SettingsView accreted per-feature into a grab-bag; this catalog is the
/// single source for the reorganized IA: every setting has a stable id (the
/// `mdv.settings.*` AX id where the row already carries one), a section from
/// the canonical order, a one-line description, and a kind — so the IA is
/// pinned by tests and the filter field is searchable-by-test. The SwiftUI
/// re-render FROM this catalog is the pixel tail; no new settings here (pure
/// reorganization per the ticket).
public enum SettingsCatalog {

    /// The canonical section order (the ticket's target IA).
    public enum Section: String, CaseIterable, Sendable, Equatable {
        case general
        case appearance
        case editor
        case viewer
        case dataAndMedia
        case tools
        case automationAndPlugins
        case advanced

        /// Human header.
        public var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .editor: return "Editor"
            case .viewer: return "Viewer"
            case .dataAndMedia: return "Data & Media"
            case .tools: return "Tools"
            case .automationAndPlugins: return "Automation & Plugins"
            case .advanced: return "Advanced"
            }
        }
    }

    /// What the row renders as (drives the rebuilt view's control choice).
    public enum Kind: String, Sendable, Equatable {
        case toggle, picker, field, action, info
    }

    /// One setting row.
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let description: String
        public let section: Section
        public let kind: Kind
        public init(id: String, title: String, description: String, section: Section, kind: Kind) {
            self.id = id
            self.title = title
            self.description = description
            self.section = section
            self.kind = kind
        }
    }

    /// The catalog — the settings surface as it exists today, reorganized
    /// into the canonical sections. Ids reuse the row's existing
    /// `mdv.settings.*` AX id where one exists (the drift guard holds the
    /// view and this list together); rows that lacked an id get one here and
    /// the view adopts it at re-render time.
    public static let items: [Item] = [
        // General
        Item(id: "mdv.settings.sessions", title: "Sessions",
             description: "Keep independent workspaces with their own tabs; restore them on relaunch.",
             section: .general, kind: .toggle),
        Item(id: "mdv.settings.reset.bookmarks", title: "Clear All Bookmarks",
             description: "Removes every file and line bookmark. This can't be undone.",
             section: .general, kind: .action),
        Item(id: "mdv.settings.reset.layout", title: "Reset Window & Layout",
             description: "Resets zoom, sidebar width, and the saved window position.",
             section: .general, kind: .action),
        Item(id: "mdv.settings.fullDiskAccess", title: "Full Disk Access",
             description: "Some locations need Full Disk Access; grant it in System Settings → Privacy & Security.",
             section: .general, kind: .info),
        // Appearance
        Item(id: "mdv.settings.theme", title: "Theme",
             description: "Color theme for source and editor views; Follow System tracks light/dark.",
             section: .appearance, kind: .picker),
        Item(id: "mdv.settings.fontPicker", title: "Source Font",
             description: "Monospace font for source and editor views.",
             section: .appearance, kind: .picker),
        Item(id: "mdv.settings.contentFontSize", title: "Text Size",
             description: "Base font size for editor/source text; Zoom multiplies it and the UI chrome.",
             section: .appearance, kind: .picker),
        // Editor
        Item(id: "mdv.settings.wordWrap", title: "Word Wrap",
             description: "Wrap long lines in source and editor modes.",
             section: .editor, kind: .toggle),
        Item(id: "mdv.settings.invisibles", title: "Show Invisibles",
             description: "Render spaces, tabs, and line breaks as visible glyphs.",
             section: .editor, kind: .toggle),
        Item(id: "mdv.settings.indentGuides", title: "Indent Guides",
             description: "Vertical guides at each indentation level in the editor.",
             section: .editor, kind: .toggle),
        Item(id: "mdv.settings.indentation", title: "Indentation",
             description: "What the Tab key inserts in the editor: spaces or tabs, and the width.",
             section: .editor, kind: .picker),
        Item(id: "mdv.settings.spellCheck", title: "Spell Check",
             description: "Squiggle misspellings in prose files; toggleable from the footer chip too.",
             section: .editor, kind: .toggle),
        Item(id: "mdv.settings.autocomplete", title: "Autocomplete",
             description: "In-file word completion while typing (plus LSP completions where available).",
             section: .editor, kind: .toggle),
        // Viewer
        Item(id: "mdv.settings.languages", title: "Highlighted Languages",
             description: "Languages Source View and the editor highlight, detected by file extension.",
             section: .viewer, kind: .info),
        // Data & Media
        Item(id: "mdv.settings.fileAssociations", title: "File Associations",
             description: "Make TextView the default app for chosen file types; revert any time in Finder.",
             section: .dataAndMedia, kind: .action),
        Item(id: "mdv.settings.audio.ffmpegPath", title: "ffmpeg Path",
             description: "MP3 export needs an external ffmpeg; blank auto-detects on PATH.",
             section: .dataAndMedia, kind: .field),
        // Tools
        Item(id: "mdv.settings.terminal.colorScheme", title: "Terminal Colors",
             description: "Color scheme for the built-in terminal.",
             section: .tools, kind: .picker),
        Item(id: "mdv.settings.terminal.paneEdge", title: "Terminal Position",
             description: "Which edge the terminal pane docks to: bottom, left, or right.",
             section: .tools, kind: .picker),
        Item(id: "mdv.settings.terminal.tabPosition", title: "Terminal Tabs",
             description: "Where the terminal's tab strip sits: left, top, or right.",
             section: .tools, kind: .picker),
        // Automation & Plugins
        Item(id: "mdv.settings.lspLanguages", title: "Language Servers",
             description: "Per-language LSP servers spawn on first use and reap after idle; see diagnostics for live state.",
             section: .automationAndPlugins, kind: .info),
        Item(id: "mdv.settings.plugins", title: "Plugins",
             description: "Plugins live in Application Support; drop a folder there and relaunch.",
             section: .automationAndPlugins, kind: .info),
        // Advanced
        Item(id: "mdv.settings.rustGates", title: "Engine Gates (experimental)",
             description: "Rust-core engine feature gates; defaults are the supported configuration.",
             section: .advanced, kind: .info),
    ]

    /// Sections in canonical order, each with its items (catalog order kept
    /// within a section); empty sections are omitted.
    public static func sections() -> [(section: Section, items: [Item])] {
        Section.allCases.compactMap { s in
            let rows = items.filter { $0.section == s }
            return rows.isEmpty ? nil : (s, rows)
        }
    }

    /// The filter field: case/diacritic-insensitive match on title or
    /// description. Empty/whitespace query → everything.
    public static func filter(_ query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let needle = norm(q)
        return items.filter {
            norm($0.title).contains(needle) || norm($0.description).contains(needle)
        }
    }
}
