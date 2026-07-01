import Foundation
import PDFKit

/// TSK-1140 (PDF reader find) — a pure text-search CURSOR over a `PDFDocument`:
/// runs `findString` and owns the ordered matches with next/prev/wraparound
/// navigation + an "n/total" summary. Host-testable in isolation (PDFKit's
/// `findString` operates on the document's extracted text, no window/view). The
/// render slice (a FindCoordinator `pdf` bag + the `PDFView` applying
/// `current` via `setCurrentSelection` + a PDF find bar) consumes this — the
/// search/cursor logic lives here so it's guarded by host tests, mirroring how
/// the rendered/source/editor find bags separate logic from their views.
public final class PDFSearcher {
    /// Ordered matches for the last `search`, in document order.
    private(set) var matches: [PDFSelection] = []
    /// 0-based cursor into `matches`; -1 when there are none.
    private(set) var index: Int = -1
    /// The query the current `matches` were produced from ("" when cleared).
    public private(set) var query: String = ""

    public init() {}

    /// Immutable snapshot of the cursor state for the find-bar "n/total" readout.
    public struct State: Equatable, Sendable {
        public let total: Int
        /// 0-based current match, or -1 when there are no matches.
        public let currentIndex: Int
        /// "n/total" (1-based) for the find bar, or "" when empty/no-match.
        public var summary: String { total == 0 ? "" : "\(currentIndex + 1)/\(total)" }
        /// Did the last search find at least one match? (nil when the query is empty.)
        public let matched: Bool?
    }

    public var state: State {
        State(total: matches.count,
              currentIndex: index,
              matched: query.isEmpty ? nil : !matches.isEmpty)
    }

    /// Run a NEW search over `document`. Resets the cursor to the first match (0)
    /// when any are found, else to -1. An empty query clears the search (the
    /// caller then clears the view's selection). Case-insensitive by default.
    @discardableResult
    public func search(_ query: String, in document: PDFDocument,
                       caseSensitive: Bool = false) -> State {
        self.query = query
        guard !query.isEmpty else { matches = []; index = -1; return state }
        var opts: NSString.CompareOptions = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        matches = document.findString(query, withOptions: opts)
        index = matches.isEmpty ? -1 : 0
        return state
    }

    /// Advance to the next match (wrapping past the end). Returns the selection
    /// the view should apply, or nil when there are no matches.
    @discardableResult
    public func next() -> PDFSelection? {
        guard !matches.isEmpty else { return nil }
        index = (index + 1) % matches.count
        return current
    }

    /// Step to the previous match (wrapping before the start).
    @discardableResult
    public func prev() -> PDFSelection? {
        guard !matches.isEmpty else { return nil }
        index = (index - 1 + matches.count) % matches.count
        return current
    }

    /// The selection at the cursor (what the `PDFView` highlights), or nil.
    public var current: PDFSelection? {
        matches.indices.contains(index) ? matches[index] : nil
    }

    /// Drop all state (find bar dismissed / document changed).
    public func clear() { matches = []; index = -1; query = "" }
}
