import SwiftUI
import ViewerCore

// View-hosting tabs (TSK-1110 SRP slice; WAVE 2b item 1) — the methods that open
// and resolve tabs rendering an arbitrary embedded SwiftUI `rootView`. The
// `hostedViews` registry stays a stored property on DocumentModel (extensions
// can't add storage); only the open/resolve logic lives here. Behavior-preserving
// move out of DocumentModel.swift.
extension DocumentModel {

    /// The embedded view for `id`, or `nil` if no such hosted tab exists.
    /// `ContentView` calls this for the `.hostedView` document state.
    public func hostedView(forID id: UUID) -> AnyView? { hostedViews[id] }

    /// TSK-721 — open the in-app HTTP request tool in a fresh hosted tab.
    /// The view is self-contained (owns its `HTTPClientViewModel`); all
    /// request logic lives in the pure, host-tested `HTTPClientCore`.
    @discardableResult
    public func openHTTPClient() -> UUID {
        openHostedView(title: "HTTP Request", rootView: HTTPClientView())
    }

    /// Open a new tab that hosts an arbitrary SwiftUI `rootView`. Always a
    /// fresh tab (these aren't file-backed, so there's nothing to reveal /
    /// dedup against). Returns the tab id so callers can identify it. The
    /// view is rendered by `ContentView` via `hostedView(forID:)`; closing
    /// the tab drops the registered view.
    @discardableResult
    public func openHostedView<V: View>(title: String, rootView: V) -> UUID {
        let hostID = UUID()
        hostedViews[hostID] = AnyView(rootView)
        let tab = Tab(state: .hostedView(id: hostID, title: title), viewMode: .source)
        tabCoordinator.append(tab)
        updateDerived()
        return hostID
    }
}
