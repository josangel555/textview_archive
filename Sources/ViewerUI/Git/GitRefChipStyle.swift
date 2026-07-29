import AppKit
import SwiftUI
import ViewerCore

/// TSK-1601 — the per-KIND colors for git-log decorations. Previously the
/// commit id, HEAD, and every branch/tag ref all rendered in
/// `Color.accentColor`: one blue wash. Each kind now reads distinctly at a
/// glance (owner 2026-07-24).
///
/// Palette rationale (works on both the light and dark chrome):
///   - commit id  → secondary/monospace grey: it's an ADDRESS, not a label,
///                  and de-emphasizing it lets the refs carry the color.
///   - HEAD       → accent (the app's own highlight = "you are here").
///   - local      → green.
///   - remote     → purple (clearly "not mine / upstream").
///   - tag        → orange (release markers pop).
///   - worktree   → teal + the worktree name, so a branch checked out in a
///                  SIBLING worktree is visibly different from a local branch.
///   - other      → secondary (stash / grafted / replaced).
enum GitRefChipStyle {

    /// SYSTEM semantic colors, not literals: macOS tunes each for light and
    /// dark appearance (and for the accessibility contrast variants), so the
    /// chips stay legible in both without a hand-rolled dynamic provider —
    /// which is exactly what the chrome color ratchet
    /// (`HardCodedColorRatchetTests`) is there to enforce. They also match
    /// the hues users already read as "branch / remote / tag" elsewhere.
    static func color(for kind: GitRefKind) -> Color {
        switch kind {
        case .head:           return .accentColor   // "you are here"
        case .localBranch:    return .green
        case .remoteBranch:   return .purple
        case .tag:            return .orange
        case .worktreeBranch: return .teal
        case .other:          return .secondary
        }
    }

    /// SF Symbol per kind — shape backs up color for accessibility (color
    /// alone must never be the only signal).
    static func symbol(for kind: GitRefKind) -> String {
        switch kind {
        case .head:           return "location.fill"
        case .localBranch:    return "arrow.triangle.branch"
        case .remoteBranch:   return "cloud"
        case .tag:            return "tag.fill"
        case .worktreeBranch: return "square.split.2x1"
        case .other:          return "circle"
        }
    }

    /// The commit-id (sha) color — an address, deliberately quiet.
    static var commitID: Color { .secondary }
}

/// One decoration chip: symbol + name (+ the worktree name for a sibling
/// worktree's branch), tinted by kind.
struct GitRefChip: View {
    let ref: GitRefKind.Ref
    let uiSize: (CGFloat) -> CGFloat

    var body: some View {
        let color = GitRefChipStyle.color(for: ref.kind)
        HStack(spacing: 2) {
            Image(systemName: GitRefChipStyle.symbol(for: ref.kind))
                .font(.system(size: uiSize(7.5), weight: .bold))
            Text(ref.name)
                .font(.system(size: uiSize(9), weight: .semibold))
            if let wt = ref.worktreeName {
                Text("· \(wt)")
                    .font(.system(size: uiSize(8)))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
        .accessibilityIdentifier("mdv.gitLog.ref.\(ref.kind.rawValue)")
    }
}
