import Foundation

/// One concrete extension point — the §2.1 "new sidebar section" surface.
/// `SidebarView` reads from `PluginRegistry.shared.sidebarSections` at
/// render time. The registry is `@MainActor` because SwiftUI consumes
/// it on the main actor and we want the host to stay single-actor
/// (no cross-actor hops on every keystroke).
///
/// Data source contract: a Tier A sidebar section is "give me a
/// snapshot of rows for the current host state." For the PoC, the
/// host state is the open document URLs (the bundled `RowCounter`
/// plugin counts lines of each open file). The contract intentionally
/// does NOT expose the model — it takes a pure `Snapshot` parameter
/// so plugins can be unit-tested without spinning up a UI.
@MainActor
public final class SidebarSectionRegistry {
    public struct Snapshot: Sendable {
        public let openFileContents: [URL: String]
        public init(openFileContents: [URL: String]) {
            self.openFileContents = openFileContents
        }
    }

    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let detail: String?
        /// Optional inline action (TSK-375 — the "button/widget" surface).
        /// When non-nil the sidebar renders a button on the row that runs
        /// this closure (on the main actor) when clicked. `nil` ⇒ a plain
        /// text row. Excluded from `Equatable` (closures aren't comparable);
        /// row identity + text drive equality, the action is presence-only.
        public let invoke: (@MainActor () -> Void)?

        public init(
            id: String,
            label: String,
            detail: String?,
            invoke: (@MainActor () -> Void)? = nil
        ) {
            self.id = id; self.label = label; self.detail = detail
            self.invoke = invoke
        }

        /// Whether this row carries a clickable action. Drives the UI's
        /// decision to render a button — host-testable without a closure
        /// comparison.
        public var isActionable: Bool { invoke != nil }

        // Closures are not `Equatable`; compare the value fields and treat
        // the action as a presence flag so existing row-equality tests (which
        // construct rows without an action) keep passing.
        public static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id
                && lhs.label == rhs.label
                && lhs.detail == rhs.detail
                && lhs.isActionable == rhs.isActionable
        }
    }

    public struct Entry {
        public let pluginID: String
        public let sectionID: String
        public let title: String
        public let icon: String?
        public let order: Int
        public let collapsedByDefault: Bool
        /// Pure function: snapshot → rows. No side effects. Must not
        /// throw — Tier A is data. A misbehaving provider returns
        /// `[]` rather than crashing the host (see `safeRows`).
        public let provider: @MainActor (Snapshot) -> [Row]

        public init(
            pluginID: String,
            sectionID: String,
            title: String,
            icon: String?,
            order: Int,
            collapsedByDefault: Bool,
            provider: @escaping @MainActor (Snapshot) -> [Row]
        ) {
            self.pluginID = pluginID
            self.sectionID = sectionID
            self.title = title
            self.icon = icon
            self.order = order
            self.collapsedByDefault = collapsedByDefault
            self.provider = provider
        }
    }

    private var entries: [Entry] = []

    public init() {}

    public var all: [Entry] {
        // Stable order: declared `order` ascending, ties broken by
        // plugin id. Matches §2.1's "order is a hint; ties broken by
        // install order." We approximate install order with id here
        // (PoC); a real impl tracks install timestamps.
        entries.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.pluginID < rhs.pluginID
        }
    }

    public func register(_ entry: Entry) {
        entries.append(entry)
    }

    public func dropAll(forPlugin id: String) {
        entries.removeAll { $0.pluginID == id }
    }

    /// The currently-registered entries contributed by one plugin.
    /// Used by `PluginRegistry.setEnabled` to stash a bundled plugin's
    /// sections before dropping them, so re-enabling can re-register
    /// without re-running the plugin's launch hook (TSK-614).
    public func entries(forPlugin id: String) -> [Entry] {
        entries.filter { $0.pluginID == id }
    }

    /// Calls the provider inside a defensive shell. The PoC's "fail
    /// isolation" for in-process bundled plugins is intentionally
    /// shallow — Swift has no in-process panic boundary, so a
    /// genuinely crashing provider takes the host with it. What we
    /// CAN protect against: providers that throw at the type
    /// boundary (we don't allow throws), runaway providers (caller
    /// timeout, not implemented in v1), and providers that return
    /// garbage (we accept it; rendering is the consumer's problem).
    /// True crash isolation requires Tier B (subprocess) or Tier C
    /// (WKWebView) — see the design-doc gap notes in the report.
    public func safeRows(for entry: Entry, snapshot: Snapshot) -> [Row] {
        // No-op wrapper today. Exists as the single seam where we'd
        // add a wall-clock guard, max-rows cap, or audit log entry
        // when we promote bundled plugins to subprocess plugins.
        return entry.provider(snapshot)
    }
}
