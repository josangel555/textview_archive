import SwiftUI
import ViewerCore

// Canvas M3.S8 (TSK-1379) — the layers tree + inspector panels. Both read
// the controller's outline snapshot (one canonical-JSON parse per revision);
// every edit lowers through the controller's op path. No parallel stores.

/// The document tree with two-way selection sync.
struct CanvasLayersView: View {
    @ObservedObject var controller: CanvasTabController

    var body: some View {
        List {
            if let root = controller.outline {
                CanvasLayersRow(controller: controller, node: root, depth: 0)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 140)
        .accessibilityIdentifier("mdv.canvas.layers")
    }
}

private struct CanvasLayersRow: View {
    @ObservedObject var controller: CanvasTabController
    let node: CanvasOutlineNode
    let depth: Int

    private var isSelected: Bool { controller.selectedIDs.contains(node.id) }

    var body: some View {
        Button {
            controller.select(node.id)
        } label: {
            HStack(spacing: 4) {
                Text(node.kind).bold()
                Text(node.id).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, CGFloat(depth) * 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.25) : nil)
        .accessibilityIdentifier("mdv.canvas.layer.\(node.id)")
        ForEach(node.children) { child in
            CanvasLayersRow(controller: controller, node: child, depth: depth + 1)
        }
    }
}

/// The registry-driven inspector for the current selection.
struct CanvasInspectorView: View {
    @ObservedObject var controller: CanvasTabController
    @State private var drafts: [String: String] = [:]

    private var selected: CanvasOutlineNode? {
        guard let id = controller.selectedIDs.first,
            let root = controller.outline else { return nil }
        return CanvasOutlineParser.find(id, in: root)
    }

    var body: some View {
        ScrollView {
            if let node = selected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(node.kind).bold()
                        Text(node.id).foregroundStyle(.secondary)
                    }
                    Divider()
                    // Registry-driven rows: the kind's ALLOWED props, current
                    // values from the outline, edits through the op path.
                    ForEach(controller.propSpecs[node.kind] ?? [], id: \.name) { spec in
                        propRow(node: node, spec: spec)
                    }
                }
                .padding(8)
            } else {
                Text("No selection")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(minWidth: 180)
        .accessibilityIdentifier("mdv.canvas.inspector")
        .onChange(of: controller.selectedIDs) { _, _ in drafts = [:] }
    }

    @ViewBuilder
    private func propRow(node: CanvasOutlineNode, spec: CanvasPropSpec) -> some View {
        let current = node.props.first { $0.name == spec.name }?.value
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.name).font(.caption).foregroundStyle(.secondary)
            TextField(
                spec.note ?? "",
                text: Binding(
                    get: { drafts[spec.name] ?? current?.display ?? "" },
                    set: { drafts[spec.name] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { commit(node: node, spec: spec) }
            .accessibilityIdentifier("mdv.canvas.inspector.\(spec.name)")
        }
    }

    private func commit(node: CanvasOutlineNode, spec: CanvasPropSpec) {
        guard let draft = drafts[spec.name] else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            controller.unsetProp(node.id, name: spec.name)
        } else {
            controller.setProp(node.id, name: spec.name, value: Self.parse(trimmed))
        }
        drafts[spec.name] = nil
    }

    /// Inspector value parsing mirrors the DSL's: `$path` = token,
    /// numbers = num, true/false = bool, anything else = string.
    static func parse(_ text: String) -> CanvasDocValue {
        if text.hasPrefix("$") { return .token(String(text.dropFirst())) }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let n = Double(text) { return .num(n) }
        return .str(text)
    }
}
