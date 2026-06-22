import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: Find bar (rendered + source mode) — forwarders to FindCoordinator
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split, slice 3).
// Thin forwarders to `find` (FindCoordinator); verbatim move, behavior identical
// to the pre-split inline definitions. Covered by FindBarTests /
// RenderedFindBarModelTests / DocumentModelTabForwarderTests / FindRepublishInvariantTests.
extension DocumentModel {
    // Rendered mode
    public var isRenderedFindBarPresented: Bool {
        get { find.isRenderedBarPresented }
        set { find.isRenderedBarPresented = newValue }
    }
    public var renderedFindQuery: String {
        get { find.renderedQuery }
        set { find.renderedQuery = newValue }
    }
    public var renderedFindNextRequest: Int {
        get { find.renderedNextRequest }
        set { find.renderedNextRequest = newValue }
    }
    public var renderedFindPrevRequest: Int {
        get { find.renderedPrevRequest }
        set { find.renderedPrevRequest = newValue }
    }
    public var renderedFindCaseSensitive: Bool {
        get { find.renderedCaseSensitive }
        set { find.renderedCaseSensitive = newValue }
    }
    public var renderedFindMatched: Bool? {
        get { find.renderedMatched }
        set { find.renderedMatched = newValue }
    }
    public var renderedFindMatchSummary: String {
        get { find.renderedMatchSummary }
        set { find.renderedMatchSummary = newValue }
    }
    public var renderedFindFocusRequest: Int {
        get { find.renderedFocusRequest }
        set { find.renderedFocusRequest = newValue }
    }

    public func setRenderedFindMatchSummary(_ s: String) {
        find.setRenderedMatchSummary(s)
    }
    public func showRenderedFindBar() { find.showRenderedBar() }
    public func dismissRenderedFindBar() { find.dismissRenderedBar() }
    public func toggleRenderedFindBar() { find.toggleRenderedBar() }

    // Source mode
    public var isSourceFindBarPresented: Bool {
        get { find.isSourceBarPresented }
        set { find.isSourceBarPresented = newValue }
    }
    public var sourceFindQuery: String {
        get { find.sourceQuery }
        set { find.sourceQuery = newValue }
    }
    public var sourceFindCaseSensitive: Bool {
        get { find.sourceCaseSensitive }
        set { find.sourceCaseSensitive = newValue }
    }
    public var sourceFindIsRegex: Bool {
        get { find.sourceIsRegex }
        set { find.sourceIsRegex = newValue }
    }
    public var sourceFindNextRequest: Int {
        get { find.sourceNextRequest }
        set { find.sourceNextRequest = newValue }
    }
    public var sourceFindPrevRequest: Int {
        get { find.sourcePrevRequest }
        set { find.sourcePrevRequest = newValue }
    }
    public var sourceFindFocusRequest: Int {
        get { find.sourceFocusRequest }
        set { find.sourceFocusRequest = newValue }
    }
}
