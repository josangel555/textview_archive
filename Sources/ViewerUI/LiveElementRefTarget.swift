import Foundation
import ViewerCore

/// TSK-1256 slice 4 — the LIVE `ElementRefTarget` (the consume side of element
/// references). Wires `ElementRefExecutor`'s typed actions to the running app:
/// the host-routable ones (`.tab` select, `.file` open) drive `DocumentModel`
/// directly; the render-only ones (`.web` editor goto/select, `.ax` native
/// activate) are injected render-bridge closures the app supplies (CM6 cmDispatch
/// + `AXDriverCore` over the live AX tree) and a host test stubs/records.
///
/// Non-isolated (so it satisfies the pure `ElementRefTarget` protocol) but it
/// touches `@MainActor` `DocumentModel`; like `LiveMacroDispatcher`, the model
/// hops are bridged with `MainActor.assumeIsolated` — an element-ref activation
/// always runs on the main thread (a menu/paste handler).
public final class LiveElementRefTarget: ElementRefTarget {
    private let model: DocumentModel
    private let renderGotoWebLine: (String, Int) -> Bool
    private let renderSelectWebNode: (String, String) -> Bool
    private let renderActivateAX: (AXQuery) -> Bool

    public init(
        model: DocumentModel,
        gotoWebLine: @escaping (String, Int) -> Bool,
        selectWebNode: @escaping (String, String) -> Bool,
        activateAX: @escaping (AXQuery) -> Bool
    ) {
        self.model = model
        self.renderGotoWebLine = gotoWebLine
        self.renderSelectWebNode = selectWebNode
        self.renderActivateAX = activateAX
    }

    public func selectTab(id: String) -> Bool {
        let model = self.model   // bind the @MainActor (Sendable) ref; don't send `self`
        return MainActor.assumeIsolated {
            guard let idx = model.tabs.tabs.firstIndex(where: { $0.id.uuidString == id }) else {
                return false
            }
            model.selectTab(at: idx)
            return true
        }
    }

    public func openFile(path: String, line: Int?) -> Bool {
        let model = self.model
        return MainActor.assumeIsolated {
            let expanded = (path as NSString).expandingTildeInPath
            model.open(url: URL(fileURLWithPath: expanded))
            return true
            // The optional line reveal rides the render bridge after the doc
            // loads (a freshly-opened CM6/preview isn't mounted yet) — VM slice.
        }
    }

    public func gotoWebLine(docId: String, line: Int) -> Bool { renderGotoWebLine(docId, line) }
    public func selectWebNode(docId: String, selector: String) -> Bool { renderSelectWebNode(docId, selector) }
    public func activateAX(_ query: AXQuery) -> Bool { renderActivateAX(query) }
}
