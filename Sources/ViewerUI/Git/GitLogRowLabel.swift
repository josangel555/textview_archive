import SwiftUI
import ViewerCore

/// One Git Log row's LABEL — extracted from `GitLogTab.row` (pure
/// code-motion) so the selected-row treatment is ImageRenderer-testable:
/// the row lives inside a ScrollView in situ, and ScrollView is opaque
/// to every headless render oracle (the TSK-593 discovery), so the
/// accent-fill pixel guard (TSK-595) must render the extracted label.
/// Plain value inputs only — no model observation — which is also what
/// keeps per-row body cost flat in the log list.
struct GitLogRowLabel: View {
    let commit: GitClient.GraphCommit
    let layoutRow: GraphLayout.Row?
    let maxLane: Int
    let isHead: Bool
    let branchRefs: [String]
    let authorLine: String
    let isSelected: Bool
    let uiSize: (CGFloat) -> CGFloat
    /// TSK-1601: TYPED decorations (local / remote / tag / HEAD / sibling
    /// worktree) so each chip gets its own color. When empty the row falls
    /// back to `branchRefs` classified with defaults — keeps every existing
    /// call site (and the ImageRenderer pixel tests) source-compatible.
    var typedRefs: [GitRefKind.Ref] = []
    /// TSK-1603 — branch the pointer is over: this row's graph dims every
    /// OTHER branch, and a row belonging to the hovered branch gets a faint
    /// tint, so "which commits are part of this branch" reads at a glance.
    var hoveredBranchID: Int? = nil

    /// True when this row's commit belongs to the hovered branch run.
    private var isOnHoveredBranch: Bool {
        guard let hoveredBranchID, let layoutRow else { return false }
        return layoutRow.branchID == hoveredBranchID
    }

    private var resolvedRefs: [GitRefKind.Ref] {
        typedRefs.isEmpty ? GitRefKind.classifyAll(branchRefs) : typedRefs
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let r = layoutRow {
                // TSK-1603: the graph column spans the row EDGE TO EDGE (the
                // vertical padding moved onto the text column below), so one
                // row's strokes meet the next row's exactly — no seam.
                GitGraphColumn(row: r, maxLane: maxLane, isHead: isHead,
                               hoveredBranchID: hoveredBranchID)
                    .frame(minHeight: uiSize(38))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // TSK-1601: the sha is an ADDRESS — quiet, so the typed
                    // ref chips carry the color signal.
                    Text(commit.sha)
                        .font(.system(size: uiSize(10), design: .monospaced))
                        .foregroundStyle(GitRefChipStyle.commitID)
                    // A commit that IS the current HEAD but carries no "HEAD"
                    // decoration (detached, or the decoration was filtered)
                    // still gets its marker.
                    if isHead, !resolvedRefs.contains(where: { $0.kind == .head }) {
                        GitRefChip(
                            ref: GitRefKind.Ref(name: "HEAD", kind: .head),
                            uiSize: uiSize)
                    }
                    ForEach(Array(resolvedRefs.enumerated()), id: \.offset) { _, ref in
                        GitRefChip(ref: ref, uiSize: uiSize)
                    }
                    Spacer(minLength: 4)
                    Text(GitRelativeTime.format(unix: commit.timestamp))
                        .font(.system(size: uiSize(9)))
                        .foregroundStyle(.tertiary)
                }
                Text(commit.subject)
                    .font(.system(size: uiSize(12),
                                  weight: commit.isMerge ? .regular : .medium))
                    .foregroundStyle(commit.isMerge ? Color.secondary : Color.primary)
                    .lineLimit(2)
                Text(authorLine)
                    .font(.system(size: uiSize(10)))
                    .foregroundStyle(.tertiary)
            }
            // TSK-1603: vertical padding lives on the TEXT column now — the
            // graph column must stay flush so its strokes are continuous.
            .padding(.vertical, uiSize(4))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, uiSize(6))
        .padding(.trailing, uiSize(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // TSK-595: strong selected state for the row whose diff is
        // shown. Explicit accent fill — NOT the system unemphasized
        // selection color, which renders grey and invisible (the
        // TSK-488 selectedContentBackgroundColor lesson).
        .background(
            isSelected
                ? Color.accentColor.opacity(0.28)
                // TSK-1603: faint tint for rows on the hovered branch.
                : (isOnHoveredBranch ? Color.accentColor.opacity(0.09) : Color.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: uiSize(8), weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
    }
}
