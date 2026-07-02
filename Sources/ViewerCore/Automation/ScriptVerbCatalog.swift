import Foundation

/// Programmatic inventory of the `--script` / palette verb vocabulary
/// (TSK-799 — "How does scripting work?").
///
/// ## Why this exists
///
/// The actual verb dispatch lives in one big `switch` in
/// `ScriptVerb.apply(verb:to:sessions:)` (ViewerUI/Automation/
/// `ScriptVerbDispatch.swift`). That switch is the runtime authority, but
/// it is **not introspectable**: nothing can ask "what verbs exist?", the
/// docs hand-maintain a table that silently rots, and there is no single
/// place a test can pin the vocabulary against. A `switch` over string
/// literals can drift from its documentation with zero compiler help.
///
/// `ScriptVerbCatalog` is the *data* mirror of that switch: every verb the
/// dispatcher recognises, grouped by the surface it drives, each with a
/// one-line description and an argument shape. It is pure ViewerCore (no
/// AppKit, no `@MainActor`), so it is host-unit-testable and can back the
/// scripting documentation, a `--list-verbs` flag, or palette/help UI.
///
/// ## Sync obligation
///
/// The dispatch switch lives in ViewerUI (it needs `DocumentModel` /
/// `SessionsAppCoordinator`), which imports ViewerCore — so this catalog
/// in ViewerCore **cannot** reach into the switch to introspect it.
/// Therefore the two are kept in sync by a single rule, enforced by
/// `ScriptVerbCatalogTests`:
///
/// > When you add a `case "<verb>":` to `ScriptVerb.apply`, add a matching
/// > `ScriptVerb` row here (and vice-versa).
///
/// `ScriptVerbCatalogTests.testCatalogMatchesDispatchSwitch` parses the
/// dispatch source file's `case "…":` labels and asserts the two sets are
/// identical, so a drift fails the host gate rather than rotting silently.
public enum ScriptVerbCatalog {

    /// The surface a verb drives. Mirrors the section comments in the
    /// dispatch switch so the documentation can group verbs the same way.
    public enum Surface: String, Sendable, CaseIterable, Comparable {
        case view          // view-mode / zoom / sidebar / split toggles
        case tabs          // tab lifecycle + navigation
        case files         // open / open-as / reload / save
        case editor        // CM6 editor buffer + flow verbs
        case lsp           // language-server navigation + seeding
        case find          // in-doc find + cross-file search
        case sidebar       // file-tree navigation
        case sessions      // multi-session coordinator
        case git           // git panel + log-diff actions
        case bookmarks     // file/line bookmarks
        case metadata      // info-panel checksum
        case tools         // clipboard text tools
        case palette       // command palette / go-to prompt
        case canvas        // canvas agent surface (M2.S6 — export / apply-file)
        case harness       // test/profiling-only (delay, snapshot, nav-sweep…)

        public var title: String {
            switch self {
            case .view:      return "View"
            case .tabs:      return "Tabs"
            case .files:     return "Files"
            case .editor:    return "Editor"
            case .lsp:       return "Language Server"
            case .find:      return "Find"
            case .sidebar:   return "Sidebar"
            case .sessions:  return "Sessions"
            case .git:       return "Git"
            case .bookmarks: return "Bookmarks"
            case .metadata:  return "Metadata"
            case .tools:     return "Text Tools"
            case .palette:   return "Command Palette"
            case .canvas:    return "Canvas"
            case .harness:   return "Harness / Profiling"
            }
        }

        public static func < (lhs: Surface, rhs: Surface) -> Bool {
            let order = Surface.allCases
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    /// The argument shape a verb expects after its token. Documentation +
    /// any future validation reads this; the dispatcher itself parses the
    /// raw remainder string per-case.
    public enum ArgShape: String, Sendable, Equatable {
        /// No argument (`toggle-view`, `zoom-in`, `next-tab`).
        case none
        /// A filesystem path (`open`, `sidebar-set-root`, `save-copy`).
        case path
        /// An integer, usually a 1-based index/line (`select-tab`, `session-activate`).
        case int
        /// A free-form string token (`set-theme`, `set-cross-query`, `lsp-rename`).
        case string
        /// A constrained enum token (`editor-set-mode` view mode, `set-open-as` category).
        case enumToken
        /// A small structured argument — space-separated fields the case splits
        /// itself (`open-as "<category> <path>"`, `lsp-seed-diagnostics "<e> <w> …"`).
        case structured
    }

    /// One recognised script verb.
    public struct ScriptVerb: Sendable, Hashable, Identifiable {
        /// The verb token — the first whitespace-delimited word of a script
        /// line, and the exact `case "…"` label in the dispatch switch.
        public let token: String
        public let surface: Surface
        public let arg: ArgShape
        /// One-line human description for docs / help UI.
        public let summary: String

        public var id: String { token }

        public init(_ token: String, _ surface: Surface, _ arg: ArgShape, _ summary: String) {
            self.token = token
            self.surface = surface
            self.arg = arg
            self.summary = summary
        }
    }

    /// Every verb the `ScriptVerb.apply` switch recognises, in dispatch
    /// order. KEEP IN SYNC with `ScriptVerbDispatch.swift` (the test
    /// enforces it). Verbs whose `case` is shared with sibling tokens
    /// (the `git-log-click` family) are listed once per token.
    public static let all: [ScriptVerb] = [
        // Canvas (M2.S6, TSK-1371) — doc = an open doc id OR a .canvas path
        // (auto-opened through the store).
        ScriptVerb("canvas-export", .canvas, .structured,
                   "Export a canvas doc to standalone HTML: \"<doc> <outPath>\""),
        ScriptVerb("canvas-apply-file", .canvas, .structured,
                   "Apply a canvas DSL file: \"<doc> <baseRev> <dslPath>\""),
        // ---- View ----
        ScriptVerb("toggle-view", .view, .none, "Toggle source ↔ rendered view mode"),
        ScriptVerb("toggle-sidebar", .view, .none, "Show/hide the file sidebar"),
        ScriptVerb("zoom-in", .view, .none, "Increase zoom"),
        ScriptVerb("zoom-out", .view, .none, "Decrease zoom"),
        ScriptVerb("zoom-reset", .view, .none, "Reset zoom to 100%"),
        ScriptVerb("toggle-format", .view, .none, "Toggle pretty-print/format for the current tab"),
        ScriptVerb("toggle-word-wrap", .view, .none, "Toggle source word-wrap"),
        ScriptVerb("toggle-invisibles", .view, .none, "Toggle showing invisible characters"),
        ScriptVerb("toggle-split", .view, .none, "Toggle the split-pane view"),
        ScriptVerb("close-split", .view, .none, "Close the split-pane view (deterministic; toggle-split is state-dependent)"),
        ScriptVerb("swap-split", .view, .none, "Swap the two split panes"),
        ScriptVerb("set-theme", .view, .string, "Select a theme by id (empty = Follow System)"),
        ScriptVerb("folder-stats", .view, .enumToken, "Folder-stats panel: on|off|<empty toggles>"),
        ScriptVerb("focus-document", .view, .none, "Move keyboard focus to the active document"),
        ScriptVerb("focus-terminal", .view, .none, "Open/focus the terminal"),
        ScriptVerb("focus-file-nav", .view, .none, "Focus the file navigator"),
        ScriptVerb("focus-git", .view, .none, "Open/focus the git panel"),
        ScriptVerb("terminal-open-here", .view, .none, "Open a terminal at the current location"),

        // ---- Tabs ----
        ScriptVerb("new-tab", .tabs, .none, "Open a new blank tab"),
        ScriptVerb("close-tab", .tabs, .none, "Close the current tab"),
        ScriptVerb("next-tab", .tabs, .none, "Select the next tab"),
        ScriptVerb("prev-tab", .tabs, .none, "Select the previous tab"),
        ScriptVerb("select-tab", .tabs, .int, "Select a tab by 1-based index"),
        ScriptVerb("move-tab-left", .tabs, .none, "Move the current tab left"),
        ScriptVerb("move-tab-right", .tabs, .none, "Move the current tab right"),
        ScriptVerb("confirm-dirty-close", .tabs, .enumToken, "Pre-arm the dirty-close prompt: save|discard|cancel"),

        // ---- Files ----
        ScriptVerb("open", .files, .path, "Open a file or folder"),
        ScriptVerb("open-lazy", .files, .path, "Append a lazy (deferred-load) tab without selecting it"),
        ScriptVerb("open-as", .files, .structured, "Open a path forced to a viewer category: \"<category> <path>\""),
        ScriptVerb("set-open-as", .files, .enumToken, "Override the current tab's viewer category (or 'auto')"),
        ScriptVerb("reload", .files, .none, "Re-read the current file from disk"),
        ScriptVerb("save-copy", .files, .path, "Write a copy of the current tab to an absolute path"),
        ScriptVerb("clear-recents", .files, .none, "Clear the Recent Files / history list"),

        // ---- Editor (CM6) ----
        ScriptVerb("editor-set-mode", .editor, .enumToken, "Force the active tab into a view mode"),
        ScriptVerb("editor-focus", .editor, .none, "Hand keyboard first-responder to the active editor"),
        ScriptVerb("copy-reference", .editor, .none, "Copy an mdv:// reference to the current editor line"),
        ScriptVerb("goto-line", .editor, .int, "Scroll the active editor/source to a 1-based line"),
        ScriptVerb("convert-encoding", .editor, .string,
                   "Re-save the active file in a target text encoding (utf-8 / utf-16 / windows-1252 / iso-latin-1)"),
        ScriptVerb("align-tables", .editor, .none, "Re-align GFM pipe tables in the active markdown editor"),
        ScriptVerb("editor-set-text", .editor, .string, "Replace the active tab's editor buffer text"),
        ScriptVerb("editor-save", .editor, .none, "Save the active editor buffer (⌘S equivalent)"),
        ScriptVerb("editor-format", .editor, .none, "Whole-document LSP format of the active buffer"),
        ScriptVerb("edit-remove-empty-lines", .editor, .none, "Remove empty lines in the active file"),
        ScriptVerb("edit-collapse-blank-lines", .editor, .none, "Collapse runs of blank lines"),
        ScriptVerb("edit-trim-trailing", .editor, .none, "Trim trailing whitespace"),
        ScriptVerb("edit-ensure-final-newline", .editor, .none, "Ensure a final newline"),
        ScriptVerb("edit-minify-json", .editor, .none, "Minify the active JSON document"),
        ScriptVerb("edit-insert-toc", .editor, .none, "Insert a Markdown table of contents"),
        ScriptVerb("edit-insert-date", .editor, .none, "Insert the current date and time"),
        ScriptVerb("edit-uppercase", .editor, .none, "Make the active file UPPER CASE"),
        ScriptVerb("edit-lowercase", .editor, .none, "Make the active file lower case"),
        ScriptVerb("edit-capitalize", .editor, .none, "Capitalize the active file"),
        ScriptVerb("edit-promote-heading", .editor, .none, "Promote Markdown headings (decrease level, ## → #)"),
        ScriptVerb("edit-demote-heading", .editor, .none, "Demote Markdown headings (increase level, # → ##)"),
        ScriptVerb("edit-sort-lines", .editor, .none, "Sort the active file's lines ascending"),
        ScriptVerb("edit-sort-lines-desc", .editor, .none, "Sort the active file's lines descending"),
        ScriptVerb("edit-reverse-lines", .editor, .none, "Reverse the order of the active file's lines"),
        ScriptVerb("edit-remove-duplicate-lines", .editor, .none, "Remove duplicate lines from the active file"),
        ScriptVerb("convert-line-endings-lf", .editor, .none, "Convert the active file's line endings to LF"),
        ScriptVerb("convert-line-endings-crlf", .editor, .none, "Convert the active file's line endings to CRLF"),
        ScriptVerb("convert-line-endings-cr", .editor, .none, "Convert the active file's line endings to CR"),
        ScriptVerb("convert-indentation-to-spaces", .editor, .none, "Convert the active file's leading tabs to spaces"),
        ScriptVerb("convert-indentation-to-tabs", .editor, .none, "Convert the active file's leading spaces to tabs"),
        ScriptVerb("macro-record-start", .view, .none, "Start recording a command macro"),
        ScriptVerb("macro-record-stop", .view, .none, "Stop recording and store the command macro"),
        ScriptVerb("macro-replay-last", .view, .none, "Replay the last recorded command macro"),
        ScriptVerb("toggle-view-only", .editor, .none, "Toggle View-only (read-only) mode"),
        ScriptVerb("toggle-blame", .editor, .none, "Toggle the editor git-blame gutter"),
        ScriptVerb("fold-all", .editor, .none, "Fold all foldable regions in the active editor"),
        ScriptVerb("unfold-all", .editor, .none, "Unfold all regions in the active editor"),

        // ---- Language Server ----
        ScriptVerb("editor-goto-definition", .lsp, .none, "Go to definition at the cursor"),
        ScriptVerb("editor-goto-declaration", .lsp, .none, "Go to declaration at the cursor"),
        ScriptVerb("editor-goto-type-definition", .lsp, .none, "Go to type definition at the cursor"),
        ScriptVerb("editor-goto-implementation", .lsp, .none, "Go to implementation at the cursor"),
        ScriptVerb("editor-find-references", .lsp, .none, "List references at the cursor in the nav panel"),
        ScriptVerb("lsp-rename", .lsp, .string, "Rename the symbol at the cursor to <arg>"),
        ScriptVerb("show-lsp-rename", .lsp, .none, "Open the interactive Rename Symbol prompt"),
        ScriptVerb("show-code-actions", .lsp, .none, "Open the LSP Code Actions picker at the cursor"),
        ScriptVerb("lsp-seed-diagnostics", .lsp, .structured, "Seed diagnostics: \"<errors> <warnings> [info] [hints]\""),
        ScriptVerb("lsp-clear-diagnostics", .lsp, .none, "Clear all seeded diagnostics"),
        ScriptVerb("lsp-seed-references", .lsp, .int, "Seed <count> synthetic reference rows"),
        ScriptVerb("lsp-clear-navigation", .lsp, .none, "Clear the LSP navigation panel"),

        // ---- Find ----
        ScriptVerb("show-find", .find, .none, "Show the in-document find bar"),
        ScriptVerb("dismiss-find", .find, .none, "Dismiss the find bar"),
        ScriptVerb("find-next", .find, .none, "Jump to the next find match"),
        ScriptVerb("find-prev", .find, .none, "Jump to the previous find match"),
        ScriptVerb("show-cross-search", .find, .none, "Show the cross-file search overlay"),
        ScriptVerb("dismiss-cross-search", .find, .none, "Dismiss the cross-file search overlay"),
        ScriptVerb("set-cross-query", .find, .string, "Show, populate, and run a cross-file search"),

        // ---- Sidebar ----
        ScriptVerb("sidebar-set-root", .sidebar, .path, "Set the sidebar root folder"),
        ScriptVerb("sidebar-select-next", .sidebar, .none, "Select the next sidebar row"),
        ScriptVerb("sidebar-select-prev", .sidebar, .none, "Select the previous sidebar row"),
        ScriptVerb("sidebar-walk-up", .sidebar, .none, "Collapse or focus the parent folder"),

        // ---- Sessions ----
        ScriptVerb("session-open-folder", .sessions, .path, "Open a folder in a session"),
        ScriptVerb("session-open-new", .sessions, .path, "Open a folder forcing a new session"),
        ScriptVerb("session-activate", .sessions, .int, "Activate a session by 1-based index"),
        ScriptVerb("session-close-active", .sessions, .none, "Close the active session"),
        ScriptVerb("session-open-home", .sessions, .none, "Open a new session at the home directory"),
        ScriptVerb("session-new-via-goto", .sessions, .none, "New session that opens the GoTo prompt prefilled with ~"),
        ScriptVerb("session-next", .sessions, .none, "Activate the next session"),
        ScriptVerb("session-prev", .sessions, .none, "Activate the previous session"),
        ScriptVerb("session-rename", .sessions, .string, "Rename the active session"),

        // ---- Git ----
        ScriptVerb("show-git-panel", .git, .none, "Show the git panel"),
        ScriptVerb("show-repo-history", .git, .none, "Open the git panel on the Log (history) tab"),
        ScriptVerb("git-file-history", .git, .none, "Show file history for the current file"),
        ScriptVerb("file-history", .git, .path, "Open file history for a given path"),
        ScriptVerb("git-panel-root", .git, .path, "Pin the git panel repo root (empty = sidebar root)"),
        ScriptVerb("git-panel-tab", .git, .enumToken, "Switch the git panel tab"),
        ScriptVerb("git-log-click", .git, .string, "Click a git log row by SHA"),
        ScriptVerb("git-log-cmd-click", .git, .string, "Cmd-click a git log row by SHA (multi-select)"),
        ScriptVerb("git-log-shift-click", .git, .string, "Shift-click a git log row by SHA (range)"),
        ScriptVerb("git-log-cumulative-diff", .git, .none, "Show the cumulative diff of selected commits"),
        ScriptVerb("goto-commit", .git, .string, "Commit the GoTo path (same session)"),
        ScriptVerb("goto-commit-new-session", .git, .string, "Commit the GoTo path in a new session"),

        // ---- Bookmarks ----
        ScriptVerb("toggle-bookmark", .bookmarks, .none, "Toggle a file-level bookmark on the current tab"),
        ScriptVerb("toggle-line-bookmark", .bookmarks, .none, "Toggle a line bookmark at the current line"),

        // ---- Metadata ----
        ScriptVerb("metadata-compute-checksum", .metadata, .none, "Compute the info-panel SHA-256 checksum"),
        ScriptVerb("metadata-set-checksum-algorithm", .metadata, .enumToken, "Set the checksum algorithm"),

        // ---- Text Tools (clipboard) ----
        ScriptVerb("tools.uuid", .tools, .none, "Generate a UUID to the clipboard"),
        ScriptVerb("tools.sha256", .tools, .none, "SHA-256 the clipboard text"),
        ScriptVerb("tools.base64Encode", .tools, .none, "Base64-encode the clipboard"),
        ScriptVerb("tools.base64Decode", .tools, .none, "Base64-decode the clipboard"),
        ScriptVerb("tools.sortLinesAsc", .tools, .none, "Sort clipboard lines ascending"),
        ScriptVerb("tools.sortLinesDesc", .tools, .none, "Sort clipboard lines descending"),
        ScriptVerb("tools.uniqueLines", .tools, .none, "Dedupe clipboard lines"),
        ScriptVerb("tools.reverseLines", .tools, .none, "Reverse clipboard lines"),
        ScriptVerb("tools.upperCase", .tools, .none, "Uppercase the clipboard"),
        ScriptVerb("tools.lowerCase", .tools, .none, "Lowercase the clipboard"),
        ScriptVerb("tools.trimTrailing", .tools, .none, "Trim trailing whitespace on clipboard lines"),
        ScriptVerb("tools.urlEncode", .tools, .none, "URL-encode the clipboard"),
        ScriptVerb("tools.urlDecode", .tools, .none, "URL-decode the clipboard"),
        ScriptVerb("tools.htmlEncode", .tools, .none, "HTML-encode the clipboard"),
        ScriptVerb("tools.htmlDecode", .tools, .none, "HTML-decode the clipboard"),
        ScriptVerb("tools.fileChecksum", .tools, .none, "SHA-256 of the current file → clipboard"),

        // ---- Command Palette ----
        ScriptVerb("show-palette", .palette, .none, "Show the command palette"),
        ScriptVerb("show-dependency-graph", .view, .none, "Open the project's import dependency graph"),
        ScriptVerb("show-folder-treemap", .view, .none, "Open the project folder's size treemap"),
        ScriptVerb("new-image", .files, .none, "Create and open a new blank image"),
        ScriptVerb("show-walkthroughs", .view, .none, "Browse and run saved walkthroughs"),
        ScriptVerb("dismiss-palette", .palette, .none, "Dismiss the command palette"),
        ScriptVerb("show-goto", .palette, .none, "Show the GoTo path prompt"),
        ScriptVerb("dismiss-goto", .palette, .none, "Dismiss the GoTo path prompt"),

        // ---- Harness / Profiling ----
        ScriptVerb("delay", .harness, .int, "Pause the script runner for N seconds (VM path only)"),
        ScriptVerb("snapshot", .harness, .none, "Capture a per-step PNG+JSON dump (handled by the caller)"),
        ScriptVerb("nav-sweep", .harness, .int, "Run a navigation-interaction sweep for N cycles (profiling)"),
        ScriptVerb("emit-test-log", .harness, .none, "Emit smoke observability events for the Logs view"),
        ScriptVerb("capture-rendered-scroll", .harness, .none, "Probe the live rendered preview's window.scrollY into the next dump (TSK-1046)"),
        ScriptVerb("capture-editor-scroll", .harness, .none, "Probe the live CM6 editor's scrollTop + viewport top line into the next dump (TSK-1047)"),
        ScriptVerb("editor-scroll-to-line", .harness, .int, "Scroll the live CM6 editor so line N is at the viewport top, no caret move (TSK-1046)"),
        ScriptVerb("rendered-scroll-to", .harness, .int, "Scroll the live rendered preview to pixel offset N (TSK-1046)"),
        ScriptVerb("wait-editor-line", .harness, .int, "Block the step until the LIVE CM6 viewport top line reaches ~N (wait-for-settle, timeout) and stash it (TSK-1047)"),
        ScriptVerb("wait-rendered-scroll", .harness, .int, "Block the step until the LIVE rendered window.scrollY reaches ~N (wait-for-settle, timeout) and stash it (TSK-1047)"),
    ]

    /// Lookup by verb token. O(1) via the precomputed index.
    public static func verb(_ token: String) -> ScriptVerb? {
        index[token]
    }

    /// All verb tokens the catalog knows, as a set (for sync checks).
    public static var tokens: Set<String> {
        Set(all.map(\.token))
    }

    /// Verbs grouped by surface, surfaces in declaration order — the shape
    /// the scripting documentation renders.
    public static func grouped() -> [(surface: Surface, verbs: [ScriptVerb])] {
        Surface.allCases.compactMap { surface in
            let verbs = all.filter { $0.surface == surface }
            return verbs.isEmpty ? nil : (surface, verbs)
        }
    }

    private static let index: [String: ScriptVerb] = {
        var m: [String: ScriptVerb] = [:]
        m.reserveCapacity(all.count)
        for v in all { m[v.token] = v }
        return m
    }()
}
