import Foundation
import Combine
import ViewerCore

/// Observable wrapper around `DocumentController`. Lives on the main actor.
@MainActor
public final class DocumentModel: ObservableObject {
    @Published public private(set) var state: DocumentState = .empty
    @Published public private(set) var windowTitle: String = "MarkdownViewer"

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
}
