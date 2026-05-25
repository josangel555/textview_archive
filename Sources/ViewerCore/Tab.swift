import Foundation
import ViewerKit

public struct Tab: Sendable, Identifiable {
    public let id: UUID
    public var url: URL?
    public var state: DocumentState
    public var viewMode: ViewMode
    /// True when the editor buffer for this tab has unsaved changes.
    /// Mirrored from `DocumentModel.editorBuffer(forTabID:).isDirty`
    /// so the TabBar can read it via the cheap, Equatable `Tab`
    /// snapshot rather than reaching into the model on every diff.
    /// Updated by `DocumentModel.updateEditorText` and cleared by
    /// `saveActiveEditor`.
    public var isDirty: Bool

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        state: DocumentState = .empty,
        viewMode: ViewMode = .rendered,
        isDirty: Bool = false
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.viewMode = viewMode
        self.isDirty = isDirty
    }

    /// What to display in the tab strip.
    public var title: String {
        switch state {
        case .loaded(let f):      return f.url.lastPathComponent
        case .binary(let b):      return b.url.lastPathComponent
        case .error(let f):       return f.url.lastPathComponent
        case .preview(let u, _):  return u.lastPathComponent
        case .loading(let u):     return u.lastPathComponent
        case .empty:              return url?.lastPathComponent ?? "Untitled"
        }
    }

    /// True when this tab has never been pointed at a file.
    public var isBlank: Bool {
        if url == nil, case .empty = state { return true }
        return false
    }
}

/// Equatable on identity + cheap discriminators only — explicitly NOT
/// on `state` (which contains `TextFile.contents`, a full file String).
/// Synthesized Equatable would O(N) compare every open file's bytes
/// on every SwiftUI `ForEach` diff over `tabs`. Identity-based equality
/// is what SwiftUI actually needs for diffing — content equality
/// matters only when something explicitly compares two `Tab`s
/// expecting deep semantic equality, which nothing does.
extension Tab: Equatable {
    public static func == (lhs: Tab, rhs: Tab) -> Bool {
        guard lhs.id == rhs.id else { return false }
        guard lhs.url == rhs.url else { return false }
        guard lhs.viewMode == rhs.viewMode else { return false }
        guard lhs.isDirty == rhs.isDirty else { return false }
        // Compare state by case-only, not by payload. Payload changes
        // are reflected by other model state (e.g. loadState, watcher
        // reload nonce); state-payload-equality isn't a property
        // anything in the app actually requires.
        switch (lhs.state, rhs.state) {
        case (.empty, .empty),
             (.loaded, .loaded),
             (.binary, .binary),
             (.error, .error):
            return true
        case (.loading(let lu), .loading(let ru)):
            // S3-D: explicit case so two adjacent .loading tabs with
            // the same URL compare equal. Without this they fell into
            // `default → false` and SwiftUI did redundant diff work
            // on every tick.
            return lu == ru
        case (.preview(let lu, let lc), .preview(let ru, let rc)):
            return lu == ru && lc == rc
        default:
            return false
        }
    }
}
