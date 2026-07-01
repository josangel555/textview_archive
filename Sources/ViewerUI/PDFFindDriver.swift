import Foundation
import PDFKit

/// TSK-1140 — the imperative half of PDF find: reconciles the `pdf` FindCoordinator
/// bag (query / case / next-prev nonces) against a live `PDFView`, running
/// `PDFSearcher` and applying the current match as the view's selection. Extracted
/// from `PDFPreview.updateNSView` so the search→selection logic is the ACTUAL code a
/// host test drives (a `PDFView`'s selection state is testable without a window; the
/// on-screen highlight is PDFView's native rendering of `currentSelection`).
@MainActor
final class PDFFindDriver {
    let searcher = PDFSearcher()
    private var lastQuery: String? = nil   // nil = not yet searched (forces first sync)
    private var lastCaseSensitive = false
    private var lastNext = 0
    private var lastPrev = 0

    /// Call when the PDFView's document changes so the next `sync` re-runs the search.
    func resetForNewDocument() { lastQuery = nil }

    /// Reconcile the find inputs against `pdfView` and apply the resulting match as
    /// the view's current selection. Returns the new search state when anything
    /// changed (query/case edit, or a next/prev nonce bump), else nil — the caller
    /// reports the summary back to the find bar. No-op without a document.
    @discardableResult
    func sync(query: String, caseSensitive: Bool, nextNonce: Int, prevNonce: Int,
              in pdfView: PDFView) -> PDFSearcher.State? {
        guard let doc = pdfView.document else { return nil }
        var changed: PDFSearcher.State? = nil

        if lastQuery != query || lastCaseSensitive != caseSensitive {
            lastQuery = query
            lastCaseSensitive = caseSensitive
            let st = searcher.search(query, in: doc, caseSensitive: caseSensitive)
            apply(searcher.current, to: pdfView)
            changed = st
        }
        if nextNonce != lastNext {
            lastNext = nextNonce
            if let sel = searcher.next() { apply(sel, to: pdfView); changed = searcher.state }
        }
        if prevNonce != lastPrev {
            lastPrev = prevNonce
            if let sel = searcher.prev() { apply(sel, to: pdfView); changed = searcher.state }
        }
        return changed
    }

    private func apply(_ sel: PDFSelection?, to view: PDFView) {
        if let sel {
            view.setCurrentSelection(sel, animate: true)
            view.scrollSelectionToVisible(nil)
        } else {
            view.setCurrentSelection(nil, animate: false)
        }
    }
}
