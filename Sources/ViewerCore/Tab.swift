import Foundation
import ViewerKit

public struct Tab: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var url: URL?
    public var state: DocumentState
    public var viewMode: ViewMode

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        state: DocumentState = .empty,
        viewMode: ViewMode = .rendered
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.viewMode = viewMode
    }

    /// What to display in the tab strip.
    public var title: String {
        switch state {
        case .loaded(let f): return f.url.lastPathComponent
        case .error(let f): return f.url.lastPathComponent
        case .empty:        return url?.lastPathComponent ?? "Untitled"
        }
    }

    /// True when this tab has never been pointed at a file.
    public var isBlank: Bool {
        if url == nil, case .empty = state { return true }
        return false
    }
}
