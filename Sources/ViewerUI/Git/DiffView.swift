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
                    hunkBlock(hunk)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor),
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
        var added = 0, removed = 0
        for hunk in file.hunks {
            for line in hunk.lines {
                if line.kind == .added   { added += 1 }
                if line.kind == .removed { removed += 1 }
            }
        }
        if added == 0 && removed == 0 { return "" }
        return "+\(added) −\(removed)"
    }

    @ViewBuilder
    private func hunkBlock(_ hunk: UnifiedDiff.Hunk) -> some View {
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
