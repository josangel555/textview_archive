import SwiftUI
import ViewerCore

// MARK: - Problems (LSP diagnostics) section
//
// Sidebar section listing every LSP diagnostic, flat across files.
// Driven by `LSPDiagnosticsStore`, which the app wires to the
// `LSPPool`'s `setOnDiagnostics` callback. Each row: severity icon,
// file name + line, message. Click jumps to the file + line.
//
// Coexistence note: this section is intentionally additive — the
// parallel sidebar-polish agent's resizable-section divider sees it
// as just one more sibling.

public struct LSPProblemsPanel: View {

    @ObservedObject var store: LSPDiagnosticsStore
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight
    @State private var isExpanded: Bool = true
    @State private var severityFilter: SeverityFilter = .all

    let onJump: (URL, Int) -> Void

    public init(
        store: LSPDiagnosticsStore,
        onJump: @escaping (URL, Int) -> Void
    ) {
        self.store = store
        self.onJump = onJump
    }

    enum SeverityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case errors = "Errors"
        case warnings = "Warnings"
        var id: String { rawValue }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text(emptyMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { (_, row) in
                                ProblemRow(url: row.url, diagnostic: row.diagnostic)
                                    .onTapGesture {
                                        onJump(row.url, row.diagnostic.range.start.line + 1)
                                    }
                                    .accessibilityIdentifier(
                                        "mdv.problems.row.\(row.url.lastPathComponent):\(row.diagnostic.range.start.line)")
                            }
                        }
                    }
                }
                .frame(height: bodyHeight)
            }
        }
        .accessibilityIdentifier("mdv.problems")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("PROBLEMS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            // Counts pill — three small chips: errors / warnings / total.
            if store.errorCount > 0 {
                pill("\(store.errorCount)", color: .red)
            }
            if store.warningCount > 0 {
                pill("\(store.warningCount)", color: .orange)
            }
            Menu {
                ForEach(SeverityFilter.allCases) { f in
                    Button {
                        severityFilter = f
                    } label: {
                        HStack {
                            Text(f.rawValue)
                            if severityFilter == f {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by severity")
            .accessibilityIdentifier("mdv.problems.filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var rows: [(url: URL, diagnostic: LSPDiagnostic)] {
        switch severityFilter {
        case .all:       return store.allFlat
        case .errors:    return store.errorsOnly
        case .warnings:  return store.filtered(by: .warning)
        }
    }

    private var emptyMessage: String {
        if store.byURL.isEmpty {
            return "No problems detected."
        }
        return "No problems match this filter."
    }
}

private struct ProblemRow: View {
    let url: URL
    let diagnostic: LSPDiagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 11))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(":\(diagnostic.range.start.line + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let source = diagnostic.source {
                        Text("[\(source)]")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(diagnostic.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch diagnostic.severity {
        case .error:        return "exclamationmark.octagon.fill"
        case .warning:      return "exclamationmark.triangle.fill"
        case .information:  return "info.circle.fill"
        case .hint:         return "lightbulb.fill"
        }
    }

    private var iconColor: Color {
        switch diagnostic.severity {
        case .error:        return .red
        case .warning:      return .orange
        case .information:  return .blue
        case .hint:         return .green
        }
    }
}
