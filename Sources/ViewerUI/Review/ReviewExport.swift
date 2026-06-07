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
    /// instructions. Pure — no side effects. Returns `nil` only on an
    /// encoder failure (effectively never for these value types).
    static func renderJSON(_ session: ReviewSession, instructions: String?) -> String? {
        try? ReviewExporter.exportAsString(session.review, instructions: instructions)
    }

    /// Export to the system pasteboard (JSON as a UTF-8 string). Records the
    /// export + transitions to `.sent`. Returns the JSON that was copied, or
    /// `nil` on failure.
    @discardableResult
    static func exportToClipboard(
        _ session: ReviewSession,
        instructions: String?,
        pasteboard: NSPasteboard = .general
    ) -> String? {
        guard let json = renderJSON(session, instructions: instructions) else { return nil }
        Pasteboard.copy(json, to: pasteboard)
        session.recordExport(target: .clipboard, destination: "clipboard")
        return json
    }

    /// Export to a file URL the caller resolved (e.g. via NSSavePanel).
    /// Records the export + transitions to `.sent`. Returns `true` on a
    /// successful write.
    @discardableResult
    static func exportToFile(
        _ session: ReviewSession,
        instructions: String?,
        url: URL
    ) -> Bool {
        guard let json = renderJSON(session, instructions: instructions) else { return false }
        do {
            try json.data(using: .utf8)!.write(to: url, options: .atomic)
            session.recordExport(target: .file, destination: url.path)
            return true
        } catch {
            return false
        }
    }
}
