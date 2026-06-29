import Foundation
import ViewerCore

// CM6 LSP completion request/response bridge (TSK-1110 SRP slice; TSK-1136/463) —
// JS posts a completion request; we resolve via the `handleCompletionRequest`
// seam (which stays on DocumentModel) and reply through the CM6 bridge so the
// editor's autocomplete source resolves. Behavior-preserving move out of
// DocumentModel.swift.
extension DocumentModel {

    /// JS posted a completion request (TSK-1136). Resolve asynchronously via the
    /// existing `handleCompletionRequest` seam (LSP when a language server is
    /// configured, else the in-file buffer-word fallback) and reply through the
    /// bridge so the CM6 autocomplete source resolves. Empty items → no popup.
    public func respondToEditorCompletion(
        tabID: UUID, fileURL: URL, request: CMHoverRequest
    ) {
        Task { [weak self] in
            guard let self = self else { return }
            let items = await self.handleCompletionRequest(
                tabID: tabID, fileURL: fileURL, request: request)
            await MainActor.run {
                self.sendEditorCompletionResponse(
                    replyId: request.replyId, items: items)
            }
        }
    }

    private func sendEditorCompletionResponse(
        replyId: String, items: [EditorCompletionItem]
    ) {
        guard let webView = CodeMirrorEditorRegistry.shared.current() else { return }
        let cmItems = items.map {
            CMCompletionItem(label: $0.label, detail: $0.detail, insertText: $0.insertText)
        }
        let json = CMBridgeCodec.encodeOutboundJSON(
            .completionResponse(replyId: replyId, items: cmItems))
        webView.evaluateJavaScript("window.cmDispatch(\(json));")
    }
}
