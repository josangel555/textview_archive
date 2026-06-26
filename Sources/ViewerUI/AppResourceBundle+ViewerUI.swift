import Foundation
import ViewerCore

public extension Bundle {
    /// ViewerUI's resource bundle (CodeMirror, mermaid, `markdown.css`),
    /// resolved for the packaged app first via ViewerCore's
    /// `resolveResourceBundle(named:fallback:)`. Falls back to ViewerUI's own
    /// `Bundle.module` under `swift test` / `swift run`. (TSK-1257)
    static let viewerUIResources: Bundle =
        resolveResourceBundle(named: "MarkdownViewer_ViewerUI", fallback: .module)
}
