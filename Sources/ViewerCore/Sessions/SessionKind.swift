import Foundation

/// What kind of project a session represents. Drives a **seed-once**
/// per-kind default shoulder-rail panel layout + initial setup at session
/// creation time (SESSIONS_DESIGN §3, #184).
///
/// SEED-ONCE, NOT a live override: the kind picks the *starting* panel
/// layout when the session is first created. Once created, the user's own
/// layout edits win — re-reading the kind on hydrate never re-imposes the
/// default. This is the difference between "a template" (what this is) and
/// "a constraint" (what it deliberately isn't).
///
/// Persisted additively-optionally as the snapshot's `sessionType` string
/// (`rawValue`). A legacy session with no `sessionType` decodes to `nil`,
/// which behaves exactly like `.project` (the plain default) — downgrade-
/// and forward-safe. An unknown future raw value also maps back to `nil`.
///
/// Pure value type, lives in `ViewerCore` (no SwiftUI / AppKit) so it's
/// host-testable and usable from both the value-level `SessionSnapshot`
/// and the UI-level `SessionState`.
public enum SessionKind: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The default — a plain project folder. Files-first layout.
    case project
    /// A code-review session — git panel forward, problems visible.
    case codeReview
    /// An agent / coding-session session — the Claude timeline forward,
    /// git visible. The "Agent session" kind in the New ▸ Session menu
    /// (TSK-373): geared at watching a coding-agent's work over a repo.
    case agent
    /// A CI/CD session — git + problems, files de-emphasised.
    case cicd
    /// A metrics / dashboard session — recents + search forward.
    case metrics

    public var id: String { rawValue }

    /// Short human-readable label (for the "New Session ▸ Kind"
    /// menu / picker, TSK-373). Kept terse — these end up in 1-line UI.
    public var displayName: String {
        switch self {
        case .project:    return "Project"
        case .codeReview: return "Code Review"
        case .agent:      return "Agent Session"
        case .cicd:       return "CI / CD"
        case .metrics:    return "Metrics"
        }
    }

    /// SF Symbol name for the kind, used by the New Session ▸ Kind menu /
    /// command-palette rows (TSK-373). Pure data so the menu and palette
    /// share one icon source of truth.
    public var symbolName: String {
        switch self {
        case .project:    return "folder"
        case .codeReview: return "checkmark.seal"
        case .agent:      return "sparkles"
        case .cicd:       return "arrow.triangle.2.circlepath"
        case .metrics:    return "chart.bar"
        }
    }

    /// One-line description for the menu/palette subtitle (TSK-373).
    /// Says what panel layout the kind seeds, so the user can pick by
    /// intent rather than guessing.
    public var menuSubtitle: String {
        switch self {
        case .project:    return "Plain folder — files first"
        case .codeReview: return "Git + Problems forward, search handy"
        case .agent:      return "Claude timeline + Git forward"
        case .cicd:       return "Git + Problems, files de-emphasised"
        case .metrics:    return "Recents + Search forward"
        }
    }

    /// The SEED-ONCE default shoulder-rail panel layout for a freshly
    /// created session of this kind. Returned as a `PanelLayoutSnapshot`
    /// so the UI layer can `apply` it to the live `PanelLayoutStore`.
    ///
    /// Pure function of the kind — deterministic, host-testable. Only the
    /// *visibility overrides* differ per kind for now (edges stay on the
    /// v1 default `.left` rail); the structure is here so a future
    /// per-kind rail arrangement is a one-function change.
    public var defaultPanelLayout: PanelLayoutSnapshot {
        // Helper: build an overrides string from explicit show/hide picks.
        func overrides(_ picks: [(SidebarPanelKind, PanelOverride)]) -> String {
            var ov = PanelVisibilityOverrides()
            for (k, s) in picks { ov.set(k, s) }
            return ov.encoded()
        }
        switch self {
        case .project:
            // Plain default (owner request 2026-06-20): open a fresh session
            // with ONLY the Files tool window; every other panel starts closed
            // (was: empty overrides → data-presence heuristic that auto-opened
            // git/etc.). The user opens what they want and it persists.
            return .filesOnly
        case .codeReview:
            // Reviewing a change: git + problems forward, search handy.
            return PanelLayoutSnapshot(
                edges: "",
                overrides: overrides([
                    (.git, .shown),
                    (.lspProblems, .shown),
                    (.searchAnywhere, .shown),
                ]))
        case .agent:
            // Watching a coding agent: the Claude timeline + git forward
            // so the agent's running transcript and its edits are visible.
            return PanelLayoutSnapshot(
                edges: "",
                overrides: overrides([
                    (.claudeTimeline, .shown),
                    (.git, .shown),
                ]))
        case .cicd:
            // Watching a pipeline: git + problems forward, files hidden.
            return PanelLayoutSnapshot(
                edges: "",
                overrides: overrides([
                    (.git, .shown),
                    (.lspProblems, .shown),
                    (.bookmarks, .hidden),
                ]))
        case .metrics:
            // Dashboard-ish: recents + search forward, git de-emphasised.
            return PanelLayoutSnapshot(
                edges: "",
                overrides: overrides([
                    (.recentlyOpened, .shown),
                    (.searchAnywhere, .shown),
                    (.git, .hidden),
                ]))
        }
    }
}

/// Persisted, downgrade-safe snapshot of the shoulder-rail panel layout
/// for one session (#184 scope item 2: per-session panel layout, moved
/// off the GLOBAL UserDefaults).
///
/// Stored as the two comma-joined strings the existing value types
/// already produce (`PanelEdgeAssignment.encoded()` /
/// `PanelVisibilityOverrides.encoded()`) rather than a parallel Codable
/// shape — this reuses their stable, sorted, unknown-token-dropping
/// round-trip for free, so a future-renamed panel kind degrades
/// gracefully instead of crashing an older reader. Both fields are
/// non-optional `String` (empty = "no overrides", the v1 default), but
/// the whole `PanelLayoutSnapshot` is itself additive-optional in
/// `SessionSnapshot`, so a pre-#184 file simply has `panelLayout == nil`.
public struct PanelLayoutSnapshot: Codable, Equatable, Sendable {
    /// `PanelEdgeAssignment.encoded()` form. Empty = all panels on the
    /// default `.left` rail.
    public let edges: String
    /// `PanelVisibilityOverrides.encoded()` form. Empty = no explicit
    /// overrides (pure data-presence heuristic).
    public let overrides: String

    public init(edges: String, overrides: String) {
        self.edges = edges
        self.overrides = overrides
    }

    /// True when this snapshot carries no deviation from the v1 default
    /// (everything on `.left`, no explicit show/hide). A `.project`
    /// session's seed produces this — so we can avoid persisting a
    /// meaningless empty blob.
    public var isDefault: Bool {
        edges.isEmpty && overrides.isEmpty
    }

    /// A layout that shows ONLY the Files tool window — every other panel is
    /// forced `.hidden`. The default a plain new (`.project`) session opens
    /// with (owner request 2026-06-20): a fresh session starts clean with just
    /// the file tree, all other tool windows closed, instead of the
    /// data-presence heuristic that auto-opens git / timeline / problems / etc.
    /// The user opens whatever else they want; their choices then persist with
    /// the session.
    public static var filesOnly: PanelLayoutSnapshot {
        var ov = PanelVisibilityOverrides()
        for k in SidebarPanelRegistry.defaultOrder {
            ov.set(k, k == .files ? .shown : .hidden)
        }
        return PanelLayoutSnapshot(edges: "", overrides: ov.encoded())
    }
}
