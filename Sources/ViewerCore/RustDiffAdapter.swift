import Foundation
import RustCore

/// Unified-diff parsing, served by the Rust core (`mdvcore_diff_parse` +
/// `mdvcore_diff_hunk_marks`).
///
/// TSK-649 Stage B #4: the Swift `DiffParser` / `DiffHunkParser` twins have been
/// DELETED. After a quiet default-ON soak (Stage A), the `.diff` gate, env var,
/// Settings toggle, and the Swift fallback all retire — this is now a direct,
/// rust-only call. A bridge fault can no longer fall back to Swift, so it
/// degrades to an EMPTY result (no diff files / no gutter marks — a safe,
/// non-crashing "nothing to show" state) and is made LOUD on the `rust-core` Obs
/// channel (surfaced by the TSK-636 audit log). The `.diff` ABI capability bit
/// stays required of the linked core. Only the *parsing* is rust — the `git diff`
/// subprocess that produces the text stays in Swift `GitClient`.
public enum RustDiffAdapter {

    /// Parse `text` (unified-diff output) into the structured model. Returns an
    /// empty file list (and logs) if the core call faults.
    public static func parse(_ text: String) -> [UnifiedDiff.File] {
        do {
            return try toUnified(mdvCoreParseDiff(text: text))
        } catch {
            Obs.shared.emit(
                .error, "rust-core",
                "diff parse faulted (no Swift fallback remains): \(error)",
                fields: ["capability": "diff"])
            return []
        }
    }

    /// Map the RustCore bridge's wire types to the ViewerCore `UnifiedDiff`
    /// model (RustCore can't depend on ViewerCore, so the crossing happens here).
    /// `RustCore.` qualifies `DiffLine`/`DiffFile` — ViewerCore has its own
    /// unrelated `DiffLine` (code-review comments) that would otherwise shadow it.
    public static func toUnified(_ files: [RustCore.DiffFile]) -> [UnifiedDiff.File] {
        files.map { f in
            UnifiedDiff.File(
                oldPath: f.oldPath, newPath: f.newPath,
                isNew: f.isNew, isDeleted: f.isDeleted,
                isBinary: f.isBinary, isRename: f.isRename,
                hunks: f.hunks.map { h in
                    UnifiedDiff.Hunk(
                        oldStart: h.oldStart, oldCount: h.oldCount,
                        newStart: h.newStart, newCount: h.newCount,
                        header: h.header,
                        lines: h.lines.map { l in
                            UnifiedDiff.Line(
                                kind: kind(l.kind),
                                oldLineNo: l.oldLineNo, newLineNo: l.newLineNo,
                                content: l.content)
                        })
                })
        }
    }

    private static func kind(_ k: RustCore.DiffLine.Kind) -> UnifiedDiff.Line.Kind {
        switch k {
        case .context: return .context
        case .added: return .added
        case .removed: return .removed
        case .noNewline: return .noNewline
        }
    }

    // MARK: - Gutter marks (the DiffHunkParser half of the slice)

    /// Flatten `diff` to a per-working-tree-line gutter-mark map. Returns an
    /// empty map (and logs) if the core call faults.
    public static func hunkMarks(_ diff: String) -> [Int: DiffMark] {
        do {
            return try mdvCoreDiffHunkMarks(text: diff).mapValues(mark)
        } catch {
            Obs.shared.emit(
                .error, "rust-core",
                "diff hunk-marks faulted (no Swift fallback remains): \(error)",
                fields: ["capability": "diff"])
            return [:]
        }
    }

    private static func mark(_ m: RustCore.DiffHunkMark) -> DiffMark {
        switch m {
        case .added: return .added
        case .modified: return .modified
        case .deleted: return .deleted
        }
    }
}
