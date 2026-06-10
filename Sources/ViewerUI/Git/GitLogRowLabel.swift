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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let r = layoutRow {
                GitGraphColumn(row: r, maxLane: maxLane, isHead: isHead)
                    .frame(minHeight: uiSize(38))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(commit.sha)
                        .font(.system(size: uiSize(10), design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    if isHead {
                        chip("HEAD", color: .accentColor)
                    }
                    ForEach(branchRefs, id: \.self) { ref in
                        Text("⎇ \(ref)")
                            .font(.system(size: uiSize(9)))
                            .foregroundStyle(Color.accentColor)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, uiSize(10))
        .padding(.vertical, uiSize(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // TSK-595: strong selected state for the row whose diff is
        // shown. Explicit accent fill — NOT the system unemphasized
        // selection color, which renders grey and invisible (the
        // TSK-488 selectedContentBackgroundColor lesson).
        .background(
            isSelected ? Color.accentColor.opacity(0.28) : Color.clear,
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
