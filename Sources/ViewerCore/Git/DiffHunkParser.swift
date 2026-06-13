import Foundation

/// Per-line diff status mapped from `git diff` unified output.
///
/// TSK-649 Stage B #4: the Swift `DiffHunkParser` that produced these marks has
/// been DELETED — gutter-mark flattening is now rust-only (`mdvcore_diff_hunk_marks`
/// via `RustDiffAdapter.hunkMarks`). This `DiffMark` MODEL stays: the adapter maps
/// the Rust wire enum into it and the source-view gutter renders it.
public enum DiffMark: Equatable, Sendable {
    /// New line in the working tree (didn't exist at HEAD).
    case added
    /// Line existed at HEAD but its content was modified.
    case modified
    /// Marks the working-tree line **after** a deletion. The deleted
    /// line itself isn't in the working tree (it's gone), so the
    /// gutter signal lands on its successor with a thin tick so the
    /// user knows lines were removed just above.
    case deleted
}
