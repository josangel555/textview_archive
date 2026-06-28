import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: Pretty-print / Format — language detection + format-toggle forwarders
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split,
// continuing the slice-2 extraction). Effective-language resolution
// (override-vs-autodetect, with a shebang fallback for extensionless files,
// TSK-901) plus the pretty-print/format toggle. The override + format state
// live on `tabCoordinator`; these forward to it (and read the shared
// `Self.loadedText` content helper, which the split widened from private to
// internal). Verbatim move — behavior is identical to the pre-split inline
// definitions.
extension DocumentModel {

    /// Effective language for a given tab — override wins over
    /// auto-detection. Public so the ModeBar dropdown + the source
    /// view both read the same source of truth. Forwards to
    /// `tabCoordinator` for the override; auto-detect lives here
    /// (URL-based, no coordinator coupling required).
    public func effectiveLanguage(forTabID id: UUID, url: URL) -> HighlightLanguage {
        var auto = HighlightLanguage.detect(from: url)
        // TSK-901: an uninformative extension (extensionless / misnamed script)
        // yields .plainText → no highlighting. Fall back to the content's shebang
        // line if it names a known interpreter. Scanned ONLY when the extension
        // can't classify the file, so files with known extensions pay nothing.
        if auto == .plainText,
           let tab = tabs.tabs.first(where: { $0.id == id }),
           let text = editor.editorBuffer(forTabID: id)?.text ?? Self.loadedText(of: tab),
           let lang = HighlightLanguage.detect(fromShebang: text) {
            auto = lang
        }
        return tabCoordinator.effectiveLanguage(forTabID: id, autodetected: auto)
    }

    /// The effective highlight language of the current tab — the manual
    /// override if one is set, else auto-detected from the URL. `nil` when no
    /// file tab is open. Drives the Language Mode menu's checkmark (TSK-753).
    public var currentEffectiveLanguage: HighlightLanguage? {
        guard let url = tabs.selected?.url, let id = tabs.selected?.id else { return nil }
        return effectiveLanguage(forTabID: id, url: url)
    }

    /// Set or clear the override for the current tab. Passing the
    /// auto-detected language clears the override (so a follow-up
    /// rename still does the right thing).
    public func setCurrentLanguage(_ lang: HighlightLanguage) {
        guard let url = tabs.selected?.url else { return }
        let auto = HighlightLanguage.detect(from: url)
        tabCoordinator.setSelectedTabLanguage(lang, autodetected: auto)
    }

    /// True if a manual override is set for the current tab.
    public var hasLanguageOverride: Bool {
        tabCoordinator.hasLanguageOverrideForSelected
    }

    /// True if the current tab's file is a format that can be pretty-
    /// printed (JSON / XML / HTML / SVG / .plist / .xib / .storyboard).
    public var supportsFormatToggle: Bool {
        guard let url = currentURL else { return false }
        return Formatter.SupportedFormat.detect(url) != nil
    }

    /// Dynamic title for the "Pretty-Print" View-menu item (TSK-904
    /// discoverability). When a formattable file is active it names the
    /// concrete format — `"Pretty-Print JSON"`, `"Pretty-Print XML"` — so
    /// a user scanning menus for "JSON" finds it; otherwise it falls back
    /// to the bare `"Pretty-Print"`. Pure derivation of `currentURL`, so
    /// it's host-testable; `validateMenuItem` assigns it each time the
    /// menu opens.
    public var formatToggleMenuTitle: String {
        guard let url = currentURL,
              let format = Formatter.SupportedFormat.detect(url)
        else { return "Pretty-Print" }
        return "Pretty-Print \(format.displayName)"
    }

    /// True if the current tab is currently showing pretty-printed
    /// content (as opposed to the raw file).
    public var isCurrentTabFormatted: Bool {
        tabCoordinator.isSelectedTabFormatted
    }

    public func toggleFormat() {
        guard supportsFormatToggle else { return }
        tabCoordinator.toggleFormatForSelected()
    }
}
