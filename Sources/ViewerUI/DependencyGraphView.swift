import SwiftUI
import ViewerCore

/// Visualizes a project's dependency graph (TSK-280) — file→file import edges
/// or `Package.swift` package dependencies. The extraction + layout are pure
/// `ViewerCore` logic (`DependencyGraph` / `DependencyGraphLayout`, both
/// host-tested); this view only paints the laid-out result and routes clicks.
///
/// Render-only by design: it derives node positions from the layout engine
/// inside a `GeometryReader` and draws nodes + directed edges with `Canvas`.
/// Visual/interaction validation is VM-only (host can't validate pixels), but
/// the model + layout it consumes are regression-guarded on the host.
public struct DependencyGraphView: View {

    private let graph: DependencyGraph.Graph
    /// Invoked with a file node's URL when its node is clicked (open the file).
    private let onOpenFile: (URL) -> Void

    @State private var selectedNodeID: String?

    public init(
        graph: DependencyGraph.Graph,
        onOpenFile: @escaping (URL) -> Void = { _ in }
    ) {
        self.graph = graph
        self.onOpenFile = onOpenFile
    }

    public var body: some View {
        if graph.isEmpty {
            ContentUnavailablePlaceholder()
        } else {
            GeometryReader { geo in
                let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 28, dy: 28)
                let positions = DependencyGraphLayout.forceDirected(graph, in: bounds)
                let posByID = Dictionary(
                    uniqueKeysWithValues: positions.map { ($0.id, $0.point) })

                ZStack {
                    edgeCanvas(positions: posByID)
                    ForEach(graph.nodes) { node in
                        if let p = posByID[node.id] {
                            nodeLabel(node)
                                .position(p)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    // MARK: - Edges

    @ViewBuilder
    private func edgeCanvas(positions: [String: CGPoint]) -> some View {
        Canvas { ctx, _ in
            for edge in graph.edges {
                guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                let highlighted = selectedNodeID == edge.from || selectedNodeID == edge.to
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(
                    path,
                    with: .color(highlighted ? .accentColor : Color.secondary.opacity(0.35)),
                    lineWidth: highlighted ? 1.8 : 1.0)
                drawArrowHead(ctx, from: a, to: b, color:
                    highlighted ? .accentColor : Color.secondary.opacity(0.45))
            }
        }
    }

    /// Small filled triangle near `to`, pointing from `from` → `to`.
    private func drawArrowHead(
        _ ctx: GraphicsContext, from: CGPoint, to: CGPoint, color: Color
    ) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / len, uy = dy / len
        // Pull the tip back so it sits at the node's rim, not its centre.
        let tipBack: CGFloat = 16
        let tip = CGPoint(x: to.x - ux * tipBack, y: to.y - uy * tipBack)
        let size: CGFloat = 6
        let left = CGPoint(x: tip.x - ux * size - uy * size * 0.6,
                           y: tip.y - uy * size + ux * size * 0.6)
        let right = CGPoint(x: tip.x - ux * size + uy * size * 0.6,
                            y: tip.y - uy * size - ux * size * 0.6)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    // MARK: - Nodes

    @ViewBuilder
    private func nodeLabel(_ node: DependencyGraph.Node) -> some View {
        let selected = selectedNodeID == node.id
        HStack(spacing: 4) {
            Image(systemName: icon(for: node.kind))
                .font(.system(size: 9))
            Text(node.label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(fill(for: node.kind, selected: selected)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                              lineWidth: selected ? 1.5 : 0.8))
        .foregroundStyle(node.kind == .external ? Color.secondary : Color.primary)
        .help(node.id)
        .onTapGesture {
            selectedNodeID = node.id
            if let url = node.url { onOpenFile(url) }
        }
    }

    private func icon(for kind: DependencyGraph.Node.Kind) -> String {
        switch kind {
        case .file: return "doc.text"
        case .external: return "shippingbox"
        case .package: return "cube.box"
        }
    }

    private func fill(for kind: DependencyGraph.Node.Kind, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.18) }
        switch kind {
        case .file: return Color(NSColor.controlBackgroundColor)
        case .external: return Color.secondary.opacity(0.12)
        case .package: return Color.accentColor.opacity(0.10)
        }
    }
}

/// Empty-state placeholder (no `ContentUnavailableView` to keep the
/// deployment target unconstrained).
private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No dependencies found")
                .font(.headline)
            Text("Open a project with source files or a Package.swift.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
