import ViewerCore
import ViewerKit

/// The shared label vocabulary for file categories and view modes —
/// "Open As…" entries, the status-bar type chip, "Default view for X"
/// menus. One home so every menu spells a lens identically.
///
/// (Rehomed 2026-08-01 from statics on the legacy `ModeBar` view when
/// that dead view was deleted — the labels were the only part of it
/// still alive.)
enum LensLabels {

    /// Human-readable label for an "Open As…" category entry.
    static func categoryLabel(_ cat: FileCategory) -> String {
        switch cat {
        case .markdown:  return "Markdown (rendered)"
        case .mermaid:   return "Mermaid"
        case .plainText: return "Plain Text / CSV"
        case .code:      return "Source / JSON"
        case .html:      return "HTML"
        case .image:     return "Image"
        case .audio:     return "Audio"
        case .video:     return "Video"
        case .pdf:       return "PDF"
        case .sqlite:    return "SQLite"
        case .archive:   return "Archive"
        case .canvas:    return "Canvas (source)"
        case .binary:    return "HEX (raw bytes)"
        case .unknown:   return "Unknown"
        }
    }

    /// Bare type name (no "(rendered)" / "/CSV" qualifiers) — used where the
    /// category is the SUBJECT of a label ("Default view for Markdown"), not an
    /// Open-As lens choice. (TSK-671)
    static func categoryShortLabel(_ cat: FileCategory) -> String {
        switch cat {
        case .markdown:  return "Markdown"
        case .mermaid:   return "Mermaid"
        case .plainText: return "Plain Text"
        case .code:      return "Source code"
        case .html:      return "HTML"
        case .image:     return "Image"
        case .audio:     return "Audio"
        case .video:     return "Video"
        case .pdf:       return "PDF"
        case .sqlite:    return "SQLite"
        case .archive:   return "Archive"
        case .canvas:    return "Canvas"
        case .binary:    return "Binary"
        case .unknown:   return "Unknown"
        }
    }

    /// Short label for a view mode (single word), shared so every menu
    /// uses the exact same wording (TSK-671).
    static func modeLabel(_ mode: ViewMode) -> String {
        switch mode {
        case .rendered:  return "Rendered"
        case .source:    return "Source"
        case .editor:    return "Editor"
        case .formatted: return "Format"
        case .table:     return "Table"
        case .diff:      return "Diff"
        case .preview:   return "Preview"
        case .hex:       return "HEX"
        }
    }
}
