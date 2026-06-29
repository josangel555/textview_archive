import Foundation
import ViewerCore

// CM6 LSP hover bridge (TSK-1110 SRP slice; TSK-963) — JS posts a hover request,
// we run the LSP `hover` round-trip off-main and reply through the CM6 bridge so
// the editor's `hoverTooltip` resolves. Uses the shared LSP gate/position helpers
// (DocumentModel+LSPShared.swift). Behavior-preserving move out of
// DocumentModel.swift.
extension DocumentModel {

    /// JS posted a hover request. Fire the LSP `hover` round-trip
    /// asynchronously, then reply through the bridge so CM6's
    /// `hoverTooltip` callback resolves. Empty contents → no popover.
    public func respondToEditorHover(
        tabID: UUID, fileURL: URL, request: CMHoverRequest
    ) {
        // Reply with empty if no LSP language is configured — avoids
        // a pointless server roundtrip that would just time out.
        guard lspLanguageConfigured(for: fileURL) else {
            sendEditorHoverResponse(replyId: request.replyId, contents: "")
            return
        }
        // CM6 line is 1-based; LSP wants 0-based. character is
        // UTF-16 code units; the pool converts internally if the
        // server negotiated a different encoding.
        let (lspLine, lspChar) = lspPosition(
            line: request.line, character: request.character)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let hover = try await self.lspPool.hover(
                    fileURL: fileURL, line: lspLine, character: lspChar)
                let text: String = hover.map { h -> String in
                    return h.contents
                } ?? ""
                await MainActor.run {
                    self.sendEditorHoverResponse(
                        replyId: request.replyId, contents: text)
                }
            } catch {
                await MainActor.run {
                    self.sendEditorHoverResponse(
                        replyId: request.replyId, contents: "")
                }
            }
        }
    }

    private func sendEditorHoverResponse(replyId: String, contents: String) {
        // The current editor webview owns the response channel; we
        // route through the registry to avoid wiring an extra
        // per-tab Coordinator handle through to the model.
        guard let webView = CodeMirrorEditorRegistry.shared.current() else {
            return
        }
        let msg = CMOutboundMessage.hoverResponse(
            replyId: replyId, contents: contents, from: 0, to: 0)
        let json = CMBridgeCodec.encodeOutboundJSON(msg)
        webView.evaluateJavaScript("window.cmDispatch(\(json));")
    }
}
