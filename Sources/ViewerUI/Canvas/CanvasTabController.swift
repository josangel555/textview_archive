import Foundation
import SwiftUI
import RustCore
import ViewerCore

// Canvas M3.S1 (TSK-1372) — the tab↔engine binding (M3-PLAN §S1). One
// controller per (tab id × canvas doc): opens the document THROUGH THE
// STORE (so the UI and the agent tools share one engine doc + revision
// stream), mounts the CanvasWebViewHost, pushes the full lowering on ready,
// and (from S4 on) translates edit intents into engine ops. Selection is
// controller state — engine-adjacent, never persisted.

/// Lifecycle: created lazily by DocumentModel when a `.canvas` tab enters
/// the `.rendered` lens; dropped when the tab closes.
@MainActor
public final class CanvasTabController: ObservableObject {

    public let tabID: UUID
    public let host: CanvasWebViewHost
    public private(set) var doc: CanvasOpenDocument?
    /// Selection (engine-adjacent controller state; S3 drives the overlay).
    @Published public private(set) var selectedIDs: [String] = []
    /// Mount status the view can observe ("mounting" → "ready" → "mounted").
    @Published public private(set) var phase: Phase = .mounting
    /// Sequence counter for outbound messages.
    private var seq: UInt64 = 0
    /// The engine revision this controller last observed (the write path's
    /// baseRev; conflict recovery refreshes it from the rejection).
    public private(set) var trackedRev: UInt64 = 0
    /// The inspector/layers read model (M3.S8): one parse of the canonical
    /// JSON, refreshed on every revision change. Engine stays the truth.
    @Published public private(set) var outline: CanvasOutlineNode?

    /// True for UI-Design-mode docs (M5.S4) — the shell shows the kit strip
    /// and opens with panels visible. Read once at mount (the mode token is
    /// document-stable).
    @Published public private(set) var isUIDesign: Bool = false

    /// Kit component names available to the insert palette (M5.S4) — the
    /// store's cmp:kit-* definition roots, refreshed with the outline.
    @Published public private(set) var kitComponents: [String] = []

    /// The player's current position + the ids the runtime revealed (M6.S4).
    @Published public private(set) var deckState: DeckState?

    public struct DeckState: Equatable, Sendable {
        public let slide: Int
        public let step: Int
        public let visibleIds: [String]
    }
    /// kind → registry prop specs (parsed once from the vocabulary).
    public private(set) var propSpecs: [String: [CanvasPropSpec]] = [:]

    public enum Phase: Equatable {
        case mounting
        case mounted(nodeCount: Int)
        case failed(String)
    }

    public init(tabID: UUID, fileURL: URL, store: CanvasDocumentStore) {
        self.tabID = tabID
        self.host = CanvasWebViewHost()
        host.onInbound = { [weak self] message in
            self?.handle(message)
        }
        do {
            let opened = try store.open(url: fileURL)
            self.doc = opened
            self.trackedRev = opened.lastKnownRev
            self.propSpecs = CanvasVocabularyIndex.propSpecs(
                fromVocabularyJSON: (try? opened.adapter.vocabulary(asJSON: true)) ?? "")
            self.isUIDesign = CanvasUIDesignMode.isUIDesign(opened)
            refreshOutline()
        } catch {
            self.phase = .failed(String(describing: error))
        }
        host.load()
    }

    /// Re-lower and re-push the whole document (undo, agent co-edit, or
    /// external reload — the S1 refresh primitive; S4 refines to patches).
    public func refresh() {
        guard let doc else { return }
        do {
            seq += 1
            host.send(.setContent(seq: seq, html: try doc.adapter.html()))
            refreshOutline()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    public func teardown() {
        host.teardown()
    }

    // MARK: - selection + read model (M3.S8)

    /// Programmatic selection (the layers tree's click path) — same authority
    /// as a canvas click.
    public func select(_ id: String?) {
        selectedIDs = id.map { [$0] } ?? []
        seq += 1
        if let id {
            host.send(.setSelection(ids: [id]))
        } else {
            host.send(.clearSelection)
        }
    }

    /// Inspector commit: one prop edit lowered through the write path.
    public func setProp(_ id: String, name: String, value: CanvasDocValue) {
        applyGesture([.update(id: id, set: [(name, value)], unset: [])])
    }

    /// Inspector clear: unset one prop.
    public func unsetProp(_ id: String, name: String) {
        applyGesture([.update(id: id, set: [], unset: [name])])
    }

    /// Re-parse the canonical JSON into the outline snapshot.
    func refreshOutline() {
        guard let doc else { return }
        let json = try? doc.adapter.save()
        outline = json.flatMap { try? CanvasOutlineParser.parse($0) }
        kitComponents = json.map { CanvasComponentIndex.kitComponents(fromCanvasJSON: $0) } ?? []
    }

    /// Insert a `use` of a kit component at the current insertion point
    /// (M5.S4) — through the ordinary op path (the same insert the agent's
    /// `use` DSL lands). Returns nothing; state flows through refreshOutline.
    public func insertKitComponent(_ name: String) {
        let ref = name.hasPrefix("cmp:") ? name : "cmp:" + name
        applyGesture([.insert(
            id: nil, kind: "component", parent: insertionParent(),
            pos: .last, props: [("ref", .str(ref))])])
    }

    /// The best parent for an insert: the selected node if it can contain
    /// children (a frame/artboard), else the first artboard, else the root.
    func insertionParent() -> String {
        if let sel = selectedIDs.first, let root = outline,
            let node = CanvasOutlineParser.find(sel, in: root), node.kind == "frame" {
            return sel
        }
        if let root = outline, let board = Self.firstArtboard(root) { return board.id }
        return outline?.id ?? "pg:1"
    }

    static func firstArtboard(_ node: CanvasOutlineNode) -> CanvasOutlineNode? {
        if node.kind == "frame",
            node.props.contains(where: { $0.name == "role" && $0.value == .str("artboard") }) {
            return node
        }
        for child in node.children {
            if let hit = firstArtboard(child) { return hit }
        }
        return nil
    }

    // MARK: - the write path (M3.S4)

    /// Apply a human gesture as engine ops — THE SAME path the agent uses.
    /// On a revision conflict (an agent edited concurrently): adopt the
    /// engine's currentRev and retry ONCE; a second failure falls back to a
    /// full re-lower (state is never guessed).
    func applyGesture(_ ops: [CanvasDocOp], isRetry: Bool = false) {
        guard let doc else { return }
        do {
            let applied = try doc.adapter.apply(baseRev: trackedRev, ops)
            trackedRev = applied.rev
            doc.noteRevision(applied.rev)
            seq += 1
            host.send(.applyPatches(seq: seq, patches: applied.patches))
            refreshOutline()
            requestMeasuredLint()
        } catch let rejection as CanvasRejection {
            if rejection.kind == "conflict", !isRetry {
                trackedRev = rejection.currentRev
                applyGesture(ops, isRetry: true)
            } else {
                NSLog("canvas gesture rejected (%@): %@ — re-lowering",
                      rejection.kind, rejection.detail)
                refresh()
            }
        } catch {
            NSLog("canvas gesture failed: %@", String(describing: error))
            refresh()
        }
    }

    /// Enter/exit deck player mode (M6.S4).
    public func setDeckMode(_ on: Bool) {
        host.send(.setDeckMode(on: on))
    }

    /// Go to a slide/step in the player (M6.S4).
    public func deckGoto(slide: Int, step: Int) {
        host.send(.deckGoto(slide: slide, step: step))
    }

    /// Ask the runtime for the measured lint stage (results cache via the
    /// inbound handler; also re-requested after every gesture apply).
    public func requestMeasuredLint() {
        seq += 1
        host.send(.measureLint(replyId: seq))
    }

    /// Engine undo (⌘Z in the surface) + full re-lower (undo is a re-lower
    /// in v1 per M1.S9).
    public func undoLastBatch() {
        guard let doc else { return }
        do {
            if let rev = try doc.adapter.undo() {
                trackedRev = rev
                doc.noteRevision(rev)
                refresh()
                refreshOutline()
            }
        } catch {
            NSLog("canvas undo failed: %@", String(describing: error))
        }
    }

    // MARK: - inbound

    private func handle(_ message: CVInboundMessage) {
        switch message {
        case .ready:
            refresh()
        case .contentSet(_, let nodeCount, _):
            phase = .mounted(nodeCount: nodeCount)
            requestMeasuredLint()
        case .nodeClicked(let id, _):
            // S3 drives the overlay; S1 just tracks the selection state.
            selectedIDs = [id]
            seq += 1
            host.send(.setSelection(ids: selectedIDs))
        case .escapePressed:
            selectedIDs = []
            seq += 1
            host.send(.clearSelection)
        case .applied, .geometry, .text:
            break // patch acks / query replies (S7 latency wiring)
        case .textEdited(let id, let text):
            applyGesture([.update(id: id, set: [("text", .str(text))], unset: [])])
        case .dragEnded(let id, let parent, let beforeId):
            let pos: CanvasDocPosition = beforeId.map { .before($0) } ?? .last
            applyGesture([.move(id: id, parent: parent, pos: pos)])
        case .deletePressed:
            guard !selectedIDs.isEmpty else { break }
            applyGesture(selectedIDs.map { .remove(id: $0) })
            selectedIDs = []
            seq += 1
            host.send(.clearSelection)
        case .undoRequested:
            undoLastBatch()
        case .deckStateChanged(let slide, let step, let visibleIds):
            deckState = DeckState(slide: slide, step: step, visibleIds: visibleIds)
        case .measuredLint(_, let findings):
            // Cache on the STORE doc so the sync canvas_lint tool can merge
            // the measured stage (M4.S9; the MCP dispatch cannot await a
            // webview round trip — the cache decouples them).
            doc?.cacheMeasuredLint(findings.map {
                CanvasDocLint(severity: $0.severity, code: $0.code,
                              id: $0.id, message: $0.message)
            })
        case .error(let message):
            NSLog("canvas runtime error: %@", message)
        case .unsupportedVersion(let v):
            phase = .failed("canvas runtime speaks v\(v); app speaks v\(CVProtocol.currentVersion)")
        }
    }
}

/// The `.rendered` lens content for a `.canvas` tab.
public struct CanvasTabView: View {
    @ObservedObject var controller: CanvasTabController

    public init(controller: CanvasTabController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            // M5.S4: the kit strip — UI-Design docs only (Tier 1's ONLY new
            // chrome). Insert palette over the SAME op path as the agent.
            if controller.isUIDesign {
                CanvasKitStripView(controller: controller)
            }
            panels
        }
    }

    private var panels: some View {
        HSplitView {
            // M3.S8: layers | surface | inspector — both panels read the
            // controller's outline; edits lower through the op path.
            CanvasLayersView(controller: controller)
            ZStack {
                CanvasSurfaceView(host: controller.host)
                if case .failed(let why) = controller.phase {
                    // Occlusion rule (LESSONS/TSK-488): the SwiftUI overlay must
                    // composite ABOVE the WKWebView representable.
                    Text("Canvas failed: \(why)")
                        .padding(8)
                        .background(.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .compositingGroup()
                        .zIndex(1)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .accessibilityIdentifier("mdv.canvas.surface")
            CanvasInspectorView(controller: controller)
        }
    }
}

/// M5.S4 — the kit strip: a thin insert palette listing the doc's kit
/// components; click = `use` at the insertion point through the controller's
/// op path. Shown only for UI-Design docs.
struct CanvasKitStripView: View {
    @ObservedObject var controller: CanvasTabController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Insert")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(controller.kitComponents, id: \.self) { name in
                    Button(name.replacingOccurrences(of: "kit-", with: "")) {
                        controller.insertKitComponent(name)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("mdv.canvas.kit.\(name)")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .accessibilityIdentifier("mdv.canvas.kitstrip")
    }
}
