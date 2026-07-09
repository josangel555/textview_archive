import Foundation
import Combine
import ViewerCore

/// TSK-1475 — the terminal-favorites management editor's view-model: the
/// binding layer over the host-tested `TerminalFavoritesStore` (rename /
/// reorder / remove). Favorites previously surfaced only in the command
/// palette; this backs a dedicated editor so the shortlist is curatable.
///
/// Pure state delegation to the store — host-testable with an injected
/// store URL; the SwiftUI editor + its mount point are the render tail.
@MainActor
public final class TerminalFavoritesEditorModel: ObservableObject {

    private let store: TerminalFavoritesStore

    /// Current favorites in stored order (mirror of `store.all`).
    @Published public private(set) var rows: [TerminalFavoritesStore.Favorite] = []
    /// Filter-box text; `visibleRows` applies it.
    @Published public var filterQuery: String = ""

    public init(store: TerminalFavoritesStore) {
        self.store = store
        refresh()
    }

    private func refresh() { rows = store.all }

    public var isEmpty: Bool { rows.isEmpty }

    /// Rows to show — filtered by `filterQuery` (title/command substring via
    /// the store's search), stored order preserved. Blank query → all.
    public var visibleRows: [TerminalFavoritesStore.Favorite] {
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? rows : store.search(q)
    }

    /// Rename a favorite's display title in place (order unchanged).
    @discardableResult
    public func rename(command: String, to title: String) -> Bool {
        let ok = store.rename(command: command, to: title)
        if ok { refresh() }
        return ok
    }

    /// Move a favorite one slot toward the top (clamped at the first).
    @discardableResult
    public func moveUp(command: String) -> Bool {
        guard let idx = rows.firstIndex(where: { $0.command == command }), idx > 0 else {
            return false
        }
        let ok = store.move(command: command, to: idx - 1)
        if ok { refresh() }
        return ok
    }

    /// Move a favorite one slot toward the bottom (clamped at the last).
    @discardableResult
    public func moveDown(command: String) -> Bool {
        guard let idx = rows.firstIndex(where: { $0.command == command }),
              idx < rows.count - 1 else { return false }
        let ok = store.move(command: command, to: idx + 1)
        if ok { refresh() }
        return ok
    }

    /// Remove a favorite.
    @discardableResult
    public func remove(command: String) -> Bool {
        let ok = store.remove(command: command)
        if ok { refresh() }
        return ok
    }
}
