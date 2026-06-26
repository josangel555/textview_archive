import Foundation

// TSK-1256 slice 3 (executor dispatch) — drive an ElementRef to its action.
//
// The executor maps an ElementRef's resolution (slice 2) to EXACTLY ONE call on
// an `ElementRefTarget`, forwarding the params. Splitting the dispatch (pure,
// here) from the target (the live AppKit/WebView/AX wiring) keeps this
// host-testable — a mock target records which action fired with which params, so
// a regression (a kind dispatched to the wrong action) fails on the host gate —
// while the LIVE target (ViewerUI) does the render/VM work: select the tab
// (DocumentModel), open + reveal the file, cmDispatch the WebView goto/select,
// and activate a native element through AXDriverCore.
//
// Mirrors the macro `MacroDispatcher` seam (TSK-1162): one pure dispatch switch,
// an injected do-er, host-testable without a window.

/// Performs the concrete action an `ElementRef` resolves to. The live
/// implementation lives in ViewerUI (it needs DocumentModel + the WebView/AX
/// render bridge); a recording mock stands in for host tests. Each method
/// returns whether the action succeeded (e.g. the tab id / file path resolved).
public protocol ElementRefTarget: AnyObject {
    func selectTab(id: String) -> Bool
    func openFile(path: String, line: Int?) -> Bool
    func gotoWebLine(docId: String, line: Int) -> Bool
    func selectWebNode(docId: String, selector: String) -> Bool
    func activateAX(_ query: AXQuery) -> Bool
}

public enum ElementRefExecutor {
    /// Dispatch `ref` to exactly one `target` action (via `ref.resolution`).
    /// Returns the target's success flag.
    @discardableResult
    public static func execute(_ ref: ElementRef, on target: ElementRefTarget) -> Bool {
        switch ref.resolution {
        case .selectTab(let id):
            return target.selectTab(id: id)
        case .openFile(let path, let line):
            return target.openFile(path: path, line: line)
        case .gotoWebLine(let docId, let line):
            return target.gotoWebLine(docId: docId, line: line)
        case .selectWebNode(let docId, let selector):
            return target.selectWebNode(docId: docId, selector: selector)
        case .activateAX(let query):
            return target.activateAX(query)
        }
    }
}
