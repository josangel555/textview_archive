import Foundation

/// How a resolved `PasteDispatch.PasteTarget` should be MATERIALIZED into a file
/// the existing viewers can open (TSK-1163, the live-action half of TSK-958).
///
/// `PasteDispatch.resolve` decides *which viewer kind* a clipboard payload wants;
/// this decides *how to turn that payload into an openable file*: which
/// pasteboard representation to read, and what temp-file extension to give it so
/// `DocumentModel.openInNewTab(_:)` routes it to the right viewer by type. Pure +
/// host-testable — the AppKit layer (read the bytes, write the temp file, open)
/// is the thin VM-gated shell over this decision.
public struct UniversalPastePlan: Equatable, Sendable {

    /// Where the openable bytes come from.
    public enum Source: Equatable, Sendable {
        /// Use the pasteboard's file-URL directly — no temp file (the bytes are
        /// already on disk; opening the path, not pasting it, is the intent).
        case fileURL
        /// Read the given pasteboard representation's raw `Data` and write it to
        /// a temp file with `fileExtension`. `fallbackTypes` are tried in order
        /// if the preferred type is absent (e.g. PNG → TIFF for images).
        case data(pasteboardType: String, fallbackTypes: [String], fileExtension: String)
        /// Read the pasteboard's string and write it as UTF-8 to a temp file
        /// with `fileExtension`.
        case string(fileExtension: String)
    }

    public let source: Source
    /// Suggested base filename (no directory) for the materialized temp file. The
    /// AppKit shell may de-collide it; the extension comes from `source`.
    public let suggestedName: String

    public init(source: Source, suggestedName: String) {
        self.source = source
        self.suggestedName = suggestedName
    }

    /// TSK-1479: the human description of the paste OUTCOME, for the
    /// "Pasted as X — Undo" feedback toast. Pure + host-tested per target.
    /// `convertedToMarkdown` covers the TSK-1327 rich-text→Markdown path,
    /// which diverges from the plan (the user should hear what actually
    /// happened, not what the plan would have done).
    public static func humanDescription(
        for target: PasteDispatch.PasteTarget,
        convertedToMarkdown: Bool = false
    ) -> String {
        if convertedToMarkdown { return "Pasted as Markdown" }
        switch target {
        case .fileURL:   return "Opened pasted file"
        case .image:     return "Pasted as image"
        case .table:     return "Pasted as table"
        case .richText:  return "Pasted as rich text"
        case .plainText: return "Pasted as text"
        }
    }

    /// The materialization plan for a resolved paste target.
    public static func plan(for target: PasteDispatch.PasteTarget) -> UniversalPastePlan {
        switch target {
        case .fileURL:
            return UniversalPastePlan(source: .fileURL, suggestedName: "")
        case .image:
            // Prefer lossless PNG; fall back to TIFF (older apps / screenshots).
            return UniversalPastePlan(
                source: .data(pasteboardType: "public.png",
                              fallbackTypes: ["public.tiff", "NSPasteboardTypePNG",
                                              "NSPasteboardTypeTIFF"],
                              fileExtension: "png"),
                suggestedName: "Pasted Image")
        case .table:
            // TSV preserves columns; `.tsv` routes to the CSV/table viewer
            // (its delimiter sniff handles tabs).
            return UniversalPastePlan(
                source: .data(pasteboardType: "public.tab-separated-values-text",
                              fallbackTypes: ["public.utf8-tab-separated-values-text",
                                              "public.comma-separated-values-text"],
                              fileExtension: "tsv"),
                suggestedName: "Pasted Table")
        case .richText:
            return UniversalPastePlan(
                source: .data(pasteboardType: "public.rtf",
                              fallbackTypes: ["NSRTFPboardType", "Apple RTF pasteboard type"],
                              fileExtension: "rtf"),
                suggestedName: "Pasted")
        case .plainText:
            return UniversalPastePlan(
                source: .string(fileExtension: "txt"),
                suggestedName: "Pasted")
        }
    }
}
