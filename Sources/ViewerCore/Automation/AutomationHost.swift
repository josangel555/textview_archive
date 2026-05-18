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

    public init(
        tabs: [TabDescriptor],
        selectedTabIndex: Int?,
        viewMode: String,
        zoom: Double,
        sidebarRoot: String?,
        isPalettePresented: Bool
    ) {
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.viewMode = viewMode
        self.zoom = zoom
        self.sidebarRoot = sidebarRoot
        self.isPalettePresented = isPalettePresented
    }

    public struct TabDescriptor: Codable, Sendable, Equatable {
        public let id: String
        public let path: String?
        public let title: String
        public let viewMode: String
        public init(id: String, path: String?, title: String, viewMode: String) {
            self.id = id; self.path = path; self.title = title; self.viewMode = viewMode
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
