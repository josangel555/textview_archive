import Foundation
import Combine
import ViewerKit
import ViewerCore

/// Observable wrapper around `DocumentController`. Lives on the main actor.
@MainActor
public final class DocumentModel: ObservableObject {
    @Published public private(set) var state: DocumentState = .empty
    @Published public private(set) var windowTitle: String = "MarkdownViewer"
    @Published public var viewMode: ViewMode = .rendered
    @Published public private(set) var recents: [HistoryEntry] = []

    private let controller: DocumentController
    public let history: HistoryStore

    public init(
        controller: DocumentController = DocumentController(),
        history: HistoryStore = HistoryStore(storeURL: HistoryStore.defaultStoreURL())
    ) {
        self.controller = controller
        self.history = history
        self.recents = history.recent()
    }

    public func open(url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        state = controller.open(url: resolved)
        switch state {
        case .loaded(let file):
            windowTitle = file.url.lastPathComponent
            history.record(url: file.url, kind: .file)
            recents = history.recent()
        case .error(let failure):
            windowTitle = failure.url.lastPathComponent
            // Don't record failed opens; user expects "Recent" to mean "things
            // I actually saw."
        case .empty:
            windowTitle = "MarkdownViewer"
        }
    }

    public func clearRecents() {
        history.clear()
        recents = []
    }

    /// Whether the user can toggle Rendered/Source for the current document.
    /// Only meaningful when a markdown file is loaded.
    public var supportsViewModeToggle: Bool {
        if case .loaded(let file) = state {
            return FileTypeDetector.category(for: file.url) == .markdown
        }
        return false
    }

    public func toggleViewMode() {
        viewMode = (viewMode == .rendered) ? .source : .rendered
    }
}
