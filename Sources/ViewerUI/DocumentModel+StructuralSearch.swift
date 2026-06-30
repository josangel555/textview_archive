import Foundation
import ViewerCore
import ViewerKit

/// TSK-1161 — the Structural Search panel's DocumentModel wiring: open the panel seeded from
/// the active buffer's content + language. The @Published flag + view-model live on
/// DocumentModel (stored props can't be in an extension); this is the open method. The
/// presentation (.sheet) + menu trigger are the view-side companions; this is host-testable.
extension DocumentModel {

    /// Open the Structural Search panel, seeded with the active buffer's live content and its
    /// effective syntax language (so node-kind queries resolve against the right grammar).
    public func openStructuralSearch() {
        let tab = tabs.selected
        let content: String
        if let id = tab?.id, let text = editorBuffer(forTabID: id)?.text {
            content = text
        } else if let url = tab?.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            content = text
        } else {
            content = ""
        }
        structuralSearchVM = StructuralSearchViewModel(
            inputText: content,
            language: currentEffectiveLanguage ?? .plainText)
        showStructuralSearch = true
    }
}
