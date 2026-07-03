import SwiftUI

// TSK-1435 — purposeful empty states for hosted tool views (usability theme #2).
//
// Hosted tool tabs (Feeds, HTTP client, SQLite browser, treemap, script
// console, task runner) used to open with a bare secondary-text placeholder
// ("No feeds") — no what-is-this, no next step. Every hosted surface now draws
// the SAME component from a central, host-tested catalog:
//
//   - `EmptyStateSpec`  — the pure descriptor (icon / title / message /
//     optional action label + help line). Host tests pin completeness so a
//     surface can't silently regress to a blank pane.
//   - `EmptyStateCatalog` — one spec per hosted surface, the single place to
//     word them.
//   - `HostedEmptyStateView` — the SwiftUI rendering (centered icon + title +
//     message + optional action button), accessibility-addressable as
//     `mdv.emptyState.<surface>` (+ `.action` for the button). (Named to
//     avoid the app-landing `EmptyStateView` in ContentView — that one is the
//     "No file open" welcome screen.)
//
// Appearance is the VM/pixel tail (validation protocol rung 3); the host pins
// the catalog + per-surface wiring decisions.

/// Pure descriptor of one surface's empty state. Value-type + Equatable so
/// tests can pin the catalog without a view.
public struct EmptyStateSpec: Equatable, Sendable {
    /// Stable surface key — also the accessibility-identifier suffix
    /// (`mdv.emptyState.<id>`).
    public let id: String
    /// SF Symbol name for the header glyph.
    public let icon: String
    /// One-line "what this is" headline.
    public let title: String
    /// One- or two-sentence next-step guidance.
    public let message: String
    /// Label for the primary action button; nil = no button (the surface's
    /// permanent chrome already carries the action, e.g. the feeds add-bar).
    public let actionLabel: String?

    public init(id: String, icon: String, title: String, message: String,
                actionLabel: String? = nil) {
        self.id = id
        self.icon = icon
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
    }

    /// The component's accessibility identifier for this surface.
    public var accessibilityID: String { "mdv.emptyState.\(id)" }
}

/// The catalog — one spec per hosted surface. Wording lives HERE, not inline
/// in views, so the completeness test (`EmptyStateCatalogTests`) covers every
/// surface and copy edits are one-file diffs.
public enum EmptyStateCatalog {
    public static let feedReader = EmptyStateSpec(
        id: "feedReader",
        icon: "dot.radiowaves.up.forward",
        title: "Feed Reader",
        message: "Follow RSS/Atom feeds and read new items here. Paste a feed URL in the field below and press Add to subscribe.")

    public static let feedReaderItems = EmptyStateSpec(
        id: "feedReader.items",
        icon: "tray",
        title: "No items yet",
        message: "Select a feed on the left, or press Refresh to fetch the latest items.")

    public static let httpClient = EmptyStateSpec(
        id: "httpClient",
        icon: "paperplane",
        title: "HTTP Request",
        message: "Compose a request above — method, URL, headers, body — and press Send. The response (status, timing, headers, body) appears here.")

    public static let sqliteBrowser = EmptyStateSpec(
        id: "sqliteBrowser",
        icon: "tablecells",
        title: "SQLite Browser",
        message: "Click a table in the sidebar to preview its rows, or write a SELECT in the query box and press ⌘↩ to run it.")

    public static let folderTreemap = EmptyStateSpec(
        id: "folderTreemap",
        icon: "square.grid.2x2",
        title: "Folder Size Map",
        message: "This folder contains no measurable files. Open a folder with content to see what's using the space.")

    public static let scriptConsole = EmptyStateSpec(
        id: "scriptConsole",
        icon: "curlybraces",
        title: "Script Console",
        message: "Transform the document with a JavaScript expression — `input` holds the text (or parsed JSON/CSV/lines). Run to preview here, Apply to open the result as a new tab.")

    public static let taskRunner = EmptyStateSpec(
        id: "taskRunner",
        icon: "play.rectangle",
        title: "Task Runner",
        message: "No runnable tasks in this folder. Tasks are discovered from package.json scripts, Cargo.toml targets, and Makefile rules — open a folder with one of those to run tasks here.")

    public static let taskRunnerOutput = EmptyStateSpec(
        id: "taskRunner.output",
        icon: "terminal",
        title: "No output yet",
        message: "Select a task and press Run — its live output streams here.")

    public static let snippetManager = EmptyStateSpec(
        id: "snippetManager",
        icon: "text.badge.plus",
        title: "No snippets",
        message: "Snippets are reusable text blocks with $1/$2 tab stops, inserted from Edit → Insert Snippet or right here. Create your first one.",
        actionLabel: "New Snippet")

    public static let snippetManagerNoMatches = EmptyStateSpec(
        id: "snippetManager.noMatches",
        icon: "magnifyingglass",
        title: "No matching snippets",
        message: "No snippet name, id, or body matches your search.",
        actionLabel: "Clear Search")

    public static let localHistory = EmptyStateSpec(
        id: "localHistory",
        icon: "clock.arrow.circlepath",
        title: "No versions yet",
        message: "Local History records a version of this file each time you save it in the editor. Save once and the timeline starts here.")

    /// Every spec (the completeness-test surface). ADD NEW SPECS HERE.
    public static let all: [EmptyStateSpec] = [
        feedReader, feedReaderItems, httpClient, sqliteBrowser,
        folderTreemap, scriptConsole, taskRunner, taskRunnerOutput,
        snippetManager, snippetManagerNoMatches, localHistory,
    ]
}

/// The shared rendering: centered glyph + headline + guidance (+ optional
/// primary action). Deliberately quiet (secondary styling) — it's guidance,
/// not chrome.
public struct HostedEmptyStateView: View {
    let spec: EmptyStateSpec
    let action: (() -> Void)?

    public init(_ spec: EmptyStateSpec, action: (() -> Void)? = nil) {
        self.spec = spec
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: spec.icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(spec.title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(spec.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let label = spec.actionLabel, let action {
                Button(label, action: action)
                    .padding(.top, 4)
                    .accessibilityIdentifier("\(spec.accessibilityID).action")
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(spec.accessibilityID)
    }
}
