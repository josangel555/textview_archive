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

    /// TSK-1417 — open the RSS/feed reader in a fresh hosted tab. The feature
    /// was fully built + host-tested (FeedReaderView + parser/fetcher/
    /// subscription store/refresh scheduler/OPML) but ORPHANED — nothing
    /// instantiated it, so it was unreachable. Owner chose FINISH (wire it).
    /// Subscriptions + read-state persist to disk via `FeedSubscriptionStore`
    /// (feeds.json / feed-read-state.json under Application Support), so a fresh
    /// per-open model reloads them; `@ObservedObject` retains the model for the
    /// hosted view's lifetime.
    @discardableResult
    public func openFeedReader() -> UUID {
        let store = FeedSubscriptionStore(
            subscriptionsURL: FeedSubscriptionStore.defaultSubscriptionsURL(),
            readStateURL: FeedSubscriptionStore.defaultReadStateURL())
        let model = FeedReaderViewModel(store: store)
        return openHostedView(title: "Feeds", rootView: FeedReaderView(model: model))
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


// Canvas rendered-lens controllers (M3.S1, TSK-1372) — one per canvas tab,
// created lazily when the tab enters `.rendered`, dropped on tab close
// (`dropCanvasController` is called from the tab-close path alongside the
// other per-tab caches).
extension DocumentModel {

    /// Lazily create (or return) the canvas controller for a `.canvas` tab.
    public func canvasController(forTab tabID: UUID, fileURL: URL) -> CanvasTabController {
        if let existing = canvasControllers[tabID] { return existing }
        let controller = CanvasTabController(
            tabID: tabID, fileURL: fileURL, store: automationCanvasStore)
        canvasControllers[tabID] = controller
        return controller
    }

    /// Drop (and tear down) the controller when its tab closes.
    public func dropCanvasController(forTab tabID: UUID) {
        canvasControllers[tabID]?.teardown()
        canvasControllers[tabID] = nil
    }
}
