import Foundation
import ViewerCore

// Print / Export-as-PDF model signals (TSK-1110 SRP slice; TSK-638) — the
// representable owns the live WKWebView; these methods only bump the @Published
// nonces / record the outcome (the find-nonce pattern). The nonces and the
// PDFExportRequest/Result structs stay on DocumentModel (extensions can't add
// stored properties). Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Printable = the selected tab currently SHOWS a rendered web page:
    /// markdown/mermaid in rendered mode, or an HTML preview tab. Source/
    /// editor/hex/CSV printing is phase 2 (NSPrintOperation on the text
    /// view), deliberately out of this gate.
    public var canPrintRenderedPage: Bool {
        guard currentURL != nil else { return false }
        let cat = currentCategory
        if cat == .html { return currentViewMode == .rendered }
        return supportsViewModeToggle && currentViewMode == .rendered
    }

    /// `⌘P` — returns false (no-op) when the selected tab isn't a
    /// printable rendered page.
    @discardableResult
    public func printRenderedPage() -> Bool {
        guard canPrintRenderedPage else { return false }
        renderedPrintRequest &+= 1
        return true
    }

    /// `File → Export as PDF…` — returns false when not printable.
    @discardableResult
    public func exportRenderedPDF(to url: URL) -> Bool {
        guard canPrintRenderedPage else { return false }
        let nonce = (renderedPDFExportRequest?.nonce ?? 0) &+ 1
        renderedPDFExportRequest = PDFExportRequest(nonce: nonce, url: url)
        return true
    }

    /// Called by the rendered view after `createPDF` resolves.
    public func recordPDFExportResult(nonce: Int, ok: Bool, message: String) {
        renderedPDFExportResult = PDFExportResult(nonce: nonce, ok: ok, message: message)
        Obs.shared.emit(
            ok ? .info : .warn, "export",
            ok ? "PDF exported" : "PDF export failed",
            fields: ["detail": message])
    }
}
