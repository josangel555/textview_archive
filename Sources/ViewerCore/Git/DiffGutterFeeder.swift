import Foundation

/// Transforms a unified `git diff` string into the CM6 outbound
/// `setGutterMarkers` payload — one `CMGutterMarker` per touched line.
///
/// Pure logic: no I/O, no Process spawn, no threading. The caller
/// (DocumentModel's `refreshDiffMarks`) runs the actual `git diff
/// HEAD -- <path>` off-main and hands the captured string here.
///
/// Mapping:
///   - `DiffMark.added`     → `CMGutterMarker(kind: "added")`
///   - `DiffMark.modified`  → `CMGutterMarker(kind: "modified")`
///   - `DiffMark.deleted`   → `CMGutterMarker(kind: "removed")`
///
/// The JS bundle's `applySetGutterMarkers` (codemirror.html) understands
/// the `"added"|"removed"|"modified"|"blame"` vocabulary. We surface
/// "removed" rather than "deleted" so the bridge stays in lock-step
/// with the CSS class names the bundle ships.
///
/// Output is sorted by line number — deterministic, host-testable,
/// and stable across runs so the dedup check in
/// `CodeMirrorEditorView.applyPendingState` (Array equality) actually
/// no-ops on idempotent recomputes.
public enum DiffGutterFeeder {

    /// JS-side gutter `kind` vocabulary. Public so callers (tests,
    /// other producers like git blame) can target the same strings
    /// without re-encoding the spelling here.
    public enum Kind {
        public static let added    = "added"
        public static let modified = "modified"
        public static let removed  = "removed"
    }

    /// Convert one parsed-diff marks dict (line → DiffMark) into the
    /// CM6 marker payload. Lines come out sorted ascending. Kept
    /// separate from `markers(fromDiff:)` so callers that already have
    /// the marks dict (e.g. the source-view gutter feeder) can re-use
    /// the produced markers without re-parsing the diff text.
    public static func markers(from marks: [Int: DiffMark]) -> [CMGutterMarker] {
        marks
            .sorted { $0.key < $1.key }
            .map { line, mark in
                CMGutterMarker(line: line, kind: kindString(for: mark))
            }
    }

    /// Convenience: parse the unified-diff string and produce the CM6
    /// marker payload in one call. Routes through `RustDiffAdapter` (the
    /// `.diff` capability gate, TSK-561 closed the routing gap here) so
    /// the parsing rules stay in one place (modify-pairs, deletion-marks-
    /// next-line, "No newline at end of file" tolerance, etc.) — Rust
    /// engine by default, Swift `DiffHunkParser` as the gate-off/fault
    /// fallback inside the adapter.
    public static func markers(fromDiff diff: String) -> [CMGutterMarker] {
        markers(from: RustDiffAdapter.hunkMarks(diff))
    }

    /// Map a `DiffMark` case to the JS-side `kind` string. Centralized
    /// so the wire vocabulary lives in one place — bridge codec tests
    /// already pin the encoding of `kind`; this is the producer's
    /// matching constant.
    public static func kindString(for mark: DiffMark) -> String {
        switch mark {
        case .added:    return Kind.added
        case .modified: return Kind.modified
        case .deleted:  return Kind.removed
        }
    }
}
