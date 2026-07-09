import SwiftUI
import ViewerCore

/// Minimal READ-ONLY cell-list renderer for a parsed `.ipynb`.
///
/// FOUNDATION SLICE (TSK-717): stacks each cell's source vertically with a
/// type chip (code / markdown / raw) and a monospaced source block. NO
/// execution, NO rich output rendering, NO editing — those are later slices
/// of the notebooks epic. Gated behind `NotebookGate`; the host only routes
/// `.ipynb` here when the gate is ON (default OFF → current raw-JSON view).
///
/// Pure SwiftUI (no `NSViewRepresentable`), so it is free of the compositor
/// occlusion class documented in CLAUDE.md — there is no opaque AppKit surface
/// to composite over sibling SwiftUI views.
public struct NotebookCellListView: View {
    private let document: NotebookDocument
    private let fontSize: CGFloat

    public init(document: NotebookDocument, fontSize: CGFloat = 13) {
        self.document = document
        self.fontSize = fontSize
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(document.cells) { cell in
                    NotebookCellRow(cell: cell, fontSize: fontSize)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("mdv.notebook.cellList")
    }
}

/// One stacked cell: a type chip header + a monospaced source block.
struct NotebookCellRow: View {
    let cell: NotebookCell
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: fontSize - 2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(chipColor.opacity(0.18), in: Capsule())
                if cell.cellType == .code, let count = executionCountLabel {
                    Text(count)
                        .font(.system(size: fontSize - 3, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(cell.source.isEmpty ? " " : cell.source)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chipColor.opacity(0.25), lineWidth: 1)
                )
            // TSK-1440: render code-cell OUTPUTS (stream/result text, images,
            // errors) below the source — previously only the source showed.
            if cell.cellType == .code {
                let outputs = NotebookOutputParser.parse(cell.outputs)
                ForEach(Array(outputs.enumerated()), id: \.offset) { _, out in
                    outputView(out)
                }
            }
        }
    }

    /// One rendered output. Text/stream → mono block; image → decoded NSImage;
    /// error → red ename/evalue + traceback; unknown → a subtle note.
    @ViewBuilder
    private func outputView(_ out: NotebookOutput) -> some View {
        switch out {
        case .stream(_, let text), .text(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.08)))
                .accessibilityIdentifier("mdv.notebook.output.text")
        case .image(_, let base64):
            if let data = Data(base64Encoded: base64), let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mdv.notebook.output.image")
            } else {
                outputNote("(image output — could not decode)")
            }
        case .error(let ename, let evalue, let traceback):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ename): \(evalue)")
                    .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
                Text(traceback)
                    .font(.system(size: fontSize - 2, design: .monospaced))
                    .textSelection(.enabled)
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(0.08)))
            .accessibilityIdentifier("mdv.notebook.output.error")
        case .unknown(let type):
            outputNote("(output: \(type))")
        }
    }

    private func outputNote(_ s: String) -> some View {
        Text(s)
            .font(.system(size: fontSize - 2))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        switch cell.cellType {
        case .code: return "CODE"
        case .markdown: return "MARKDOWN"
        case .raw: return "RAW"
        }
    }

    private var chipColor: Color {
        switch cell.cellType {
        case .code: return .blue
        case .markdown: return .green
        case .raw: return .gray
        }
    }

    /// `[N]` / `[ ]` execution-count badge (display-only).
    private var executionCountLabel: String? {
        guard case let .number(raw)? = cell.executionCount else {
            // null / nil → not yet executed
            return cell.cellType == .code ? "[ ]" : nil
        }
        return "[\(raw)]"
    }
}
