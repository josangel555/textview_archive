import Foundation

/// Host-testable model behind the snippet management UI (TSK-705). The SwiftUI
/// sheet (`SnippetManagerView`) is a thin shell over this: it owns the editing
/// form state, validates input, and applies add / update / delete to the backing
/// `SnippetStore`. Keeping the logic here (not in the View) means the create /
/// edit / delete BEHAVIOUR is covered by host XCTest, with only the rendering
/// left to the VM tier.
///
/// `@MainActor` because `SnippetStore` is main-actor-touched (its `JSONFileStore`
/// write coalescing assumes main-thread mutation) and the UI binds to it.
@MainActor
public final class SnippetManagerModel {

    /// Validation outcome for a candidate snippet. The view surfaces the
    /// `message` inline; `.ok` enables the Save button.
    public enum Validation: Equatable, Sendable {
        case ok
        case emptyName
        case emptyBody
        /// `id` collides with a BUILT-IN snippet that the user isn't editing in
        /// place. Built-ins can be overridden (same id) but not duplicated.
        case duplicateBuiltInID(String)
        /// `id` collides with another USER snippet (not the one being edited).
        case duplicateUserID(String)

        public var isValid: Bool { self == .ok }

        public var message: String? {
            switch self {
            case .ok: return nil
            case .emptyName: return "Name can't be empty."
            case .emptyBody: return "Body can't be empty."
            case .duplicateBuiltInID(let id):
                return "Id \"\(id)\" matches a built-in. Use a different id, or edit the built-in to override it."
            case .duplicateUserID(let id):
                return "Id \"\(id)\" is already used by another snippet."
            }
        }
    }

    private let store: SnippetStore

    public init(store: SnippetStore) {
        self.store = store
    }

    // MARK: - Reads

    /// All snippets (built-ins + user overrides/additions), the merged set the
    /// Insert-Snippet menu shows. Built-ins first, then user additions.
    public var allSnippets: [Snippet] { store.all }

    /// The user-defined snippets only (the rows the manager lets you delete /
    /// edit; built-ins are read-only unless overridden by id).
    public var userSnippets: [Snippet] { store.userDefined() }

    /// True when `id` belongs to a shipped built-in (can be overridden by a user
    /// snippet of the same id, but the built-in row itself is not deletable).
    public func isBuiltIn(_ id: String) -> Bool {
        SnippetLibrary.builtIns.contains { $0.id == id }
    }

    // MARK: - Search / preview / insert (TSK-1461)

    /// Case-insensitive filter over the merged snippet set. Matches against
    /// name, id, AND body (a body match is how you find "that snippet with the
    /// front-matter block" whose name you forgot). Empty / whitespace-only
    /// query returns everything, preserving the merged order (built-ins first).
    public func filtered(query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allSnippets }
        return allSnippets.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    /// The snippet a one-keystroke insert (Return / the Insert button) should
    /// target: the explicitly selected row if it survives the current filter,
    /// else the FIRST filtered match (the type-to-filter → Return flow). Nil
    /// when nothing matches.
    public func insertCandidate(query: String, selectedID: String?) -> Snippet? {
        let matches = filtered(query: query)
        if let selectedID, let sel = matches.first(where: { $0.id == selectedID }) {
            return sel
        }
        return matches.first
    }

    /// What `body` actually inserts into the buffer: the parsed expansion's
    /// plain text (placeholder markup stripped, defaults kept). This is the
    /// manager's preview-pane content — the same `ParsedSnippet.plainText` the
    /// real insert path (`DocumentModel.insertSnippet`) uses, so preview and
    /// insert can't drift.
    public static func previewText(body: String) -> String {
        SnippetExpansion.parse(body).plainText
    }

    /// One-line caption for the preview pane describing the tab-stop walk,
    /// e.g. "2 tab stops + final caret", "1 tab stop", "No tab stops".
    public static func tabStopSummary(body: String) -> String {
        let order = SnippetExpansion.parse(body).tabStopOrder
        let hasFinal = order.contains(0)
        let stops = order.filter { $0 != 0 }.count
        switch (stops, hasFinal) {
        case (0, false): return "No tab stops"
        case (0, true): return "Final caret only"
        case (1, false): return "1 tab stop"
        case (1, true): return "1 tab stop + final caret"
        case (let n, false): return "\(n) tab stops"
        case (let n, true): return "\(n) tab stops + final caret"
        }
    }

    // MARK: - Validation

    /// Validate a candidate snippet. `editingID` is the id of the snippet
    /// currently being edited in place (nil when creating a new one) — its own
    /// id is exempt from the duplicate checks so re-saving an edit isn't a
    /// "duplicate". A user snippet whose id equals a built-in's id is allowed
    /// (it's an intentional override), so the built-in collision only fires when
    /// the user is NOT already overriding that built-in.
    public func validate(
        id: String, name: String, body: String, editingID: String? = nil
    ) -> Validation {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .emptyName }
        guard !body.isEmpty else { return .emptyBody }

        // A user snippet may deliberately OVERRIDE a built-in (same id). That's
        // allowed only when the user is editing/creating THAT override — i.e.
        // there isn't already a different user snippet on the id. So: collide
        // with a built-in id is fine; collide with ANOTHER user snippet is not.
        if trimmedID != editingID,
           userSnippets.contains(where: { $0.id == trimmedID }) {
            return .duplicateUserID(trimmedID)
        }
        return .ok
    }

    // MARK: - Mutations

    /// Add / update a user snippet after validation. Returns the validation
    /// result; on `.ok` the snippet is persisted (replacing any user snippet of
    /// the same id, or overriding a built-in). `id`/`name` are trimmed; `body`
    /// is kept verbatim (leading/trailing whitespace can be meaningful).
    @discardableResult
    public func save(
        id: String, name: String, body: String, editingID: String? = nil
    ) -> Validation {
        let result = validate(id: id, name: name, body: body, editingID: editingID)
        guard result.isValid else { return result }
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An in-place edit that RENAMED the id removes the old user entry so we
        // don't leave a duplicate behind.
        if let editingID, editingID != trimmedID {
            store.remove(id: editingID)
        }
        store.add(Snippet(id: trimmedID, name: trimmedName, body: body))
        return .ok
    }

    /// Delete a user snippet by id. Built-ins can't be deleted (only overridden)
    /// — `remove` no-ops on a built-in id that has no user override. Returns
    /// true when a user entry was actually removed.
    @discardableResult
    public func delete(id: String) -> Bool {
        let had = userSnippets.contains { $0.id == id }
        store.remove(id: id)
        return had
    }
}
