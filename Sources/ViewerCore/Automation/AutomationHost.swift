import Foundation
import ViewerKit

/// Surface the MCP server (and, eventually, App Intents / the
/// `--script` DSL) dispatch through to reach the live view model.
///
/// The protocol lives in ViewerCore so the MCP layer doesn't import
/// AppKit / SwiftUI. The real conformance is `DocumentModel` in
/// ViewerUI; tests use a fake host (see `MCPServerTests`).
///
/// All methods are `@MainActor` because every implementation touches
/// `@Published` state on the SwiftUI model. The MCP server's request
/// loop runs off-main; dispatch hops onto MainActor per request.
@MainActor
public protocol AutomationHost: AnyObject {

    // MARK: Canvas (M2 agent surface — TSK-1368)

    /// The canvas document registry the canvas_* tools address. Defaulted
    /// (below) to a process-shared store so existing hosts/doubles need no
    /// changes; DocumentModel overrides with its own instance.
    var automationCanvasStore: CanvasDocumentStore { get }

    // MARK: Files & tabs

    /// Open `url` in a new tab (or the current blank tab) and return
    /// the resulting tab id. `newTab` mirrors `openInNewTab` vs
    /// `open(url:)` on DocumentModel.
    func automationOpenPath(_ url: URL, newTab: Bool) -> UUID

    /// Select a tab by 1-based index (clamped to bounds) or by id.
    /// Returns true if a selection change occurred.
    @discardableResult
    func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool

    // MARK: View state

    func automationSetViewMode(_ mode: ViewMode)

    /// Scroll the source view to a 1-based line number. Column is
    /// advisory — most implementations only honour line.
    func automationGotoLine(_ line: Int, column: Int?)

    /// Set the absolute zoom multiplier. The caller (`MCPToolCatalog`)
    /// clamps the requested value to `[PreferencesStore.minZoom,
    /// PreferencesStore.maxZoom]` BEFORE handing it here and reports the
    /// applied value back to the client, so a clamp is observable on the
    /// wire. The host applies it verbatim — clamping policy lives in the
    /// catalog (mirroring `open_path`'s path-jail validation), not the
    /// host, so the security/limits model stays reviewable in one place.
    func automationSetZoom(_ zoom: Double)

    // MARK: Find

    /// Run an in-doc find against the currently-selected tab's text.
    /// Returns the matches plus a slice of context (line/column).
    func automationFind(_ query: FindQuery) -> [FindMatch]

    // MARK: Read side

    /// Plain text currently in the selected tab (source view contents
    /// when loaded; empty string for binary/preview/error/empty tabs).
    /// Capped at `AutomationLimits.visibleTextMaxBytes` to defend
    /// against pulling a huge log over the wire.
    func automationVisibleText() -> String

    /// Snapshot the full app state per design §7. JSON-serialisable;
    /// the MCP layer turns it into a `Value` via JSONEncoder.
    func automationCurrentState() -> AutomationState

    // MARK: Bookmarks

    /// Toggle a bookmark on the currently-selected tab. If `line` is
    /// nil, toggles a file-level bookmark.
    func automationToggleBookmark(line: Int?)

    func automationListBookmarks() -> [BookmarkEntry]

    // MARK: Snapshot

    /// Render the main window to PNG bytes. Throws if no window is
    /// available (headless mode without window).
    func automationSnapshotPNG() throws -> Data

    // MARK: Script-verb bus

    /// Dispatch a script-verb LINE (verb + optional arg) through the same
    /// `ScriptVerb.apply` surface the palette / `--script` runner use, returning
    /// whether it was handled. The caller (`MCPToolCatalog.run_verb`) validates
    /// the token against `ScriptVerbCatalog` first; this just runs it.
    func automationRunVerb(_ verbLine: String) -> Bool

    // MARK: Code nav (TSK-1192 — the ASYNC tool lane)

    /// `who_calls`: resolve `symbol` via the live LSP and return its
    /// definition + callers. `nil` = unresolvable (no matching symbol, or
    /// no language server running for the workspace). Async by nature (an
    /// LSP round-trip); the MCP server runs it on its reader thread, never
    /// parked on the main actor.
    func automationWhoCalls(symbol: String) async -> CodeNav.WhoCalls?

    /// `goto_definition` (TSK-1560): the definition location(s) of the symbol
    /// at a POSITION — `line`/`character` are LSP-native 0-based (the catalog
    /// converts from the tool's 1-based inputs). `nil` = no server routed for
    /// the file; an EMPTY result = the server answered "no definition".
    func automationDefinition(file: String, line: Int, character: Int) async -> CodeNav.NavLocations?

    /// `find_references` (TSK-1560): every reference to the symbol at a
    /// position (declaration included). Same conventions as
    /// `automationDefinition`.
    func automationReferences(file: String, line: Int, character: Int) async -> CodeNav.NavLocations?
}

public extension AutomationHost {
    /// Default: this host doesn't support the script-verb bus (minimal test
    /// doubles). The live host (`DocumentModel`) overrides to dispatch through
    /// `ScriptVerb.apply`; a recording test host may override to capture.
    func automationRunVerb(_ verbLine: String) -> Bool { false }

    /// Default: no code-nav backend (test doubles / headless hosts).
    func automationWhoCalls(symbol: String) async -> CodeNav.WhoCalls? { nil }

    /// Default: no position-nav backend (test doubles / headless hosts).
    func automationDefinition(file: String, line: Int, character: Int) async -> CodeNav.NavLocations? { nil }

    /// Default: no position-nav backend (test doubles / headless hosts).
    func automationReferences(file: String, line: Int, character: Int) async -> CodeNav.NavLocations? { nil }
}

// MARK: - Plain DTOs (ViewerCore, no UI types)

/// State payload returned by `current_state`. Codable so the MCP layer
/// can hand it straight to `JSONEncoder`.
public struct AutomationState: Codable, Sendable, Equatable {
    public let tabs: [TabDescriptor]
    public let selectedTabIndex: Int?
    public let viewMode: String
    public let zoom: Double
    public let sidebarRoot: String?
    public let isPalettePresented: Bool
    /// Whether the split-pane view is open — an agent journey-state assertion.
    public let isSplitOpen: Bool
    /// Whether the editor's Vim mode is enabled.
    public let vimModeEnabled: Bool
    /// The live session list (app-level) — lets an agent enumerate sessions to
    /// drive the session-* verbs by id/name instead of a blind 1-based index.
    public let sessions: [SessionDescriptor]

    public init(
        tabs: [TabDescriptor],
        selectedTabIndex: Int?,
        viewMode: String,
        zoom: Double,
        sidebarRoot: String?,
        isPalettePresented: Bool,
        isSplitOpen: Bool = false,
        vimModeEnabled: Bool = false,
        sessions: [SessionDescriptor] = []
    ) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.viewMode = viewMode
        self.zoom = zoom
        self.sidebarRoot = sidebarRoot
        self.isPalettePresented = isPalettePresented
        self.isSplitOpen = isSplitOpen
        self.vimModeEnabled = vimModeEnabled
        self.sessions = sessions
    }

    public struct TabDescriptor: Codable, Sendable, Equatable {
        public let id: String
        public let path: String?
        public let title: String
        public let viewMode: String
        /// Whether this tab has unsaved edits — the primary agent journey assertion.
        public let isDirty: Bool
        public init(id: String, path: String?, title: String, viewMode: String, isDirty: Bool = false) {
            self.id = id; self.path = path; self.title = title; self.viewMode = viewMode
            self.isDirty = isDirty
        }
    }

    /// One live app-level session (the session-tab strip). `isActive` marks the
    /// focused session; `id` round-trips back to the session-* verbs.
    public struct SessionDescriptor: Codable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let isActive: Bool
        public init(id: String, displayName: String, isActive: Bool) {
            self.id = id; self.displayName = displayName; self.isActive = isActive
        }
    }
}

/// Tunable limits used by the MCP layer + AutomationHost implementations.
/// Centralised so the security model (design §8) is reviewable in one
/// place rather than scattered across handlers.
public enum AutomationLimits {
    /// Cap on `visibleText` payload. Design §8 calls for 10 MB; we
    /// pick the same value to match the framing ceiling intent.
    public static let visibleTextMaxBytes: Int = 10 * 1024 * 1024
}


/// Process-shared default canvas store (hosts that don't override share it;
/// the live DocumentModel provides its own).
@MainActor
private let sharedCanvasStore = CanvasDocumentStore()

extension AutomationHost {
    public var automationCanvasStore: CanvasDocumentStore { sharedCanvasStore }
}
