import Foundation

/// Universal Paste — pasteboard type-precedence resolver (TSK-958, builds on
/// TSK-935's text-only paste scratch).
///
/// An `NSPasteboard` almost always advertises MANY representations of the same
/// payload at once: a copied web image carries PNG/TIFF *and* an HTML `<img>`
/// *and* a plain-text URL; a copied spreadsheet range carries HTML (with a
/// `<table>`), TSV, RTF, *and* plain text; a dragged Finder item carries a
/// file-URL *and* a plain-text path. "Paste this somewhere useful" therefore
/// reduces to: given the set of advertised types, which VIEWER KIND best
/// preserves the user's intent?
///
/// This is the pure, host-testable kernel of that decision. It is a function
/// over a list of type identifier STRINGS (UTType raw values / legacy NSPboard
/// names) so it needs no live clipboard — the caller hands it
/// `pasteboard.types?.map(\.rawValue)` (optionally augmented by an HTML-body
/// peek, see `resolve(types:htmlHasTable:)`). The UI/AppKit wiring that reads
/// the pasteboard and routes to the chosen viewer is the separate, VM-gated
/// render layer.
///
/// ## Precedence
/// A higher kind WINS when several coexist, because it carries strictly more
/// structure than the lower ones it subsumes:
///
///   fileURL  >  image  >  table  >  richText  >  plainText
///
/// Rationale, top-down:
/// - **fileURL** — a file reference is an *out-of-band* payload: the bytes live
///   on disk, and the accompanying plain-text path is just a fallback label.
///   Opening the file (not pasting its path string) is the intent.
/// - **image** — PNG/TIFF/etc. is lossy to flatten to anything below it; a
///   coexisting text rep is almost always alt-text / a source URL, not the
///   payload. Pasting the picture beats pasting its URL.
/// - **table** — HTML that actually contains a `<table>`, or a TSV rep, is
///   tabular data; the CSV/table viewer preserves columns that RTF/plain would
///   collapse. (Plain HTML without a table is NOT a table — see below.)
/// - **richText** — RTF or non-table HTML: formatted prose. Beats plain text
///   because styling/links would be lost.
/// - **plainText** — the universal floor; anything Unicode-text-bearing.
public enum PasteDispatch {

    /// The viewer kind a paste should be routed to.
    public enum PasteTarget: String, Equatable, Sendable, CaseIterable {
        case image
        case table
        case richText
        case plainText
        case fileURL
    }

    // MARK: - Type identifier vocabulary

    /// Pasteboard type identifiers we recognise, grouped by the structure they
    /// imply. Both modern UTType raw values (`public.*`, `org.*`) and the legacy
    /// `NSPasteboard.PasteboardType` constants' raw strings are included, since
    /// real pasteboards (and drags from older apps) still advertise the legacy
    /// names. Matching is case-insensitive on the raw string.
    private enum TypeID {
        // File references — highest precedence.
        static let fileURL: Set<String> = [
            "public.file-url",
            "public.url",                       // a URL rep often shadows a file-url
            "NSFilenamesPboardType",            // legacy multi-file drag
            "NSURLPboardType",                  // legacy single URL
            "Apple URL pasteboard type",        // legacy NSURLPboardType raw
            "CorePasteboardFlavorType 0x6675726C", // 'furl'
        ]

        // Raster images.
        static let image: Set<String> = [
            "public.png",
            "public.tiff",
            "public.jpeg",
            "com.compuserve.gif",
            "public.heic",
            "public.heif",
            "com.microsoft.bmp",
            "public.image",                     // generic image conformance
            "NSPasteboardTypePNG",
            "NSPasteboardTypeTIFF",
            "NSTIFFPboardType",                 // legacy TIFF
            "NSPICTPboardType",                 // legacy PICT (still image-ish)
            "Apple PNG pasteboard type",
        ]

        // Tabular reps (TSV — HTML <table> is handled separately via a body peek).
        static let table: Set<String> = [
            "public.tab-separated-values-text",
            "public.comma-separated-values-text",
            "public.utf8-tab-separated-values-text",
            "com.apple.numbers.table",          // Numbers native table flavor
        ]

        // HTML — table-or-prose; the `htmlHasTable` flag disambiguates.
        static let html: Set<String> = [
            "public.html",
            "Apple HTML pasteboard type",
            "NSHTMLPboardType",
        ]

        // Rich text (non-HTML formatting).
        static let richText: Set<String> = [
            "public.rtf",
            "com.apple.flat-rtfd",
            "public.rtfd",
            "NSRTFPboardType",                  // legacy RTF
            "NSRTFDPboardType",                 // legacy RTFD
            "Apple RTF pasteboard type",
            "Apple RTFD pasteboard type",
        ]

        // Plain text — the floor.
        static let plainText: Set<String> = [
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.utf16-plain-text",
            "public.plain-text",
            "public.text",                      // generic text conformance
            "NSStringPboardType",               // legacy plain string
            "NSPasteboardTypeString",
            "Apple HTML pasteboard type ",      // (defensive trailing-space variant)
        ]
    }

    // MARK: - Resolve

    /// Resolve the best `PasteTarget` from the advertised pasteboard type
    /// identifiers, with no insight into the HTML body. Equivalent to
    /// `resolve(types:htmlHasTable: false)` — i.e. HTML is treated as rich text
    /// unless the caller has peeked and found a `<table>`.
    ///
    /// Returns `nil` when no recognised representation is present (an empty or
    /// fully-unknown pasteboard) — the caller should then no-op / fall back.
    public static func resolve(types: [String]) -> PasteTarget? {
        resolve(types: types, htmlHasTable: false)
    }

    /// Resolve the best `PasteTarget`, with an explicit signal for whether the
    /// HTML representation (if any) contains a `<table>`.
    ///
    /// The HTML body is NOT available from the type list alone — distinguishing
    /// "copied a spreadsheet range" (HTML with `<table>` → `.table`) from
    /// "copied a paragraph from a web page" (HTML prose → `.richText`) requires
    /// peeking at the bytes. The caller (the AppKit paste handler) does that
    /// peek and passes the result here, keeping this function pure. When the
    /// caller can't or won't peek, `false` is the safe default (HTML → rich
    /// text, never a phantom table).
    ///
    /// - Parameters:
    ///   - types: pasteboard type identifiers (UTType raw values and/or legacy
    ///     `NSPasteboard.PasteboardType` raw strings). Order is ignored.
    ///   - htmlHasTable: `true` iff an HTML representation is present AND its
    ///     body contains a `<table>` element. Only consulted when an HTML type
    ///     is advertised.
    public static func resolve(types: [String], htmlHasTable: Bool) -> PasteTarget? {
        let normalized = Set(types.map { $0.lowercased() })

        func has(_ ids: Set<String>) -> Bool {
            !normalized.isDisjoint(with: Set(ids.map { $0.lowercased() }))
        }

        // 1. File reference — open the file, don't paste its path.
        if has(TypeID.fileURL) { return .fileURL }

        // 2. Raster image — preserve the pixels.
        if has(TypeID.image) { return .image }

        let hasHTML = has(TypeID.html)

        // 3. Tabular — an explicit TSV/Numbers rep, OR HTML carrying a <table>.
        if has(TypeID.table) || (hasHTML && htmlHasTable) {
            return .table
        }

        // 4. Rich text — RTF/RTFD, or HTML prose (no table).
        if has(TypeID.richText) || hasHTML {
            return .richText
        }

        // 5. Plain text — the floor.
        if has(TypeID.plainText) { return .plainText }

        // Nothing recognised.
        return nil
    }

    /// Convenience overload: detect a `<table>` in a supplied HTML body string
    /// and resolve in one call. The detection is a case-insensitive substring
    /// match for an opening `<table` tag (with or without attributes), which is
    /// deliberately permissive — a false positive merely routes prose-with-a-
    /// table to the table viewer, the more structured target.
    ///
    /// - Parameters:
    ///   - types: pasteboard type identifiers.
    ///   - htmlBody: the decoded HTML representation, or `nil` if none / not read.
    public static func resolve(types: [String], htmlBody: String?) -> PasteTarget? {
        let hasTable = htmlBody.map(htmlContainsTable) ?? false
        return resolve(types: types, htmlHasTable: hasTable)
    }

    /// True when `html` contains an opening `<table` tag (case-insensitive).
    public static func htmlContainsTable(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("<table>") || lower.contains("<table ")
            || lower.contains("<table\t") || lower.contains("<table\n")
            || lower.contains("<table/")
    }
}
