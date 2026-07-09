import Foundation
import ViewerKit

/// TSK-1319 — the PURE model behind the dynamic, content-specific menu: given the
/// visible tab's `FileCategory`, the set of content-relevant actions (title +
/// script-verb token) a dedicated menu should offer. These are CANDIDATES — the
/// live menu additionally filters by runtime capability (e.g. only show the CSV
/// converters when the active file actually parses as CSV) and the verbs
/// self-gate, so an offered-but-inapplicable action is a safe no-op. Host-testable
/// (the mapping + verb-token validity); the dynamic NSMenu build + per-tab-switch
/// rebuild are the AppKit/render tail.
public enum ContentActionMenu {

    /// One content-specific menu action: a human title + the `ScriptVerbCatalog`
    /// token it dispatches (so the menu reuses the existing verb/command path).
    public struct Action: Equatable, Sendable {
        public let title: String
        public let verb: String
        public init(title: String, verb: String) { self.title = title; self.verb = verb }
    }

    /// The dynamic menu's TITLE for a content kind, or nil when there's no
    /// content-specific menu for it (audio/video/pdf/sqlite/archive/canvas/binary/
    /// unknown have in-view actions, not menu verbs — a follow-on).
    public static func menuTitle(for category: FileCategory) -> String? {
        actions(for: category).isEmpty ? nil : title(category)
    }

    /// The candidate content-specific actions for a category (empty ⇒ no menu).
    public static func actions(for category: FileCategory) -> [Action] {
        switch category {
        case .markdown, .mermaid:
            return [
                Action(title: "Lint Markdown", verb: "lint-markdown"),
                Action(title: "Check Links", verb: "check-links"),
                Action(title: "Align Tables", verb: "align-tables"),
                Action(title: "Insert Table of Contents", verb: "edit-insert-toc"),
                Action(title: "Copy as HTML", verb: "copy-doc-as-html"),
                Action(title: "Document Statistics", verb: "document-stats"),
            ]
        case .plainText:
            // .csv/.tsv/.txt/.log all land here; the CSV converters self-gate.
            return [
                Action(title: "CSV Summary", verb: "csv-summary"),
                Action(title: "Copy CSV as Markdown Table", verb: "copy-csv-as-markdown-table"),
                Action(title: "Copy CSV as JSON", verb: "copy-csv-as-json"),
                Action(title: "Document Statistics", verb: "document-stats"),
            ]
        case .code:
            // .json lands in code; the JSON tools self-gate for non-JSON code.
            return [
                Action(title: "Minify JSON", verb: "edit-minify-json"),
                Action(title: "Copy JSON as CSV", verb: "copy-json-as-csv"),
                Action(title: "Document Statistics", verb: "document-stats"),
            ]
        case .html:
            return [
                Action(title: "Copy as HTML", verb: "copy-doc-as-html"),
            ]
        case .binary, .image, .audio, .video, .pdf, .sqlite, .archive, .canvas, .unknown:
            return []
        }
    }

    private static func title(_ category: FileCategory) -> String {
        switch category {
        case .markdown, .mermaid: return "Markdown"
        case .plainText:          return "Data"
        case .code:               return "Code"
        case .html:               return "HTML"
        default:                  return "Content"
        }
    }
}
