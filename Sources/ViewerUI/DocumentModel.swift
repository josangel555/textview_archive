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

    private let controller: DocumentController

    public init(controller: DocumentController = DocumentController()) {
        self.controller = controller
    }

    public func open(url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        state = controller.open(url: resolved)
        switch state {
        case .loaded(let file):
            windowTitle = file.url.lastPathComponent
        case .error(let failure):
            windowTitle = failure.url.lastPathComponent
        case .empty:
            windowTitle = "MarkdownViewer"
        }
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
