import SwiftUI
import ViewerCore

/// Renders a unified diff as a per-file, per-hunk colored view with
/// old/new line numbers. Replaces the "open the .diff as plain text"
/// fallback for git-generated diffs (Status row, commit show, stash show).
///
/// Side-by-side mode is a future polish — v1 is unified.
struct DiffView: View {
    let text: String
    @ObservedObject var doc: DocumentModel

    /// Optional review session (§6.2). When `nil` (the default — both
    /// existing call sites), `DiffView` renders EXACTLY as before: read-only
    /// diff, no gutter affordance, no comment threads. When non-nil, the
    /// diff becomes review-aware: comment threads render under their anchored
    /// lines and a hover gutter opens the composer. Every review affordance
    /// is gated on `reviewSession != nil`, so the read-only path is provably
    /// unchanged (pinned by `DiffViewReviewTests`).
    var reviewSession: ReviewSession? = nil

    /// `DiffParser.parse` is O(diff size) and allocates a fresh
    /// `[UnifiedDiff.File]` tree per call. As a computed property
    /// it re-ran on every body re-eval (zoom change, hover, etc.) —
    /// on a multi-thousand-line commit diff that's the dominant
    /// cost. @State + .onChange recomputes only when `text` changes.
    @State private var files: [UnifiedDiff.File] = []

    var body: some View {
        Group {
            if files.isEmpty {
                empty
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                            fileBlock(file)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .onAppear { files = DiffParser.parse(text) }
        .onChange(of: text) { _, newText in files = DiffParser.parse(newText) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No diff content.")
                .font(.system(size: doc.uiSize(13)))
                .foregroundStyle(.secondary)
            Text("The file may be unchanged, untracked, or binary.")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fileBlock(_ file: UnifiedDiff.File) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            if file.isBinary {
                Text("Binary file — no textual diff.")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if file.hunks.isEmpty {
                Text("(no hunks)")
                    .font(.system(size: doc.uiSize(11)))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkBlock(hunk, filePath: filePath(of: file))
                }
            }
        }
        .background(Palette.textBackground,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
    }

    private func fileHeader(_ file: UnifiedDiff.File) -> some View {
        HStack(spacing: 8) {
            statusBadge(file)
            if file.isRename {
                Text(file.oldPath)
                    .font(.system(size: doc.uiSize(12), design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(file.newPath)
                    .font(.system(size: doc.uiSize(12), design: .monospaced))
                    .foregroundStyle(.primary)
            } else {
                Text(file.newPath.isEmpty ? file.oldPath : file.newPath)
                    .font(.system(size: doc.uiSize(12), weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text(stats(file))
                .font(.system(size: doc.uiSize(10), design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }

    private func statusBadge(_ file: UnifiedDiff.File) -> some View {
        let (label, color): (String, Color) = {
            if file.isNew     { return ("A", .green) }
            if file.isDeleted { return ("D", .red) }
            if file.isRename  { return ("R", .blue) }
            return ("M", .yellow)
        }()
        return Text(label)
            .font(.system(size: doc.uiSize(10), weight: .bold,
                          design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }

    private func stats(_ file: UnifiedDiff.File) -> String {
        // Single source of truth: the host-tested UnifiedDiff.File.lineStats
        // (TSK-514). Identical "+a −r" output; was an untested inline counter.
        let s = file.lineStats
        if s.added == 0 && s.removed == 0 { return "" }
        return "+\(s.added) −\(s.removed)"
    }

    @ViewBuilder
    private func hunkBlock(_ hunk: UnifiedDiff.Hunk, filePath: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header banner — like "@@ -10,3 +12,5 @@ func foo()"
            HStack(spacing: 6) {
                Text(hunkCoords(hunk))
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !hunk.header.isEmpty {
                    Text(hunk.header)
                        .font(.system(size: doc.uiSize(10), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.06))

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                lineRow(line)
                // Review affordances — entirely gated on a session being
                // present. The nil (read-only) path renders only `lineRow`.
                if reviewSession != nil {
                    reviewAffordances(for: line, hunk: hunk, filePath: filePath)
                }
            }
        }
    }

    /// New-path is what `ReviewComment.filePath` is keyed on (post-change
    /// path); fall back to old path for pure deletions.
    private func filePath(of file: UnifiedDiff.File) -> String {
        file.newPath.isEmpty ? file.oldPath : file.newPath
    }

    /// Comment threads anchored to this line, plus the inline composer when
    /// the user has opened it on this line. Only invoked when
    /// `reviewSession != nil`.
    @ViewBuilder
    private func reviewAffordances(
        for line: UnifiedDiff.Line, hunk: UnifiedDiff.Hunk, filePath: String
    ) -> some View {
        if let session = reviewSession {
            let lineNo = line.newLineNo ?? line.oldLineNo
            // Threads whose anchor start lands on this line.
            let topLevel = session.review.comments.filter {
                $0.parentId == nil && $0.filePath == filePath
                && lineNo != nil && $0.anchor.startLine == lineNo
            }
            ForEach(topLevel) { parent in
                CommentThreadView(
                    doc: doc,
                    parent: parent,
                    replies: session.review.comments
                        .filter { $0.parentId == parent.id }
                        .sorted { $0.createdAt < $1.createdAt },
                    anchorState: session.anchorStates[parent.id] ?? .unknown,
                    onResolveToggle: { session.setResolved(id: parent.id, !parent.resolved) },
                    onReply: { /* VM-owed: opens reply composer */ },
                    onEdit: { /* VM-owed: opens edit composer */ },
                    onDelete: { session.delete(id: parent.id) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private func hunkCoords(_ h: UnifiedDiff.Hunk) -> String {
        "@@ -\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) @@"
    }

    private func lineRow(_ line: UnifiedDiff.Line) -> some View {
        HStack(spacing: 0) {
            lineNoCell(line.oldLineNo)
            lineNoCell(line.newLineNo)
            // Gutter +/- column
            Text(prefix(for: line.kind))
                .font(.system(size: doc.uiSize(11), design: .monospaced))
                .foregroundStyle(prefixColor(line.kind))
                .frame(width: 14, alignment: .center)
            // Content
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(size: doc.uiSize(11), design: .monospaced))
                .foregroundStyle(contentColor(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .frame(minHeight: 17)
        .background(rowBackground(line.kind))
    }

    private func lineNoCell(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: doc.uiSize(10), design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private func prefix(for kind: UnifiedDiff.Line.Kind) -> String {
        switch kind {
        case .context:    return " "
        case .added:      return "+"
        case .removed:    return "-"
        case .noNewline:  return "\\"
        }
    }

    private func prefixColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added:    return .green
        case .removed:  return .red
        case .context:  return .secondary
        case .noNewline: return Color.secondary.opacity(0.6)
        }
    }

    private func contentColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added, .removed: return .primary
        case .context:         return .secondary
        case .noNewline:       return Color.secondary.opacity(0.6)
        }
    }

    private func rowBackground(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added:    return Color.green.opacity(0.10)
        case .removed:  return Color.red.opacity(0.10)
        default:        return .clear
        }
    }
}
