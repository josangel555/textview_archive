import Foundation
import RustCore

/// Routes unified-diff parsing through the Rust core (migration slice #3) when
/// the `.diff` gate is on, falling back to the Swift `DiffParser` otherwise —
/// the single place the two implementations meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; Rust bridge
/// fault → Swift. Default-OFF; the diff viewer is byte-identical to today until
/// the gate is flipped. Only the *parsing* is routed — the `git diff` subprocess
/// that produces the text stays in Swift `GitClient`.
public enum RustDiffAdapter {

    /// Parse `text` (unified-diff output) into the structured model, routing per
    /// the `.diff` gate.
    public static func parse(_ text: String) -> [UnifiedDiff.File] {
        outcome(text).value
    }

    /// Same, but also reporting which engine produced the result (A/B / diag).
    public static func outcome(_ text: String) -> CoreOutcome<[UnifiedDiff.File]> {
        RustCoreFallback.run(
            .diff,
            rust: { try toUnified(mdvCoreParseDiff(text: text)) },
            swift: { DiffParser.parse(text) }
        )
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
}
