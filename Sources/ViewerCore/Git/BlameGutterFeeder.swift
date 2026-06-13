import Foundation

/// Transforms `git blame` per-line authorship into the CM6 `setGutterMarkers`
/// payload — one `"blame"`-kind `CMGutterMarker` per line, carrying a hover
/// tooltip (`author · relative-time · summary  [shortSHA]`). Pure logic: no
/// I/O, no Process, no threading (the caller runs `GitClient.blame` off-main and
/// hands the `[BlameLine]` here). Mirrors `DiffGutterFeeder`; the JS bundle's
/// `applySetGutterMarkers` already maps the `"blame"` kind to `cm-blame-marker`.
public enum BlameGutterFeeder {

    /// Build the CM6 marker payload from blame lines. Sorted ascending by line
    /// (deterministic + idempotent so the editor's Array-equality dedup no-ops).
    /// `now` is injected so the relative-time tooltip is host-testable.
    public static func markers(
        from blame: [GitClient.BlameLine], now: Date = Date()
    ) -> [CMGutterMarker] {
        blame
            .sorted { $0.line < $1.line }
            .map { entry in
                CMGutterMarker(
                    line: entry.line,
                    kind: "blame",
                    tooltip: tooltip(for: entry, now: now))
            }
    }

    /// `Alice · 3 days ago · Fix the off-by-one  [a1b2c3d4]` — the hover shown
    /// in the blame gutter. A blank summary (e.g. an uncommitted line) drops the
    /// trailing separator so it doesn't read as a dangling field.
    static func tooltip(for entry: GitClient.BlameLine, now: Date) -> String {
        let when = GitRelativeTime.format(unix: entry.timestamp, now: now)
        let head = "\(entry.author) · \(when)"
        let body = entry.summary.isEmpty ? head : "\(head) · \(entry.summary)"
        return "\(body)  [\(entry.sha)]"
    }
}
