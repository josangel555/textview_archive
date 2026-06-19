import Foundation
import ViewerKit

/// A *focused work mode* — a one-click workspace preset that arranges the
/// sidebar (and a preferred default lens) for a specific activity.
///
/// ## Why
///
/// The app surfaces many sidebar panels (files, git, search, LSP outline,
/// problems, …). The right *subset* depends entirely on what the user is
/// doing right now: writing code wants Files + Outline + Problems; reviewing a
/// diff wants Git + Files; reading docs wants Files + Bookmarks and a rendered
/// lens, nothing else. Manually toggling six rail buttons every time you
/// switch tasks is friction. A focus mode collapses that into one action.
///
/// ## What a mode produces (pure logic, host-testable)
///
/// A mode is purely declarative — it names:
///   * `panels` — the curated set of `SidebarPanelKind` that are RELEVANT to
///     the activity. `panelOverrides()` turns this into a
///     `PanelVisibilityOverrides` snapshot: the relevant panels are forced
///     `.shown`, every other panel is forced `.hidden`. That snapshot is the
///     exact same persisted shape the rail toggles already write, so applying
///     a mode is just "store these overrides" — no new persistence surface.
///   * `preferredMode` — the view lens the activity reads best in (Editor for
///     coding, Source for reading code, Rendered for docs, Diff for review).
///     A caller applies it only when the open file actually supports that lens
///     (`appliedMode(available:)`), degrading to the file's own default
///     otherwise — never desyncing the picker from the pane.
///
/// This is the FOUNDATION slice (TSK-381): the model + its mapping to the
/// existing visibility/lens machinery, fully unit-tested. The UI wiring (a
/// `View → Focus Mode ▸` menu / command-palette entries that call
/// `panelOverrides()` and apply `preferredMode`) is a thin follow-up that
/// reads this enum — no duplicated truth.
public enum FocusWorkMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Writing / editing code: Files tree + symbol Outline + Problems, in the
    /// editable buffer.
    case coding
    /// Reading code without editing: Files + Outline + References, read-only
    /// highlighted Source.
    case codeReading
    /// Reading prose / documentation: Files + Bookmarks, rendered Markdown.
    case docReading
    /// Exploring git history: Git panel + Files, read-only Source.
    case gitHistory
    /// Inspecting a working-tree / commit diff: Git + Files, the Diff lens.
    case gitDiff
    /// Reviewing a change set: Git + Files + Problems, the Diff lens.
    case codeReview

    public var id: String { rawValue }

    /// Human-readable label for the `View → Focus Mode` menu / command palette.
    public var displayName: String {
        switch self {
        case .coding:      return "Coding"
        case .codeReading: return "Code Reading"
        case .docReading:  return "Doc Reading"
        case .gitHistory:  return "Git History"
        case .gitDiff:     return "Git Diff"
        case .codeReview:  return "Code Review"
        }
    }

    /// SF Symbol cue for the menu / palette row.
    public var systemImage: String {
        switch self {
        case .coding:      return "chevron.left.forwardslash.chevron.right"
        case .codeReading: return "text.book.closed"
        case .docReading:  return "doc.richtext"
        case .gitHistory:  return "clock.arrow.circlepath"
        case .gitDiff:     return "plusminus.circle"
        case .codeReview:  return "checklist"
        }
    }

    /// The curated set of sidebar panels RELEVANT to this activity. Everything
    /// *not* listed here is forced hidden by `panelOverrides()`.
    ///
    /// `.files` appears in every mode — the file tree is the spatial anchor
    /// you always want regardless of task. Beyond that the sets are tuned per
    /// activity (see the per-mode docs).
    public var panels: Set<SidebarPanelKind> {
        switch self {
        case .coding:
            // Author code: tree to navigate, Outline to jump within a file,
            // Problems to see diagnostics as you type.
            return [.files, .lspOutline, .lspProblems]
        case .codeReading:
            // Read code: tree + Outline to navigate, References to follow
            // symbol usages. No Problems clutter — you're not editing.
            return [.files, .lspOutline, .lspNavigation]
        case .docReading:
            // Read prose: tree + Bookmarks for marked passages. No code tools.
            return [.files, .bookmarks]
        case .gitHistory:
            // Browse history: the Git panel (graph / commits) beside the tree.
            return [.files, .git]
        case .gitDiff:
            // Inspect a diff: Git panel + tree to pivot between changed files.
            return [.files, .git]
        case .codeReview:
            // Review a change: Git + tree, plus Problems to catch regressions.
            return [.files, .git, .lspProblems]
        }
    }

    /// The view lens the activity reads best in. A caller applies it only when
    /// the open file supports it (see `appliedMode(available:)`).
    public var preferredMode: ViewMode {
        switch self {
        case .coding:      return .editor
        case .codeReading: return .source
        case .docReading:  return .rendered
        case .gitHistory:  return .source
        case .gitDiff:     return .diff
        case .codeReview:  return .diff
        }
    }

    /// Build the `PanelVisibilityOverrides` snapshot that realises this mode:
    /// every panel in `panels` is forced `.shown`, every other panel is forced
    /// `.hidden`. Returns an EXPLICIT override for every known panel (none left
    /// `.auto`) so the result is deterministic regardless of data-presence —
    /// the whole point of a focus mode is that it pins the layout.
    ///
    /// `order` defaults to the full registry so a future panel that's omitted
    /// from a mode's `panels` set is hidden rather than silently left visible.
    public func panelOverrides(
        order: [SidebarPanelKind] = SidebarPanelRegistry.defaultOrder
    ) -> PanelVisibilityOverrides {
        var overrides = PanelVisibilityOverrides()
        let relevant = panels
        for kind in order {
            overrides.set(kind, relevant.contains(kind) ? .shown : .hidden)
        }
        return overrides
    }

    /// Resolve the lens to actually apply for a file whose reachable lenses are
    /// `available` (i.e. `ViewModeOptions.availableModes(...)`). Returns
    /// `preferredMode` when the file supports it, otherwise `nil` so the caller
    /// leaves the file on its own default lens — applying a focus mode must
    /// never push a file into a lens it can't render (e.g. forcing `.diff` on a
    /// plain `.swift` file, or `.rendered` on a non-markdown file).
    public func appliedMode(available: [ViewMode]) -> ViewMode? {
        available.contains(preferredMode) ? preferredMode : nil
    }
}
