import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: Find — menu gating (canFind*, findIsAvailable)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split, slice 6).
// Find-availability decision logic that drives the Find / Find&Replace /
// Find-Next-Prev menu enablement — distinct from the find-bar forwarders
// (DocumentModel+FindBarForwarders.swift). Verbatim move; only public/internal/
// global access (no visibility-widening). The pure `findIsAvailable` decision is
// host-tested.
extension DocumentModel {
    /// Gates Find & Replace (⌥⌘F, TSK-949). Replace is only possible on the
    /// editable CM6 editor surface; the rendered (WKWebView) and source
    /// (read-only NSTextView) views can't replace. The old handler silently
    /// degraded ⌥⌘F to plain Find outside the editor — a surprise; greying
    /// the item makes "replace needs the editor" explicit instead.
    public var canFindAndReplace: Bool {
        tabs.selected != nil && currentViewMode == .editor
    }

    /// Gates ⌘F (TSK-947 / parity B5). Find works in editor, source, and
    /// markdown/mermaid rendered views — but NOT in HTML-rendered mode: the
    /// `HTMLRenderedView` has no find runtime (raw-HTML find is deferred) and
    /// hosts no find bar, so ⌘F there used to flip an INVISIBLE rendered-find
    /// bar. Gating greys the Find menu + makes ⌘F a clean no-op instead.
    public var canFindInPage: Bool {
        Self.findIsAvailable(category: currentCategory, viewMode: currentViewMode,
                             editorExceedsSizeCap: isEditorOverSizeCap)
    }

    /// True only when the editor is showing the over-cap placeholder (TSK-947
    /// second half): a file past `codeMirrorEditorMaxBytes` in editor mode renders
    /// the LargeEditorPlaceholderView (no CodeMirror), so there is no find runtime
    /// for ⌘F to drive.
    var isEditorOverSizeCap: Bool {
        guard currentViewMode == .editor, let tab = tabs.selected,
              case .loaded(let file) = tab.state else { return false }
        return file.byteCount > codeMirrorEditorMaxBytes
    }

    /// Pure decision for [`canFindInPage`] (host-tested): find is available
    /// everywhere EXCEPT (a) an HTML page shown in rendered mode (no find runtime),
    /// and (b) a file past the CM6 size cap in editor mode — the placeholder has
    /// no CodeMirror, so ⌘F has nothing to drive (TSK-947).
    static func findIsAvailable(category: FileCategory?, viewMode: ViewMode,
                                editorExceedsSizeCap: Bool = false) -> Bool {
        if viewMode == .editor && editorExceedsSizeCap { return false }
        return !(category == .html && viewMode == .rendered)
    }
}
