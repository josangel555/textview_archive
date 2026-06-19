import SwiftUI
import ViewerCore

/// Compact, self-contained unified-diff renderer for an agent (Claude Code)
/// file-mutating tool call (TSK-940 — "Review agent-written diffs in-app").
///
/// The Claude monitor's detail card previously dumped an `Edit`/`Write`/
/// `MultiEdit` tool call as a raw `old_string: …` / `new_string: …` text blob.
/// This view turns that payload into a colored unified diff: removed lines
/// tinted red, added lines green, a `@@` hunk banner, and a per-file header.
///
/// It is intentionally decoupled from `DocumentModel`/`DiffView` (which the
/// monitor never wires up): the model is produced by the host-tested
/// `AgentDiffExtractor` + `RustDiffAdapter.parse`, and rendering is plain
/// SwiftUI `Text` rows — no WebView, no AppKit surface, so none of the
/// compositor-occlusion traps apply. Pure SwiftUI siblings only.
struct AgentDiffInlineView: View {

    /// The agent tool call name (`Edit` / `Write` / `MultiEdit`).
    let toolName: String
    /// The decoded tool input (`file_path`, `old_string`, `new_string`, …).
    let input: [String: String]

    /// Parsed diff files, derived once from the extractor output. Empty when
    /// the tool call carried no renderable change (the caller should not host
    /// this view in that case, but we degrade gracefully).
    private var files: [UnifiedDiff.File] {
        guard let text = AgentDiffExtractor.unifiedDiffText(toolName: toolName, input: input)
        else { return [] }
        return RustDiffAdapter.parse(text)
    }

    var body: some View {
        let parsed = files
        if parsed.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parsed.enumerated()), id: \.offset) { _, file in
                    fileBlock(file)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fileBlock(_ file: UnifiedDiff.File) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Per-file header: the path + a +adds/-dels stat badge.
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(filePath(file))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(stats(file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                hunkBlock(hunk)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func hunkBlock(_ hunk: UnifiedDiff.Hunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.purple)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                lineRow(line)
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: UnifiedDiff.Line) -> some View {
        Text(line.kind.diffPrefix + line.content)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(lineColor(line.kind))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lineBackground(line.kind))
            .textSelection(.enabled)
    }

    // MARK: - Styling

    private func lineColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added:     return Color.green
        case .removed:   return Color.red
        case .context:   return Color.secondary
        case .noNewline: return Color.secondary
        }
    }

    private func lineBackground(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added:     return Color.green.opacity(0.10)
        case .removed:   return Color.red.opacity(0.10)
        case .context, .noNewline: return .clear
        }
    }

    private func filePath(_ file: UnifiedDiff.File) -> String {
        if file.isNew { return file.newPath }
        if file.isDeleted { return file.oldPath }
        return file.newPath.isEmpty ? file.oldPath : file.newPath
    }

    private func stats(_ file: UnifiedDiff.File) -> String {
        var adds = 0, dels = 0
        for hunk in file.hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added:   adds += 1
                case .removed: dels += 1
                default: break
                }
            }
        }
        return "+\(adds) -\(dels)"
    }
}
