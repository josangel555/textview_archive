import Foundation

// Source-view scroll-to-line forwarders (TSK-1110 SRP slice) — thin forwarders to
// the SourceViewChannel for scroll-to-1-based-line requests. Behavior-preserving
// move out of DocumentModel.swift.
extension DocumentModel {

    /// Forwarders. Scroll the active source view to this 1-based line number
    /// on the next render. The controller debounces by comparing to its
    /// last-applied target; pair with a bumped `sourceScrollLineNonce` so
    /// re-requesting the same line still fires. Lives on the `sourceView`
    /// narrow channel — see `SourceViewChannel`.
    public var sourceScrollLineTarget: Int? {
        get { sourceView.sourceScrollLineTarget }
        set { sourceView.sourceScrollLineTarget = newValue }
    }
    public var sourceScrollLineNonce: Int {
        get { sourceView.sourceScrollLineNonce }
        set { sourceView.sourceScrollLineNonce = newValue }
    }
    public func scrollSource(toLine line: Int) {
        sourceView.scrollSource(toLine: line)
    }
}
