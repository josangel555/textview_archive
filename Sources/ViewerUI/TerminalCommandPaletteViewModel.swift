import Foundation
import ViewerCore

/// TSK-1176 — controller for the Terminal Command Palette (the UI over the host-built
/// command-history + favorites search, TSK-769/1301). A live query filters the unified,
/// favorites-first, de-duplicated command list (`TerminalCommandSearch.unified`); the
/// selection drives keyboard navigation; the chosen command is inserted at the PTY prompt.
///
/// Host-tested model layer; the SwiftUI panel + DocumentModel wiring + trigger + PTY-insert
/// are the render companions (VM-validated like the Script Console, TSK-698).
@MainActor
public final class TerminalCommandPaletteViewModel: ObservableObject {

    /// The live filter query (empty → the full favorites-first list).
    @Published public var query: String = "" { didSet { refresh() } }
    /// Unified results for the current query (favorites first, de-duplicated).
    @Published public private(set) var results: [TerminalCommandSearch.Result] = []
    /// The highlighted row (keyboard navigation; clamped to results).
    @Published public var selectedIndex: Int = 0

    private let favorites: TerminalFavoritesStore
    private let history: TerminalCommandHistory

    public init(favorites: TerminalFavoritesStore, history: TerminalCommandHistory) {
        self.favorites = favorites
        self.history = history
        refresh()
    }

    /// Recompute `results` from the current query, keeping the selection in range.
    public func refresh() {
        results = TerminalCommandSearch.unified(query: query, favorites: favorites, history: history)
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
    }

    /// The command of the highlighted row, or nil if there are no results.
    public var selectedCommand: String? {
        results.indices.contains(selectedIndex) ? results[selectedIndex].command : nil
    }

    /// Move the highlight by `delta` rows, wrapping around the result list.
    public func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }
}
