import Foundation

/// I-08 (owner intake 2026-08-01): "apply the diff to file" from Local History
/// — selectively. `Restore` replaces the WHOLE buffer, which is exactly wrong
/// when the current file has moved on since the version (the live incident:
/// the owner hand-copied lost lines out of the history viewer instead).
///
/// This builds a PICKABLE region set from a plain 2-way diff of
/// (current, version): every differing run becomes a synthetic
/// `.conflict(base: currentRun, ours: currentRun, theirs: versionRun)`, so the
/// EXISTING 3-pane conflict-resolution UI (TSK-1171 — per-region picker, Apply
/// gating, undoable buffer apply) doubles as a per-hunk "bring this back"
/// picker: ours = keep current, theirs = take the version's lines.
///
/// Pure + host-tested (`VersionPickMergeTests`). Uses `LineDiff.Patch` (Myers)
/// for the runs and mirrors its `components(separatedBy: "\n")` split so op
/// indexes align and a trailing newline round-trips through
/// `ThreeWayMerge.Result.resolvedText`.
public enum VersionPickMerge {

    /// Synthesize the pickable result, or nil when the two texts are identical
    /// (nothing to pick — callers say so instead of opening an empty sheet).
    public static func regions(current: String, version: String) -> ThreeWayMerge.Result? {
        let patch = LineDiff.Patch.between(current, version)
        guard !patch.ops.isEmpty else { return nil }
        let cur = current.components(separatedBy: "\n")   // == LineDiff.lines(of:)
        var regions: [ThreeWayMerge.Region] = []
        var cursor = 0
        for op in patch.ops {
            guard op.index >= cursor, op.index + op.delete <= cur.count else {
                return nil   // malformed patch — degrade to "nothing to pick"
            }
            if op.index > cursor {
                regions.append(.unchanged(Array(cur[cursor..<op.index])))
            }
            let currentRun = Array(cur[op.index..<(op.index + op.delete)])
            regions.append(.conflict(
                base: currentRun, ours: currentRun, theirs: op.insert))
            cursor = op.index + op.delete
        }
        if cursor < cur.count {
            regions.append(.unchanged(Array(cur[cursor...])))
        }
        return ThreeWayMerge.Result(regions: regions)
    }
}
