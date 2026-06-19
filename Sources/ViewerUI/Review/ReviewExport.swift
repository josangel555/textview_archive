import SwiftUI
import AppKit
import ViewerCore

// MARK: - ReviewExportCoordinator (§6.5)
//
// The Claude-handoff flow: render the review via the unchanged
// `ReviewExporter`, write to the pasteboard or a save panel, append a
// `ReviewExportRecord`, and transition state → .sent (guarded). Kept as a
// small @MainActor helper so the menu/buttons stay declarative and the
// side-effecting bits are testable in isolation (the pure JSON build is
// already covered by ReviewExporterTests in ViewerCore).

@MainActor
enum ReviewExportCoordinator {

    /// Build the export JSON string for `session`'s review with the given
    /// instructions and snippet `mode`. Pure — no side effects. Returns `nil`
    /// only on an encoder failure (effectively never for these value types).
    ///
    /// `mode` selects whether each comment carries its verbatim hunk snippet
    /// (`.withCode`, the default) or just the comment + line anchor
    /// (`.withoutCode`, for when the receiver already has the source or the
    /// code shouldn't leave the machine). TSK-530.
    static func renderJSON(
        _ session: ReviewSession,
        instructions: String?,
        mode: ReviewExporter.ExportMode = .withCode
    ) -> String? {
        try? ReviewExporter.exportAsString(
            session.review, instructions: instructions, mode: mode
        )
    }

    /// Export to the system pasteboard (JSON as a UTF-8 string). Records the
    /// export + transitions to `.sent`. Returns the JSON that was copied, or
    /// `nil` on failure. `mode` picks the with/without-snippet payload (TSK-530).
    @discardableResult
    static func exportToClipboard(
        _ session: ReviewSession,
        instructions: String?,
        mode: ReviewExporter.ExportMode = .withCode,
        pasteboard: NSPasteboard = .general
    ) -> String? {
        guard let json = renderJSON(session, instructions: instructions, mode: mode) else { return nil }
        Pasteboard.copy(json, to: pasteboard)
        session.recordExport(target: .clipboard, destination: "clipboard")
        return json
    }

    /// Export to a file URL the caller resolved (e.g. via NSSavePanel).
    /// Records the export + transitions to `.sent`. Returns `true` on a
    /// successful write. `mode` picks the with/without-snippet payload (TSK-530).
    @discardableResult
    static func exportToFile(
        _ session: ReviewSession,
        instructions: String?,
        url: URL,
        mode: ReviewExporter.ExportMode = .withCode
    ) -> Bool {
        guard let json = renderJSON(session, instructions: instructions, mode: mode) else { return false }
        do {
            try json.data(using: .utf8)!.write(to: url, options: .atomic)
            session.recordExport(target: .file, destination: url.path)
            return true
        } catch {
            return false
        }
    }
}
