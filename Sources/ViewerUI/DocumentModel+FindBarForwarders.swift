import Foundation
import Combine
import SwiftUI
import AppKit
import ViewerKit
import ViewerCore

// MARK: Find bar (rendered + source mode) — forwarders to FindCoordinator
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split, slice 3).
// Thin forwarders to `find` (FindCoordinator); verbatim move, behavior identical
// to the pre-split inline definitions. Covered by FindBarTests /
// RenderedFindBarModelTests / DocumentModelTabForwarderTests / FindRepublishInvariantTests.
extension DocumentModel {
    /// TSK-1248: ⌘F must not steal focus from a CONTROL's text field (the sidebar
    /// file-nav filter, a rename/goto prompt, the cross-search field) to open the
    /// document find bar. The window FIELD EDITOR is the canonical "editing a
    /// control" signal. EXCEPTION: a find bar that's already open has its OWN
    /// input as a field editor — ⌘F there must still toggle it closed — so only
    /// defer when NO document find bar is currently open. Pure decision
    /// (host-tested); main.swift passes `NSApp.keyWindow?.firstResponder`.
    @MainActor
    public func shouldDeferFindToFocusedField(_ firstResponder: NSResponder?) -> Bool {
        let anyFindBarOpen = isRenderedFindBarPresented
            || isSourceFindBarPresented
            || isEditorFindBarPresented
            || isPdfFindBarPresented
        return !anyFindBarOpen
            && EscFocusMonitor.firstResponderIsFieldEditor(firstResponder)
    }

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
    /// Find-bar scroll-key forwarding (TSK-1271) — see `FindCoordinator.renderedScroll`.
    public var renderedFindScrollRequest: Int {
        get { find.renderedScrollRequest }
        set { find.renderedScrollRequest = newValue }
    }
    public var renderedFindScrollCommand: FindCoordinator.RenderedScrollCommand {
        find.renderedScrollCommand
    }
    public func renderedFindScroll(_ command: FindCoordinator.RenderedScrollCommand) {
        find.renderedScroll(command)
    }

    public func setRenderedFindMatchSummary(_ s: String) {
        find.setRenderedMatchSummary(s)
    }
    public func showRenderedFindBar() { find.showRenderedBar() }
    public func dismissRenderedFindBar() { find.dismissRenderedBar() }
    public func toggleRenderedFindBar() { find.toggleRenderedBar() }

    // PDF mode (TSK-1140) — the PDFView reader find bar
    public var isPdfFindBarPresented: Bool {
        get { find.isPdfBarPresented }
        set { find.isPdfBarPresented = newValue }
    }
    public var pdfFindQuery: String {
        get { find.pdfQuery }
        set { find.pdfQuery = newValue }
    }
    public var pdfFindNextRequest: Int {
        get { find.pdfNextRequest }
        set { find.pdfNextRequest = newValue }
    }
    public var pdfFindPrevRequest: Int {
        get { find.pdfPrevRequest }
        set { find.pdfPrevRequest = newValue }
    }
    public var pdfFindCaseSensitive: Bool {
        get { find.pdfCaseSensitive }
        set { find.pdfCaseSensitive = newValue }
    }
    public var pdfFindMatchSummary: String {
        get { find.pdfMatchSummary }
        set { find.pdfMatchSummary = newValue }
    }
    public func setPdfFindMatchSummary(_ s: String) { find.setPdfMatchSummary(s) }
    public func showPdfFindBar() { find.showPdfBar() }
    public func dismissPdfFindBar() { find.dismissPdfBar() }
    public func togglePdfFindBar() { find.togglePdfBar() }

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

    // CM6 editor mode
    public var isEditorFindBarPresented: Bool {
        get { find.isEditorBarPresented }
        set { find.isEditorBarPresented = newValue }
    }
    public var editorFindQuery: String {
        get { find.editorQuery }
        set { find.editorQuery = newValue }
    }
    public var editorFindCaseSensitive: Bool {
        get { find.editorCaseSensitive }
        set { find.editorCaseSensitive = newValue }
    }
    public var editorFindIsRegex: Bool {
        get { find.editorIsRegex }
        set { find.editorIsRegex = newValue }
    }
    public var editorFindNextRequest: Int {
        get { find.editorNextRequest }
        set { find.editorNextRequest = newValue }
    }
    public var editorFindPrevRequest: Int {
        get { find.editorPrevRequest }
        set { find.editorPrevRequest = newValue }
    }
    public var editorFindFocusRequest: Int {
        get { find.editorFocusRequest }
        set { find.editorFocusRequest = newValue }
    }
    public var editorFindMatchSummary: String {
        get { find.editorMatchSummary }
        set { find.editorMatchSummary = newValue }
    }
    public var editorFindReplacement: String {
        get { find.editorReplacement }
        set { find.editorReplacement = newValue }
    }
    public var editorReplaceNextRequest: Int {
        get { find.editorReplaceNextRequest }
        set { find.editorReplaceNextRequest = newValue }
    }
    public var editorReplaceAllRequest: Int {
        get { find.editorReplaceAllRequest }
        set { find.editorReplaceAllRequest = newValue }
    }

    public func showEditorFindBar() { find.showEditorBar() }
    public func showEditorReplaceBar() { find.showEditorReplaceBar() }
    public func dismissEditorFindBar() { find.dismissEditorBar() }
    public func toggleEditorFindBar() { find.toggleEditorBar() }
    public func editorFindNext() { find.editorNext() }
    public func editorFindPrev() { find.editorPrev() }
    public func editorReplaceNext() { find.editorReplaceNext() }
    public func editorReplaceAll() { find.editorReplaceAll() }
    public func setEditorFindMatchSummary(_ s: String) {
        find.setEditorMatchSummary(s)
    }

    // Source match-state + cross-bar next/prev
    public var sourceFindMatchSummary: String {
        get { find.sourceMatchSummary }
        set { find.sourceMatchSummary = newValue }
    }
    public var sourceFindMatchLines: [Int] {
        get { find.sourceMatchLines }
        set { find.sourceMatchLines = newValue }
    }
    public var sourceFindCurrentMatchIndex: Int? {
        get { find.sourceCurrentMatchIndex }
        set { find.sourceCurrentMatchIndex = newValue }
    }

    public func setSourceFindMatchSummary(_ s: String) {
        find.setSourceMatchSummary(s)
    }
    public func setSourceFindMatches(lines: [Int], currentIndex: Int?) {
        find.setSourceMatches(lines: lines, currentIndex: currentIndex)
    }

    public func showSourceFindBar() { find.showSourceBar() }
    public func dismissSourceFindBar() { find.dismissSourceBar() }
    public func toggleSourceFindBar() { find.toggleSourceBar() }
    public func sourceFindNext() { find.sourceNext() }
    public func sourceFindPrev() { find.sourcePrev() }
    public func renderedFindNext() { find.renderedNext() }
    public func renderedFindPrev() { find.renderedPrev() }

    /// ⌘G / ⌥⌘G — step the *open* find bar (TSK-946). The previous menu
    /// items targeted `NSTextView.performFindPanelAction` (NSTextFinder),
    /// which is inert here because no surface sets `usesFindBar` — our find
    /// bars are custom. Route to whichever bar is presented instead.
    public func findNext() { find.next() }
    public func findPrev() { find.prev() }
    /// Gates the Find Next/Previous menu items — only meaningful with a bar open.
    public var canFindNextPrev: Bool { find.isAnyBarPresented }
}
