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
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    public func teardown() {
        host.teardown()
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

    /// Engine undo (⌘Z in the surface) + full re-lower (undo is a re-lower
    /// in v1 per M1.S9).
    public func undoLastBatch() {
        guard let doc else { return }
        do {
            if let rev = try doc.adapter.undo() {
                trackedRev = rev
                doc.noteRevision(rev)
                refresh()
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
        .accessibilityIdentifier("mdv.canvas.surface")
    }
}
