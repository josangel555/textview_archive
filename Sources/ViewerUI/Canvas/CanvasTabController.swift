import Foundation
import SwiftUI
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
            self.doc = try store.open(url: fileURL)
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
            break // S4+ consumers
        case .textEdited, .dragEnded:
            break // S4/S6 wire these to ops
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
