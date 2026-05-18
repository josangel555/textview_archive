import Foundation
import SwiftUI
import ViewerCore

/// Walkthrough-specific request-nonce channels grafted onto
/// `DocumentModel` via a side container.
///
/// Why a side container rather than `@Published` props directly on
/// `DocumentModel`: the walkthrough surface is opt-in — the vast
/// majority of sessions never load a script, and we don't want every
/// `ContentView` body re-eval to pay an extra observer hop. Stashing
/// the state on an inner `WalkthroughBridge` keeps a single
/// `@Published` reference on `DocumentModel` (the bridge itself) and
/// scopes redraws to views that observe the bridge.
///
/// All channels here follow the same pattern the rest of the model
/// already uses for cross-actor signalling — a value + a monotonically
/// increasing nonce. Re-issuing the same target (e.g. "highlight
/// lines 10–20 of the same file") still fires because the nonce bumps.
@MainActor
public final class WalkthroughBridge: ObservableObject {

    public init() {}

    // MARK: - Highlight request
    //
    // The TextDisplayView coordinator owns range highlighting today
    // (`FindState`); for walkthrough we route through a separate
    // channel so a step's highlight survives an unrelated find-bar
    // open/close. The view layer reads (url, startLine, endLine,
    // style) and re-renders when `highlightNonce` changes.

    public struct HighlightRange: Equatable, Sendable {
        public let url: URL
        public let startLine: Int        // 1-based
        public let endLine: Int          // 1-based, inclusive
        public let style: HighlightStyle
        public init(
            url: URL, startLine: Int, endLine: Int, style: HighlightStyle
        ) {
            self.url = url
            self.startLine = startLine
            self.endLine = endLine
            self.style = style
        }
    }

    @Published public private(set) var highlight: HighlightRange? = nil
    @Published public private(set) var highlightNonce: Int = 0

    public func requestHighlight(_ range: HighlightRange) {
        highlight = range
        highlightNonce &+= 1
    }

    public func clearHighlight() {
        guard highlight != nil else { return }
        highlight = nil
        highlightNonce &+= 1
    }

    // MARK: - Popover request

    public struct PopoverRequest: Equatable, Sendable {
        public let body: String          // markdown allowed
        public let anchor: PopoverAnchor
        public let style: PopoverTarget
        public init(body: String, anchor: PopoverAnchor, style: PopoverTarget) {
            self.body = body
            self.anchor = anchor
            self.style = style
        }
    }

    @Published public private(set) var popover: PopoverRequest? = nil
    @Published public private(set) var popoverNonce: Int = 0

    public func requestPopover(_ request: PopoverRequest) {
        popover = request
        popoverNonce &+= 1
    }

    public func clearPopover() {
        guard popover != nil else { return }
        popover = nil
        popoverNonce &+= 1
    }

    // MARK: - Note request (Code Review hookup is a follow-up)
    //
    // Per design decision: the per-step Note button is visual-only in
    // v1. Clicking it bumps `noteNonce` and stashes the stepID; a
    // future Code Review integration will subscribe.

    @Published public private(set) var lastNoteStepID: String? = nil
    @Published public private(set) var noteNonce: Int = 0

    public func requestNote(forStepID stepID: String) {
        lastNoteStepID = stepID
        noteNonce &+= 1
    }
}

public extension DocumentModel {

    /// Lazy-attached bridge. Per-process singleton on the model so
    /// `ContentView` can observe it via `@ObservedObject` without
    /// `DocumentModel` paying the publish cost when no walkthrough is
    /// in flight. Held via an associated object to avoid invasive
    /// changes to `DocumentModel`'s stored-property list.
    var walkthroughBridge: WalkthroughBridge {
        if let existing = objc_getAssociatedObject(
            self, &WalkthroughBridgeKey.key
        ) as? WalkthroughBridge {
            return existing
        }
        let bridge = WalkthroughBridge()
        objc_setAssociatedObject(
            self, &WalkthroughBridgeKey.key, bridge,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return bridge
    }

    /// Switch the focused tab to one already showing `url`, if any.
    /// Returns true when a switch happened. Used by the walkthrough
    /// `openFile` handler so an already-open file becomes the active
    /// tab without re-reading from disk.
    func selectTab(forURL url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let idx = tabs.tabs.firstIndex(where: { $0.url == resolved })
        else { return false }
        selectTab(at: idx)
        return true
    }
}

/// Associated-object key. The address of this static var is the key;
/// the contents are unused. Wrapping in an enum (uninstantiable) keeps
/// the global namespace clean.
private enum WalkthroughBridgeKey {
    nonisolated(unsafe) static var key: UInt8 = 0
}
