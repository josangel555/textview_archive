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
        }
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
