import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Code folding (Fold / Unfold menu actions, TSK-948)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// View → Fold All / Unfold All menu items used to dispatch directly to the CM6
// editor and were greyed unless the tab was in `.editor` mode, so they did
// NOTHING in the read-only `.source` lens — which is itself a foldable lens (its
// gutter draws the same TreeSitter `FoldRegion` chevrons). These entry points
// route the command to the correct surface for the active foldable lens and
// record the dispatch so the wiring is host-testable (the actual collapse
// rendering is the VM tail). The `@Published lastFoldDispatch` state + nonce
// stay on the main class (stored state can't live in an extension); the write
// goes through the vended `recordFoldDispatch`.
extension DocumentModel {
    /// A fold command targeted at the active foldable lens. `target` records
    /// WHICH surface received it (CM6 editor vs the read-only Source view) so a
    /// host test can assert the dispatch decision without a live WebView.
    public enum FoldDispatchTarget: String, Equatable, Sendable {
        case editor   // CM6 WKWebView (`.editor` mode)
        case source   // read-only Source NSTextView (`.source` mode)
    }

    public enum FoldCommand: String, Equatable, Sendable {
        case foldAll
        case unfoldAll
    }

    /// One dispatched fold command. Published as a one-shot record (nonce-
    /// distinct so re-issuing the same command still fires) — the host-
    /// observable proof that a menu action reached the right surface.
    public struct FoldDispatch: Equatable, Sendable {
        public let command: FoldCommand
        public let target: FoldDispatchTarget
        public let nonce: Int
        public init(command: FoldCommand, target: FoldDispatchTarget, nonce: Int) {
            self.command = command
            self.target = target
            self.nonce = nonce
        }
    }

    /// Whether the Fold / Unfold / Fold All / Unfold All menu items should be
    /// ENABLED. True only when a tab is open AND its active lens supports
    /// folding (`.source` / `.editor`); greyed in render / preview / hex /
    /// table / diff / formatted (TSK-948).
    public var canFoldActiveDocument: Bool {
        tabs.selected != nil && currentViewMode.supportsFolding
    }

    /// Fold All in the active foldable lens. No-op (returns false) when the
    /// active lens isn't foldable — the same gate the menu uses, so a
    /// keyboard-shortcut firing in a non-foldable lens is also inert.
    @discardableResult
    public func foldAllActiveDocument() -> Bool { dispatchFold(.foldAll) }

    /// Unfold All in the active foldable lens. No-op outside a foldable lens.
    @discardableResult
    public func unfoldAllActiveDocument() -> Bool { dispatchFold(.unfoldAll) }

    private func dispatchFold(_ command: FoldCommand) -> Bool {
        guard canFoldActiveDocument else { return false }
        let target: FoldDispatchTarget = currentViewMode == .editor ? .editor : .source
        recordFoldDispatch(command, target: target)
        switch target {
        case .editor:
            // CM6 owns the editable buffer's folds — dispatch into the live
            // WKWebView via the registry (the existing, working path).
            if let wv = CodeMirrorEditorRegistry.shared.current() {
                let json = CMBridgeCodec.encodeOutboundJSON(
                    command == .foldAll ? .foldAll : .unfoldAll)
                wv.evaluateJavaScript("window.cmDispatch(\(json));", completionHandler: nil)
            }
        case .source:
            // The read-only Source view collapses via its `FoldState` (the
            // gutter-chevron model). The collapse RENDERING is the VM tail;
            // the published `lastFoldDispatch` is the host-tested intent the
            // Source view subscribes to.
            break
        }
        return true
    }
}
