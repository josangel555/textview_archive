import Foundation

/// How a file is currently being displayed. The set of available
/// modes varies by file type; the always-on baseline is `source`
/// + `hex`, with `rendered` and `formatted` opt-in for files that
/// support them.
public enum ViewMode: String, Equatable, Sendable, CaseIterable, Codable {
    case rendered    // markdown only: WKWebView-rendered HTML
    case source      // every text file: NSTextView with syntax highlight
    case editor      // text files: editable NSTextView (in-memory buffer until ⌘S)
    case formatted   // JSON / XML / etc.: pretty-printed source
    case table       // csv / tsv: column-major grid
    case diff        // .diff / .patch: per-hunk colored DiffView
    case preview     // image/audio/video/pdf/sqlite: native MediaPreviewView (state-driven)
    case hex         // every file: byte grid

    /// True only for the modes backed by a live text caret (an editable /
    /// selectable NSTextView): `.source` and `.editor`. Every other lens —
    /// `.rendered` (WKWebView), `.preview`, `.hex`, `.formatted`, `.table`,
    /// `.diff` — has no caret, so a "Ln X, Col Y" readout is meaningless
    /// there and the status bar must hide it. The `SourceSelection` channel
    /// keeps its last/seed value across a mode toggle (seed is line:1,col:1),
    /// so the chip can't be gated on the selection alone — it has to be
    /// gated on the mode.
    public var hasTextCaret: Bool {
        switch self {
        case .source, .editor: return true
        case .rendered, .formatted, .table, .diff, .preview, .hex: return false
        }
    }
}

/// Computes which view modes are reachable for a given URL. Always
/// includes `.source` + `.hex`. Adds `.rendered` for markdown and
/// `.formatted` when the URL has a registered pretty-printer.
public enum ViewModeOptions {
    /// Available view modes for `url`. `forcedCategory` (WAVE 2b item 6 —
    /// "Open As…") overrides the extension/UTI detection so the picker
    /// offers the modes for the chosen viewer instead of the auto-detected
    /// one (e.g. a `.db` opened as Source gets Source + HEX; opened as
    /// CSV gets Table + Source + HEX).
    public static func availableModes(
        for url: URL?, forcedCategory: FileCategory? = nil,
        isRenderableText: Bool? = nil
    ) -> [ViewMode] {
        guard let url else { return [.source, .hex] }
        // Native-preview categories (image/audio/video/pdf/sqlite) render via
        // the `.preview` document state. Their PRIMARY mode is the first-class
        // `.preview` lens (native MediaPreviewView); HEX stays available as the
        // raw-bytes secondary lens. `.binary` / `.unknown` have no native
        // preview (they'd hit UnsupportedPreview), so they stay HEX-only —
        // UNLESS the content-sniff hint (TSK-332) reports the bytes decoded as
        // renderable text, in which case the no-native-preview HEX-only set is
        // upgraded to `[.source, .hex]` so the unknown-extension text file is
        // actually inspectable as Source (and `defaultMode`'s matching `.source`
        // upgrade has a mode to land on — they MUST stay in sync or the picker
        // selects a mode absent from `availableModes`). A native preview always
        // wins over the hint (an image is never "renderable text").
        if let forced = forcedCategory, !hasTextRepresentation(forced) {
            if hasNativePreview(forced) { return [.preview, .hex] }
            return isRenderableText == true ? [.source, .hex] : [.hex]
        }
        let cat = forcedCategory ?? FileTypeDetector.category(for: url)
        if !hasTextRepresentation(cat) {
            if hasNativePreview(cat) { return [.preview, .hex] }
            return isRenderableText == true ? [.source, .hex] : [.hex]
        }
        // Past the early returns above, `cat` always has a text
        // representation (binary/unknown/native-preview already returned).
        // Seed Source as the text baseline.
        var modes: [ViewMode] = [.source]
        if cat == .markdown || cat == .mermaid { modes.insert(.rendered, at: 0) }
        // .html gets a Rendered mode too — through the SEPARATE,
        // sanitized + JS-default-deny HTMLRenderedView path (NOT the
        // markdown WebView). Inserted AFTER .source (not at the front
        // like markdown): the conservative default for untrusted HTML
        // stays Source (see `defaultMode`), and Rendered is an explicit
        // opt-in mode. The later `.editor` insert also lands after
        // .source, so the final picker reads Source | Editor | Rendered |
        // … — what matters is Source is first/default, Rendered is not.
        if cat == .html {
            if let sourceIdx = modes.firstIndex(of: .source) {
                modes.insert(.rendered, at: sourceIdx + 1)
            } else {
                modes.insert(.rendered, at: 0)
            }
        }
        // With an explicit text override the user is inspecting the file
        // through a chosen lens, so offer the structured modes (Table for
        // CSV-style, Formatted for JSON/XML-style) regardless of the
        // file's real extension. Without an override we keep the
        // extension-driven gating (only true CSV/JSON get these).
        let isTextOverride = forcedCategory.map { hasTextRepresentation($0) } ?? false
        if Self.supportsFormatting(url) || isTextOverride { modes.append(.formatted) }
        if Self.supportsTable(url) || isTextOverride { modes.insert(.table, at: 0) }
        // .diff / .patch files get the dedicated DiffView as default,
        // with `.source` still available for raw-text inspection.
        if Self.supportsDiff(url) { modes.insert(.diff, at: 0) }
        // Editor mode — editable plain-text buffer. Available for any
        // file we'd otherwise show as text; excluded for image / audio
        // / video / pdf / sqlite (which never have a text view to edit)
        // and for `.diff` files (editing a unified-diff representation
        // would silently desync from the actual repo state).
        if Self.supportsEditor(url) || isTextOverride {
            // Slot right after `.source` so the picker reads
            // Source | Editor | Formatted | … from left to right.
            if let sourceIdx = modes.firstIndex(of: .source) {
                modes.insert(.editor, at: sourceIdx + 1)
            } else {
                modes.append(.editor)
            }
        }
        modes.append(.hex)
        return modes
    }

    /// True for files where `.table` is a sensible default. We
    /// preselect Table mode for CSV/TSV by inserting it at the
    /// front of the picker. `forcedCategory` (WAVE 2b item 6) overrides
    /// detection so an "Open As…" tab opens straight into the chosen
    /// viewer's natural default mode.
    ///
    /// `isRenderableText` is an optional content-sniff hint (TSK-332): when
    /// the extension/UTI gives no text identity (a binary/`.unknown`
    /// HEX-default) but the loader has sniffed the bytes and found them to be
    /// renderable text, passing `true` resolves the default to `.source`
    /// instead of `.hex` — so an unknown-extension text file opens into a
    /// usable source view rather than the byte grid. The hint is strictly
    /// additive: it only ever upgrades the HEX default, never overrides a
    /// native-preview (`.preview`) or an extension-driven text default. When
    /// the hint is absent (`nil`) or `false`, behavior is unchanged, so true
    /// binary / unknown-non-text files still default to HEX.
    public static func defaultMode(
        for url: URL?, forcedCategory: FileCategory? = nil,
        isRenderableText: Bool? = nil,
        preferred: [FileCategory: ViewMode] = [:]
    ) -> ViewMode {
        let builtin = builtinDefaultMode(
            for: url, forcedCategory: forcedCategory, isRenderableText: isRenderableText)
        // TSK-671 — per-file-category default override. The user can pin a
        // category to a non-built-in default (e.g. always open Markdown as
        // Source instead of Rendered, CSV as Source instead of Table). Honored
        // ONLY when the pinned mode is in this file's `availableModes`: a stale
        // or cross-type pref (e.g. `.table` pinned on `.plainText`, hit by a
        // `.txt` with no Table mode) degrades to the built-in default rather
        // than desyncing the picker from the pane. Applies to FRESH opens; an
        // already-open tab keeps its mode.
        guard let url, !preferred.isEmpty else { return builtin }
        let cat = forcedCategory ?? FileTypeDetector.category(for: url)
        guard let pinned = preferred[cat], pinned != builtin else { return builtin }
        let avail = availableModes(
            for: url, forcedCategory: forcedCategory, isRenderableText: isRenderableText)
        return avail.contains(pinned) ? pinned : builtin
    }

    /// The built-in (extension/category-derived) default mode, before any user
    /// per-category override (TSK-671). Kept separate so `defaultMode` layers
    /// the override on top while this stays the pure baseline.
    private static func builtinDefaultMode(
        for url: URL?, forcedCategory: FileCategory? = nil,
        isRenderableText: Bool? = nil
    ) -> ViewMode {
        guard let url else { return .source }
        if let forced = forcedCategory {
            // Native-preview categories render through `.preview` and default
            // to the first-class Preview lens; binary/unknown default to HEX.
            if !hasTextRepresentation(forced) {
                if hasNativePreview(forced) { return .preview }
                return isRenderableText == true ? .source : .hex
            }
            if forced == .markdown || forced == .mermaid { return .rendered }
            return .source
        }
        if Self.supportsDiff(url) { return .diff }
        if Self.supportsTable(url) { return .table }
        let cat = FileTypeDetector.category(for: url)
        if cat == .markdown || cat == .mermaid { return .rendered }
        // Native-preview categories default to the Preview lens (native
        // MediaPreviewView). Binary / unknown have no native preview, so they
        // default straight into HEX (bug3) — opening into a usable view rather
        // than a now-unavailable Source — UNLESS the content-sniff hint
        // (TSK-332) says the bytes are renderable text, in which case the
        // unknown-extension-but-text file resolves to `.source`.
        if !hasTextRepresentation(cat) {
            if hasNativePreview(cat) { return .preview }
            return isRenderableText == true ? .source : .hex
        }
        return .source
    }

    /// True for categories that have a real plain-text / source rendering.
    /// `.binary` and `.unknown` do not — the loader rejects them as binary
    /// and the content switch shows them in HexView. The preview-only media
    /// categories (image/audio/video/pdf/sqlite) also have no text view; they
    /// render via the `.preview` document state, not a Source ViewMode.
    static func hasTextRepresentation(_ cat: FileCategory) -> Bool {
        switch cat {
        case .markdown, .mermaid, .plainText, .code, .html:
            return true
        case .image, .audio, .video, .pdf, .sqlite, .archive, .binary, .unknown:
            return false
        }
    }

    /// True for categories that have a first-class native preview rendered
    /// through the `.preview` document state (`MediaPreviewView`). These get a
    /// `.preview` ViewMode as their primary/default lens. `.binary` / `.unknown`
    /// have NO native preview — they'd hit `UnsupportedPreview` — so they are
    /// HEX-only and never offer `.preview`.
    static func hasNativePreview(_ cat: FileCategory) -> Bool {
        switch cat {
        case .image, .audio, .video, .pdf, .sqlite, .archive:
            return true
        case .markdown, .mermaid, .plainText, .code, .html, .binary, .unknown:
            return false
        }
    }

    // NOTE: `.svg` is deliberately NOT here. `FileTypeDetector.category`
    // classifies `.svg` as `.image`, so `availableModes` returns early on
    // the `!hasTextRepresentation` path (`[.preview, .hex]`) and never
    // reaches `supportsFormatting()`. Listing "svg" here was dead config
    // for the normal path while leaking a contradictory third identity for
    // SVG (image vs. xml-source vs. xml-formatter). SVG commits to
    // image/preview. An explicit "Open As… text" override still surfaces
    // the structured modes via `isTextOverride`, and source highlighting on
    // that path correctly resolves to XML via `HighlightLanguage`.
    private static let formatterExtensions: Set<String> = [
        "json", "jsonl", "xml", "plist", "xib", "storyboard",
        "html", "htm", "xhtml"
    ]

    private static let tableExtensions: Set<String> = [
        "csv", "tsv"
    ]

    private static let diffExtensions: Set<String> = [
        "diff", "patch"
    ]

    private static func supportsFormatting(_ url: URL) -> Bool {
        formatterExtensions.contains(url.pathExtension.lowercased())
    }

    private static func supportsTable(_ url: URL) -> Bool {
        tableExtensions.contains(url.pathExtension.lowercased())
    }

    private static func supportsDiff(_ url: URL) -> Bool {
        diffExtensions.contains(url.pathExtension.lowercased())
    }

    /// Editor (in-memory writable buffer) is offered for any file we
    /// classify as text-shaped. Binary categories (image / audio /
    /// video / pdf / sqlite) plus the diff-renderer category are
    /// excluded — the user would be editing a derived representation
    /// or a non-text payload.
    public static func supportsEditor(_ url: URL) -> Bool {
        if supportsDiff(url) { return false }
        return hasTextRepresentation(FileTypeDetector.category(for: url))
    }
}
