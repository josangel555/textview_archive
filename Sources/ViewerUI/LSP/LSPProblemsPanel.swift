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
    /// Closure that scales a base font size by the active UI-zoom
    /// factor. Threaded from the host (`DocumentModel.uiSize(_:)`) so
    /// the section's header tracks user-controlled UI zoom. Defaults
    /// to identity for call sites without a document model. Not
    /// `@Sendable` — the host's `uiSize` is `@MainActor`-isolated.
    let uiSize: (CGFloat) -> CGFloat
    /// Reports whether the *active* file has a registered LSP language
    /// but no diagnostics in the store — i.e. it was never analyzed by
    /// a language server in this view. When true, the empty body must
    /// NOT read as a green "no problems": Source view never drives the
    /// `didOpen`/`didChange` that makes the server publish diagnostics
    /// (only the Editor / Outline paths do), so an empty store for a
    /// broken `.swift` file is "not analyzed", not "clean". Threaded
    /// from the host; defaults to `false` (the legacy all-clear copy)
    /// for call sites without a document model. See UAT LSP-01.
    let activeFileUnanalyzed: () -> Bool

    public init(
        store: LSPDiagnosticsStore,
        onJump: @escaping (URL, Int) -> Void,
        uiSize: @escaping (CGFloat) -> CGFloat = { $0 },
        activeFileUnanalyzed: @escaping () -> Bool = { false }
    ) {
        self.store = store
        self.onJump = onJump
        self.uiSize = uiSize
        self.activeFileUnanalyzed = activeFileUnanalyzed
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
                                .font(.system(size: uiSize(11)))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { (_, row) in
                                // UIRESP-07: a Button (rather than a bare
                                // `.onTapGesture` on an inert HStack) gives
                                // the row hover feedback + a pointing-hand
                                // cursor + proper button a11y semantics.
                                Button {
                                    onJump(row.url, row.diagnostic.range.start.line + 1)
                                } label: {
                                    ProblemRow(url: row.url, diagnostic: row.diagnostic,
                                               uiSize: uiSize)
                                }
                                .buttonStyle(RowHoverButtonStyle(cornerRadius: 0))
                                .accessibilityLabel(accessibilityLabel(for: row))
                                .accessibilityIdentifier(
                                    "mdv.problems.row.\(row.url.lastPathComponent):\(row.diagnostic.range.start.line)")
                            }
                        }
                    }
                }
                .sidebarSectionBodyFrame()
            }
        }
        // Apply the standard section chrome (subtle bg tint + outer
        // vertical padding) so PROBLEMS terminates with the same
        // breathing room as BOOKMARKS / SEARCH / GIT. Without this
        // the section ended flush against the next divider — looked
        // unfinished compared to its neighbours.
        .sidebarSectionContainer()
        .accessibilityIdentifier("mdv.problems")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                SidebarSectionHeaderLabel(
                    title: "Problems",
                    isExpanded: isExpanded,
                    uiSize: uiSize,
                    dragKind: .lspProblems
                )
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
                    .font(.system(size: uiSize(10)))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by severity")
            .accessibilityIdentifier("mdv.problems.filter")
        }
        .sidebarHeaderRow(uiSize: uiSize)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: uiSize(9), weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, uiSize(5))
            .padding(.vertical, uiSize(1))
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
            // LSP-01: don't claim a clean bill of health for a file the
            // language server was never asked about. Source view never
            // sends didOpen/didChange, so diagnostics never get computed
            // — an empty store for an LSP-supported active file means
            // "not analyzed here", not "no problems". Say so honestly
            // rather than presenting a falsely-reassuring green all-clear.
            if activeFileUnanalyzed() {
                return "Not analyzed. Open in Editor to see problems."
            }
            return "No problems detected."
        }
        return "No problems match this filter."
    }

    /// VoiceOver label for a problem row: spells out the severity (the
    /// icon-only glyph is otherwise inaudible), file, 1-based line, and
    /// message. e.g. "Error in Foo.swift line 42: missing semicolon".
    private func accessibilityLabel(for row: (url: URL, diagnostic: LSPDiagnostic)) -> String {
        let severity: String
        switch row.diagnostic.severity {
        case .error:       severity = "Error"
        case .warning:     severity = "Warning"
        case .information: severity = "Info"
        case .hint:        severity = "Hint"
        }
        let line = row.diagnostic.range.start.line + 1
        return "\(severity) in \(row.url.lastPathComponent) line \(line): \(row.diagnostic.message)"
    }
}

private struct ProblemRow: View {
    let url: URL
    let diagnostic: LSPDiagnostic
    /// UX-F (#228): zoom-scale helper threaded from `LSPProblemsPanel`
    /// (`DocumentModel.uiSize`). Defaults to identity for previews.
    var uiSize: (CGFloat) -> CGFloat = { $0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: uiSize(6)) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: uiSize(11)))
                .frame(width: uiSize(14))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: uiSize(4)) {
                    Text(url.lastPathComponent)
                        .font(.system(size: uiSize(12), weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(":\(diagnostic.range.start.line + 1)")
                        .font(.system(size: uiSize(10), design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let source = diagnostic.source {
                        Text("[\(source)]")
                            .font(.system(size: uiSize(9)))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(diagnostic.message)
                    .font(.system(size: uiSize(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, uiSize(10))
        .padding(.vertical, uiSize(4))
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
