import SwiftUI
import ViewerCore

/// TSK-1438 — the live Markdown outline panel: a filterable heading list with
/// click-to-jump and a scroll-following highlight, bound to the host-tested
/// `MarkdownOutlineModel`. Mirrors the proven `LSPOutlineSection` scaffolding.
///
/// Self-contained on purpose: it renders its own lightweight header (no
/// `SidebarPanelKind` drag coupling yet) so it can be mounted without
/// perturbing the sidebar registry / pinned panel-kind contracts. Wiring it
/// in as a first-class `.markdownOutline` sidebar panel (registry order,
/// redock, persisted height) is the on-screen tail tracked on the ticket.
struct MarkdownOutlineSection: View {

    @ObservedObject var model: MarkdownOutlineModel
    /// Jump the active document to a 1-based source line (host wires this to
    /// `openPath(_:atLine:)` / `scrollSource(toLine:)`).
    let onJump: (Int) -> Void
    var uiSize: (CGFloat) -> CGFloat = { $0 }

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                if model.isEmpty {
                    SidebarEmptyPlaceholder(message: "No headings.")
                } else {
                    filterField
                    ScrollView { rows }
                }
            }
        }
        .accessibilityIdentifier("mdv.markdownOutline")
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: uiSize(9), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Outline")
                    .font(.system(size: uiSize(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.isEmpty {
                    Text("\(model.headings.count)")
                        .font(.system(size: uiSize(10), weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, uiSize(8))
        .padding(.vertical, uiSize(4))
        .accessibilityIdentifier("mdv.markdownOutline.header")
    }

    private var filterField: some View {
        HStack(spacing: uiSize(4)) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: uiSize(10)))
                .foregroundStyle(.tertiary)
            TextField("Filter headings", text: $model.filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: uiSize(11)))
                .accessibilityIdentifier("mdv.markdownOutline.filter")
        }
        .padding(.horizontal, uiSize(8))
        .padding(.vertical, uiSize(3))
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.visibleRows, id: \.index) { row in
                MarkdownOutlineRow(
                    heading: row.heading,
                    isCurrent: row.index == model.currentIndex,
                    uiSize: uiSize)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let line = model.select(index: row.index) { onJump(line) }
                    }
            }
        }
    }
}

private struct MarkdownOutlineRow: View {
    let heading: MarkdownHeading
    let isCurrent: Bool
    var uiSize: (CGFloat) -> CGFloat = { $0 }

    var body: some View {
        HStack(spacing: 0) {
            // Indent by heading depth (level 1 = flush left).
            Spacer().frame(width: uiSize(CGFloat(max(0, heading.level - 1)) * 12))
            Text(heading.title)
                .font(.system(size: uiSize(12),
                              weight: heading.level == 1 ? .medium : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, uiSize(8))
        .padding(.vertical, uiSize(2))
        .background(isCurrent
            ? Color.accentColor.opacity(0.12)
            : Color.clear)
    }
}
