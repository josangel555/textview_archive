import Foundation
import ViewerCore

/// TSK-1448 — the first-run experience's DocumentModel glue: write the sample
/// tour document ("Welcome to TextView.md") and open it RENDERED. The one-shot
/// latch + the sample content + the collision-safe write are host-tested in
/// ViewerCore (`FirstRunExperience`); this reaches them.
extension DocumentModel {

    /// Write the first-run sample into `dir` (default: the app Samples dir) and
    /// open it. Collision-safe — a user's own same-named file is never
    /// overwritten (OutputNaming). Returns the opened URL, or nil on failure.
    @discardableResult
    public func openFirstRunSample(dir: URL? = nil) -> URL? {
        guard let dir = dir ?? Self.firstRunSamplesDirectory() else { return nil }
        guard let url = try? FirstRunExperience.writeSample(to: dir) else { return nil }
        openPath(url)   // .md opens rendered — the tour demonstrates the lenses
        return url
    }

    /// Application Support ▸ MarkdownViewer ▸ Samples (created on demand). Kept
    /// out of the user's workspace so the tour never clutters their project.
    static func firstRunSamplesDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("MarkdownViewer/Samples", isDirectory: true)
    }
}
