import Foundation
import Combine
import ViewerKit
import ViewerCore

/// Owns the open-tab list, the selection, and the six per-tab caches
/// that follow tab identity (CSV filter state, HEX bytes-per-row,
/// language override, formatted-flag set, formatted-text cache,
/// editor buffers). Extracted from `DocumentModel` so that views
/// observing tabs (TabBar, content tree) don't pay for unrelated
/// `DocumentModel` mutations (sidebar churn, recents updates, etc.)
/// and inversely so that mutations of unrelated DocumentModel slices
/// don't re-render every tab consumer.
///
/// Precedent: `FindCoordinator` (same shape — child ObservableObject
/// hung off DocumentModel via `tabCoordinator`, forwarders on the
/// parent so call sites in views / tests remain unchanged).
///
/// Split status: `splitURL` lives here too because it's part of the
/// "what's currently on screen" surface; the split pane is a sibling
/// view of the active tab. The `closeSplit / toggleSplit` family is
/// owned alongside.
///
/// `materializeTasks` (lazy file-read Tasks keyed by tab id) is
/// coordinator-owned for the same reason as the close paths: cancel
/// is fan-out from a single close site and must follow the tabs map
/// 1:1.
///
/// Not moved here (yet): `editorCursorByTab`, `editorScrollByTab`,
/// `pendingEditorDiagnostics`. Those go to the upcoming
/// `EditorCoordinator`. Likewise `highlightCaches` (per-tab actor
/// map, but conceptually a highlight subsystem concern) and
/// `renderedHTMLCache` (keyed by `RenderedHTMLKey`, not raw UUID).
///
/// Cleanup discipline: all three close paths (`closeTab`,
/// `closeOtherTabs`, `closeTabsToRight`) MUST funnel through
/// `cleanupAfterClose(id:)` so the six dicts stay in lock-step with
/// `tabs`. The previous in-line 6-line cleanup blocks were repeated
/// in each path and silently diverged as fields were added; folding
/// them here closes that gap.
@MainActor
public final class TabCoordinator: ObservableObject {

    // MARK: - Core state

    /// Ordered list of open tabs plus selected index. Mutated only
    /// through the methods below so derived state (`openTabURLs`)
    /// stays in sync.
    @Published public private(set) var tabs: TabsState = .init()

    /// O(1)-contains set of URLs currently open in any tab. Maintained
    /// after every tabs mutation. Sidebar uses this to render
    /// "open elsewhere" indicators without scanning `tabs.tabs` per row.
    @Published public private(set) var openTabURLs: Set<URL> = []

    // MARK: - Per-tab dicts (the six pruned in every close path)

    /// Per-tab CSV filter state. Persists across tab switches so the
    /// user doesn't lose their filter when navigating away and back.
    /// Keyed by tab id.
    @Published public private(set) var csvFilterStates: [UUID: CSVFilterState] = [:]

    /// Per-tab HEX viewer bytes-per-row. Falls back to the global
    /// default in PreferencesStore. Not persisted across app
    /// relaunches — intentional: globally changing the default is
    /// the durable knob; per-tab is a session-scoped override.
    @Published public private(set) var hexBytesPerRow: [UUID: Int] = [:]

    /// Per-tab override of the auto-detected language. Keyed by Tab.id
    /// so two tabs of the same file can have independent overrides.
    @Published public private(set) var languageOverrides: [UUID: HighlightLanguage] = [:]

    /// Tab.id's the user has toggled into "formatted" (pretty-printed)
    /// view. Keyed by Tab.id (not URL) so two tabs of the same file
    /// have independent format state.
    @Published public private(set) var formattedTabIDs: Set<UUID> = []

    /// Memoized pretty-printer output per tab id. Bounded by
    /// `formattedTextCacheMax`; eviction is insertion-order.
    ///
    /// RWC-2 / TD-09 (2026-05-30): the entry carries the source
    /// `modifiedTime` alongside `sourceLength`, and the hit guard
    /// compares BOTH. The prior length-only key served STALE pretty-
    /// printed output when an edit/reload kept the byte length identical
    /// (`{"a":1}` → `{"b":2}` reformats the same length): `sourceLength`
    /// matched, so the cache returned the formatting of the OLD bytes.
    /// mtime is the same invalidation channel the rendered-HTML and
    /// highlight caches use — O(1), captured at load, nanosecond-
    /// resolution on APFS.
    ///
    /// `formattedLength` is the utf8 length of the *formatted output*
    /// (not the source). It's cached here so `displayText`'s highlight
    /// path can form its cache key without re-walking the formatted
    /// string on every body re-eval (PERF-04).
    public struct FormattedCacheEntry: Sendable {
        public let sourceLength: Int
        public let modifiedTime: Date?
        public let formatted: String
        public let formattedLength: Int
        public init(
            sourceLength: Int, modifiedTime: Date?,
            formatted: String, formattedLength: Int
        ) {
            self.sourceLength = sourceLength
            self.modifiedTime = modifiedTime
            self.formatted = formatted
            self.formattedLength = formattedLength
        }
    }
    public private(set) var formattedTextCache: [UUID: FormattedCacheEntry] = [:]
    public private(set) var formattedTextCacheOrder: [UUID] = []
    public static let formattedTextCacheMax = 8

    /// One EditorBuffer per tab id. Lazily seeded by
    /// `editorBuffer(forTabID:)` or `ensureEditorBuffer(for:tabID:)`.
    /// Dropped in the close paths (and on user-confirmed discard).
    @Published public private(set) var editorBuffers: [UUID: EditorBuffer] = [:]

    // MARK: - Materialize tasks (lazy file reads, keyed by tab id)

    /// In-flight materialization Tasks keyed by tab id. Cancelled in
    /// every close path so a doomed tab's still-running file read
    /// doesn't waste I/O.
    private var materializeTasks: [UUID: Task<Void, Never>] = [:]

    /// External cleanup hooks invoked from `cleanupAfterClose(id:)` for
    /// every close path. Lets non-tab coordinators (EditorCoordinator —
    /// cursor / scroll / pending-diagnostics dicts) drain their per-tab
    /// state without piling more fields into this coordinator's
    /// alphabetical removeValue list. Invocation order is registration
    /// order; called inside the same main-actor turn as the built-in
    /// drains so observers see a consistent post-close state.
    ///
    /// Hooks must be cheap, synchronous, and only touch their own
    /// state — fanning out further work risks the same divergence the
    /// folded `cleanupAfterClose` was meant to prevent.
    private var closeHooks: [(UUID) -> Void] = []

    /// Register a cleanup hook that fires on every tab close (single
    /// close, close-others, close-to-right). Idempotent storage — the
    /// caller is responsible for not registering the same closure
    /// twice. EditorCoordinator registers exactly once on init.
    public func addCloseHook(_ hook: @escaping (UUID) -> Void) {
        closeHooks.append(hook)
    }

    // MARK: - Split pane

    /// URL displayed in the right-hand secondary pane, or nil when
    /// split is closed. The secondary pane is read-only and stateless
    /// — no tab bar, no per-tab view-mode — it just shows whatever
    /// file the user pinned there. Lives on the tab coordinator
    /// because it shares the "what's on screen" lifecycle.
    @Published public var splitURL: URL? = nil

    // MARK: - Editor panes (I-21 S2, owner 2026-08-11)

    /// The pane overlay: which tab ids render in which pane's strip, each
    /// pane's own selection, and the focused pane. The flat `tabs` store
    /// stays the OWNER of tabs (and, until S3 renders per-pane, of the
    /// app-wide selection); `syncPaneAssignment()` reconciles the overlay
    /// after every store mutation, so every existing tab path keeps
    /// working untouched. Single-pane (un-split) the overlay mirrors the
    /// store byte-for-byte — the pre-panes world is unchanged.
    @Published public private(set) var paneAssignment = PaneAssignment()

    /// S4c — the cross-pane geometry channel (strip drop targets +
    /// content click-focus rects). Coordinator-owned so every pane strip
    /// and the click monitor share one instance per window.
    public let paneDropChannel = PaneDropChannel()

    /// Reconcile the overlay with the store: adopt `opened` (a just-added
    /// tab joins the focused pane), drop closed ids, re-validate
    /// selections, mirror the store's selection onto the focused pane,
    /// and keep single-pane order in lockstep. Equality-guarded.
    private func syncPaneAssignment(opened newTabID: UUID? = nil) {
        var next = paneAssignment
        if let id = newTabID, next.pane(containing: id) == nil {
            next.didOpenTab(id: id)
        }
        next = next.normalized(against: tabs.tabs.map(\.id))
        if let sel = tabs.selected?.id, next.pane(containing: sel) != nil {
            next.selectTab(id: sel)
        }
        next.mirrorSinglePane(order: tabs.tabs.map(\.id),
                              selected: tabs.selected?.id)
        if next != paneAssignment { paneAssignment = next }
        // MRU history (owner 2026-08-27): every mutation path funnels
        // through here, so the front of the history is always the current
        // selection and the entry behind it is "the previously selected".
        if let sel = tabs.selected?.id, selectionHistory.first != sel {
            selectionHistory.removeAll { $0 == sel }
            selectionHistory.insert(sel, at: 0)
            if selectionHistory.count > Self.selectionHistoryCap {
                selectionHistory.removeLast()
            }
        }
    }

    /// Split: a new focused pane after the current one (right in a
    /// horizontal run, below in a vertical one — `direction` picks the
    /// axis on the first split). `movingSelected` tears the store-selected
    /// tab into it (the selection is unchanged — the same tab stays
    /// current, now in the new pane).
    public func splitFocusedPane(
        movingSelected: Bool,
        direction: PaneAssignment.SplitOrientation = .horizontal
    ) {
        var next = paneAssignment
        next.splitFocusedPane(moving: movingSelected ? tabs.selected?.id : nil,
                              direction: direction)
        paneAssignment = next
    }

    /// Focus `paneID` and make ITS remembered selection the app-wide
    /// current tab (click-into-a-pane / next-pane command semantics).
    public func focusPane(id paneID: UUID) {
        var next = paneAssignment
        next.focusPane(id: paneID)
        paneAssignment = next
        if let sel = next.focusedPane.selectedTabID,
           let idx = tabs.tabs.firstIndex(where: { $0.id == sel }) {
            select(at: idx)   // runs the sync — keeps both sides agreed
        }
    }

    /// Close a pane; its tabs are absorbed by the neighbor (never closed).
    /// The app-wide selection follows the absorbing pane's selection.
    public func closePane(id paneID: UUID) {
        var next = paneAssignment
        next.closePane(id: paneID)
        paneAssignment = next
        if let sel = next.focusedPane.selectedTabID,
           let idx = tabs.tabs.firstIndex(where: { $0.id == sel }) {
            select(at: idx)
        }
    }

    /// Reorder a tab WITHIN its pane (the strip drag + the Move Tab
    /// Left/Right commands). `gap` is in `TabsState.move` coordinates
    /// against the PANE's order. While split, each pane owns its strip
    /// order and the flat store is deliberately untouched. UN-split, the
    /// STORE owns the order (`mirrorSinglePane` overwrites the pane from
    /// it on every sync) — so the reorder must drive the store, or it
    /// visually applies and then REVERTS on the next coordinator mutation
    /// (owner audit 2026-08-27; the pane order == store order un-split,
    /// so the gap coordinates are identical).
    public func reorderPaneTab(id tabID: UUID, to gap: Int) {
        if paneAssignment.isSplit {
            var next = paneAssignment
            next.reorderTab(id: tabID, to: gap)
            if next != paneAssignment { paneAssignment = next }
        } else if let from = tabs.tabs.firstIndex(where: { $0.id == tabID }) {
            move(from: from, to: gap)
        }
    }

    /// S4d — commit a divider drag's rebalanced weights (equality-guarded;
    /// the model refuses count mismatches from a drag racing a pane close).
    public func setPaneWeights(_ weights: [CGFloat]) {
        var next = paneAssignment
        next.applyWeights(weights)
        if next != paneAssignment { paneAssignment = next }
    }

    /// Cycle focus to the next pane in the run (wraps). No-op un-split.
    /// The app-wide selection follows the pane's remembered tab, same as
    /// clicking into it.
    public func focusNextPane() {
        let a = paneAssignment
        guard a.isSplit,
              let idx = a.panes.firstIndex(where: { $0.id == a.focusedPaneID })
        else { return }
        focusPane(id: a.panes[(idx + 1) % a.panes.count].id)
    }

    /// Tear `tabID` into a new pane before/after ITS pane (the tab
    /// context-menu splits). The new pane takes focus; the store selects
    /// the torn tab.
    public func splitPane(
        movingTab tabID: UUID,
        placement: PaneAssignment.SplitPlacement,
        direction: PaneAssignment.SplitOrientation = .horizontal
    ) {
        var next = paneAssignment
        next.splitPane(moving: tabID, placement: placement, direction: direction)
        guard next != paneAssignment else { return }
        paneAssignment = next
        if let idx = tabs.tabs.firstIndex(where: { $0.id == tabID }) {
            select(at: idx)
        }
    }

    /// Move a tab into `paneID` (drag between strips / "Open in New
    /// Pane"). The destination pane takes focus and shows the moved tab.
    public func movePaneTab(id tabID: UUID, toPane paneID: UUID, at index: Int? = nil) {
        var next = paneAssignment
        next.moveTab(id: tabID, toPane: paneID, at: index)
        next.focusPane(id: paneID)
        paneAssignment = next
        if let idx = tabs.tabs.firstIndex(where: { $0.id == tabID }) {
            select(at: idx)
        }
    }

    /// I-21 S4b — capture the pane layout for the session snapshot, by
    /// FILE PATH (tab ids are re-minted on restore). nil while un-split so
    /// fresh snapshots stay byte-compatible with older files.
    public func paneLayoutSnapshot() -> SessionSnapshot.PaneLayoutState? {
        let a = paneAssignment
        guard a.isSplit else { return nil }
        let pathByID: [UUID: String] = Dictionary(
            tabs.tabs.compactMap { t in t.url.map { (t.id, $0.path) } },
            uniquingKeysWith: { first, _ in first })
        return SessionSnapshot.PaneLayoutState(
            panes: a.panes.map { $0.tabIDs.compactMap { pathByID[$0] } },
            selected: a.panes.map { $0.selectedTabID.flatMap { pathByID[$0] } },
            focusedIndex: a.panes.firstIndex { $0.id == a.focusedPaneID } ?? 0,
            orientation: a.orientation.rawValue,
            weights: a.panes.map { Double($0.weight) })
    }

    /// I-21 S4b — restore a persisted pane layout AFTER the session's tabs
    /// have been appended: persisted paths resolve to the re-minted tab
    /// ids, the result normalizes against the store (missing files drop;
    /// unassigned tabs join the focused pane), and the app-wide selection
    /// follows the focused pane's memory.
    /// Session-switch FAÇADE-LEAK GUARD (owner bug 2026-08-26): collapse to
    /// a single pane holding the store's tabs and selection. A session with
    /// no persisted pane layout (never split) must not inherit the previous
    /// session's split through the shared coordinator — without this, the
    /// stale panes swallow the incoming session's tabs via `normalized`.
    /// Same class as the `splitURL` guard in `SessionState.hydrate`.
    public func resetPaneLayout() {
        let next = PaneAssignment(tabIDs: tabs.tabs.map(\.id),
                                  selectedTabID: tabs.selected?.id)
        if next != paneAssignment { paneAssignment = next }
    }

    public func applyPaneLayout(_ state: SessionSnapshot.PaneLayoutState) {
        // A degenerate single-pane persisted layout means "un-split" — treat
        // it exactly like the nil case (reset, don't keep the live split).
        guard state.panes.count > 1 else { resetPaneLayout(); return }
        let idByPath: [String: UUID] = Dictionary(
            tabs.tabs.compactMap { t in t.url.map { ($0.path, t.id) } },
            uniquingKeysWith: { first, _ in first })
        let panes = state.panes.enumerated().map { i, paths -> PaneAssignment.Pane in
            let ids = paths.compactMap { idByPath[$0] }
            let sel = state.selected.indices.contains(i)
                ? state.selected[i].flatMap { idByPath[$0] } : nil
            // Pre-S4d snapshots carry no weights → equal shares.
            let w = state.weights.flatMap {
                $0.indices.contains(i) ? CGFloat($0[i]) : nil
            } ?? 1
            return PaneAssignment.Pane(tabIDs: ids, selectedTabID: sel,
                                       weight: w > 0 ? w : 1)
        }
        let orientation = PaneAssignment.SplitOrientation(rawValue: state.orientation)
            ?? .horizontal
        var next = PaneAssignment(
            restoring: panes, focusedIndex: state.focusedIndex,
            orientation: orientation)
        next = next.normalized(against: tabs.tabs.map(\.id))
        paneAssignment = next
        if let sel = next.focusedPane.selectedTabID,
           let idx = tabs.tabs.firstIndex(where: { $0.id == sel }) {
            select(at: idx)
        }
    }

    public init() {}

    // MARK: - Value types

    /// Per-tab CSV filter state. Mirror of the prior nested type on
    /// `DocumentModel.CSVFilterState`; aliased there for source
    /// compatibility.
    public struct CSVFilterState: Equatable, Sendable {
        public var globalQuery: String = ""
        public var globalScope: Int? = nil
        public var perColumn: [Int: String] = [:]
        public var advancedShown: Bool = false

        public init(globalQuery: String = "", globalScope: Int? = nil,
                    perColumn: [Int: String] = [:], advancedShown: Bool = false) {
            self.globalQuery = globalQuery
            self.globalScope = globalScope
            self.perColumn = perColumn
            self.advancedShown = advancedShown
        }
    }

    // MARK: - Derived

    public var selected: ViewerCore.Tab? { tabs.selected }
    public var selectedIndex: Int? { tabs.selectedIndex }
    public var isSplitOpen: Bool { splitURL != nil }

    // MARK: - Tab mutation primitives

    /// Append `tab` and select it. Updates `openTabURLs` cheaply.
    public func append(_ tab: ViewerCore.Tab) {
        tabs.append(tab)
        refreshOpenTabURLs()
        syncPaneAssignment(opened: tab.id)
    }

    public func select(at index: Int) {
        tabs.select(at: index)
        // `selectedIndex` change doesn't shift the URL set; skip the
        // recompute to keep hot-path tab clicks cheap.
        syncPaneAssignment()
    }

    public func replace(at index: Int, with tab: ViewerCore.Tab) {
        tabs.replace(at: index, with: tab)
        // A replace can swap URL (lazy materialize finish, viewMode
        // flip with URL retained, etc.); recompute conservatively.
        refreshOpenTabURLs()
        syncPaneAssignment(opened: tab.id)
    }

    public func move(from src: Int, to dst: Int) {
        tabs.move(from: src, to: dst)
        // Move never changes the URL set; skip the recompute.
        syncPaneAssignment()
    }

    public func swapWithPrevious(at index: Int) {
        tabs.swapWithPrevious(at: index)
        syncPaneAssignment()
    }

    public func swapWithNext(at index: Int) {
        tabs.swapWithNext(at: index)
        syncPaneAssignment()
    }

    @discardableResult
    public func openOrReveal(url: URL, state: DocumentState, viewMode: ViewMode) -> Int {
        let i = tabs.openOrReveal(url: url, state: state, viewMode: viewMode)
        refreshOpenTabURLs()
        syncPaneAssignment(opened: tabs.tabs.indices.contains(i) ? tabs.tabs[i].id : nil)
        return i
    }

    /// Open `url` in the single ephemeral preview slot (TSK-306 / TSK-272).
    /// Forwarder onto `TabsState.openPreview`. See `docs/PREVIEW_TAB_DESIGN.md`.
    @discardableResult
    public func openPreview(url: URL, state: DocumentState, viewMode: ViewMode) -> Int {
        let i = tabs.openPreview(url: url, state: state, viewMode: viewMode)
        refreshOpenTabURLs()
        syncPaneAssignment(opened: tabs.tabs.indices.contains(i) ? tabs.tabs[i].id : nil)
        return i
    }

    /// Promote the preview tab `id` → permanent ("pin"). Forwarder.
    public func promoteTab(id: UUID) {
        tabs.promoteTab(id: id)
    }

    /// id of the current ephemeral preview tab, if any. Forwarder.
    public var previewTabID: UUID? { tabs.previewTabID }

    // MARK: - Close paths (the three that prune per-tab dicts)

    /// Close the tab at `index` and prune every per-tab cache that
    /// belonged to it. Caller is responsible for any dirty-buffer
    /// prompting BEFORE invoking this (the prompt lives on
    /// DocumentModel so it can run NSAlert and call `saveEditor`).
    ///
    /// Returns the closed tab's id (or nil for an out-of-bounds
    /// index) so the caller can run additional post-close cleanup
    /// (e.g. DocumentModel's `purgeCaches(forURL:tabID:)`).
    ///
    /// SELECTION (owner 2026-08-27): closing the SELECTED tab selects the
    /// most recently selected still-open sibling of the SAME pane (the MRU
    /// history) — not the flat store's index-neighbor, which in a split
    /// could live in the OTHER pane (yanking focus there and overwriting
    /// that pane's front). Fallbacks: pane-strip neighbor (after, else
    /// before); a pane whose last tab died hands selection to the focused
    /// survivor's own front. Tab ORDER is never touched.
    @discardableResult
    public func closeTab(at index: Int) -> UUID? {
        guard tabs.tabs.indices.contains(index) else { return nil }
        let closed = tabs.tabs[index]
        let replacement = tabs.selected?.id == closed.id
            ? closeReplacement(for: closed.id) : nil
        tabs.close(at: index)
        cleanupAfterClose(id: closed.id)
        if let rep = replacement,
           let idx = tabs.tabs.firstIndex(where: { $0.id == rep }) {
            tabs.select(at: idx)
        }
        refreshOpenTabURLs()
        syncPaneAssignment()
        return closed.id
    }

    /// MRU selection history, most-recent first (front = current
    /// selection). Maintained by `syncPaneAssignment`; pruned on close.
    /// Ephemeral by design — a restored session starts fresh and falls
    /// back to the pane-neighbor rule.
    private(set) var selectionHistory: [UUID] = []
    private static let selectionHistoryCap = 64

    /// The tab to select after closing the SELECTED tab `closedID`.
    private func closeReplacement(for closedID: UUID) -> UUID? {
        let a = paneAssignment
        guard let pane = a.pane(containing: closedID) else { return nil }
        let siblings = pane.tabIDs.filter { $0 != closedID }
        if !siblings.isEmpty {
            // MRU first (skips the closed tab naturally — it's no sibling).
            if let mru = selectionHistory.first(where: { siblings.contains($0) }) {
                return mru
            }
            // Pane-strip neighbor: the tab after, else the one before.
            if let pos = pane.tabIDs.firstIndex(of: closedID) {
                return pos + 1 < pane.tabIDs.count
                    ? pane.tabIDs[pos + 1] : pane.tabIDs[pos - 1]
            }
            return siblings.last
        }
        // The pane's last tab died: selection goes to a surviving pane's
        // OWN front (prefer the focused pane), never disturbing it.
        if a.focusedPaneID != pane.id,
           let f = a.panes.first(where: { $0.id == a.focusedPaneID })?.selectedTabID {
            return f
        }
        return a.panes.first(where: { $0.id != pane.id && $0.selectedTabID != nil })?
            .selectedTabID
    }

    /// Close an arbitrary id set (the pane-scoped close variants). Returns
    /// the ids actually closed. Same cleanup pipeline as the index-batch
    /// primitives; `syncPaneAssignment` reconciles the panes afterwards.
    @discardableResult
    public func closeTabs(ids: Set<UUID>) -> [UUID] {
        let closedIDs = tabs.tabs.filter { ids.contains($0.id) }.map(\.id)
        guard !closedIDs.isEmpty else { return [] }
        tabs.close(ids: Set(closedIDs))
        for id in closedIDs { cleanupAfterClose(id: id) }
        let openIDs = Set(tabs.tabs.map { $0.id })
        formattedTabIDs.formIntersection(openIDs)
        refreshOpenTabURLs()
        syncPaneAssignment()
        return closedIDs
    }

    /// Close every tab except the one at `index`. Returns the ids of
    /// the closed tabs (in original order) for any caller-side
    /// follow-up cleanup. Caller is responsible for dirty prompts.
    @discardableResult
    public func closeOtherTabs(keeping index: Int) -> [UUID] {
        guard tabs.tabs.indices.contains(index) else { return [] }
        let keepID = tabs.tabs[index].id
        let closedIDs = tabs.tabs.filter { $0.id != keepID }.map { $0.id }
        tabs.closeAll(except: index)
        for id in closedIDs { cleanupAfterClose(id: id) }
        // The `formattedTabIDs` set is the one cleanup that's cheaper
        // to do as a set-intersection than as a per-id remove (it's a
        // Set not a Dict and the surviving set is a single element).
        // Same final state either way; the intersect just avoids an
        // O(n_closed) loop on a set that's almost always tiny.
        let openIDs = Set(tabs.tabs.map { $0.id })
        formattedTabIDs.formIntersection(openIDs)
        refreshOpenTabURLs()
        syncPaneAssignment()
        return closedIDs
    }

    /// Close every tab whose index is greater than `index`. Returns
    /// the closed-tab ids for any caller-side follow-up cleanup.
    @discardableResult
    public func closeTabsToRight(of index: Int) -> [UUID] {
        guard tabs.tabs.indices.contains(index) else { return [] }
        if tabs.tabs.count <= index + 1 { return [] }
        let closed = Array(tabs.tabs.suffix(from: index + 1))
        let closedIDs = closed.map { $0.id }
        tabs.closeAllToRight(of: index)
        for id in closedIDs { cleanupAfterClose(id: id) }
        let openIDs = Set(tabs.tabs.map { $0.id })
        formattedTabIDs.formIntersection(openIDs)
        refreshOpenTabURLs()
        syncPaneAssignment()
        return closedIDs
    }

    /// Single fan-out point for the per-tab cleanup. Called from each
    /// of the three close paths. Whenever a new per-tab dict gets
    /// added here, EVERY close path picks up the cleanup automatically
    /// — this is the invariant the previous in-line cleanup blocks
    /// kept silently breaking.
    ///
    /// Order matters minimally (these are independent dict deletes)
    /// but we keep the listing alphabetical so additions land in
    /// predictable spots.
    private func cleanupAfterClose(id: UUID) {
        selectionHistory.removeAll { $0 == id }
        cancelMaterialize(forTabID: id)
        csvFilterStates.removeValue(forKey: id)
        editorBuffers.removeValue(forKey: id)
        // formattedTabIDs handled by the caller via intersection
        // (it's a Set, cheaper to recompute once at end of batch
        // close). For single-tab close we drop it explicitly here:
        formattedTabIDs.remove(id)
        formattedTextCache.removeValue(forKey: id)
        if let idx = formattedTextCacheOrder.firstIndex(of: id) {
            formattedTextCacheOrder.remove(at: idx)
        }
        hexBytesPerRow.removeValue(forKey: id)
        languageOverrides.removeValue(forKey: id)
        // External hooks last — built-in drains finish first so the
        // closure observes a fully-pruned coordinator if it ever pokes
        // back at our state.
        for hook in closeHooks { hook(id) }
    }

    /// Recompute the open-tab URL set from `tabs`. Dedupe assignment
    /// so observers don't re-publish on no-op URL-set changes
    /// (selection moves, viewMode flips, etc.).
    private func refreshOpenTabURLs() {
        let newSet = Set(tabs.tabs.compactMap { $0.url })
        if newSet != openTabURLs { openTabURLs = newSet }
    }

    // MARK: - Per-tab dict accessors / mutators

    public func csvFilterState(forTabID id: UUID) -> CSVFilterState {
        csvFilterStates[id] ?? CSVFilterState()
    }

    public func setCsvFilterState(_ state: CSVFilterState, forTabID id: UUID) {
        if csvFilterStates[id] != state { csvFilterStates[id] = state }
    }

    public func clearCsvFilterState(forTabID id: UUID) {
        csvFilterStates.removeValue(forKey: id)
    }

    public func hexWidth(forTabID id: UUID, fallback: Int) -> Int {
        if let w = hexBytesPerRow[id] { return HexLayout.clampWidth(w) }
        return HexLayout.clampWidth(fallback)
    }

    public func setHexWidth(_ width: Int, forTabID id: UUID) {
        let clamped = HexLayout.clampWidth(width)
        if hexBytesPerRow[id] != clamped { hexBytesPerRow[id] = clamped }
    }

    /// Effective language for `tabID` — override wins over the
    /// auto-detected language passed in by the caller. The caller
    /// owns the autodetect (uses URL extension) so this coordinator
    /// stays UI-toolkit-free; we only adjudicate the override map.
    public func effectiveLanguage(
        forTabID id: UUID, autodetected: HighlightLanguage
    ) -> HighlightLanguage {
        languageOverrides[id] ?? autodetected
    }

    /// Set the language for the selected tab. Pass `autodetected` so
    /// we can clear the override when it would no longer have an
    /// effect (i.e. user selected the natural language).
    public func setSelectedTabLanguage(
        _ lang: HighlightLanguage, autodetected: HighlightLanguage
    ) {
        guard let id = tabs.selected?.id,
              let i = tabs.tabs.firstIndex(where: { $0.id == id })
        else { return }
        if lang == autodetected {
            languageOverrides.removeValue(forKey: id)
        } else {
            languageOverrides[id] = lang
        }
        // Re-publish the tab so source-view downstream recomputes its
        // highlight runs. No payload change — only the override map
        // shifted — but the cached `highlightRuns(forTabID:url:text:
        // language:)` keys on `language`, so the language flip alone
        // is enough to invalidate.
        let t = tabs.tabs[i]
        tabs.replace(at: i, with: t)
    }

    public var hasLanguageOverrideForSelected: Bool {
        guard let id = tabs.selected?.id else { return false }
        return languageOverrides[id] != nil
    }

    /// Toggle the formatted flag on the selected tab. Caller has
    /// already verified `supportsFormatToggle` (it depends on URL
    /// type, which is a DocumentModel-level concern).
    public func toggleFormatForSelected() {
        guard let id = tabs.selected?.id else { return }
        if formattedTabIDs.contains(id) {
            formattedTabIDs.remove(id)
        } else {
            formattedTabIDs.insert(id)
        }
    }

    public func setFormatted(_ on: Bool, forTabID id: UUID) {
        if on { formattedTabIDs.insert(id) }
        else  { formattedTabIDs.remove(id) }
    }

    public var isSelectedTabFormatted: Bool {
        guard let id = tabs.selected?.id else { return false }
        return formattedTabIDs.contains(id)
    }

    /// LRU-ish read-through for the pretty-printer output. Returns the
    /// cached entry when BOTH the source length AND the source mtime
    /// match the cached entry's, nil otherwise (caller computes +
    /// caches). The mtime compare is what makes a same-byte-length
    /// reload a miss (RWC-2 / TD-09).
    public func formattedHit(
        forTabID id: UUID, sourceLength: Int, modifiedTime: Date?
    ) -> FormattedCacheEntry? {
        guard let hit = formattedTextCache[id],
              hit.sourceLength == sourceLength,
              hit.modifiedTime == modifiedTime
        else { return nil }
        return hit
    }

    /// Store a fresh pretty-print result and evict the oldest entries
    /// once over cap. The 2/3 drop-down matches the rendered-HTML
    /// cache eviction strategy (S2-G / S4-G). `formattedLength` is the
    /// utf8 length of `result`, computed once by the caller so the
    /// highlight path doesn't re-walk it (PERF-04).
    public func cacheFormatted(
        _ result: String, forTabID id: UUID,
        sourceLength: Int, modifiedTime: Date?, formattedLength: Int
    ) {
        if formattedTextCache[id] == nil {
            formattedTextCacheOrder.append(id)
        }
        formattedTextCache[id] = FormattedCacheEntry(
            sourceLength: sourceLength,
            modifiedTime: modifiedTime,
            formatted: result,
            formattedLength: formattedLength
        )
        if formattedTextCache.count > Self.formattedTextCacheMax {
            let dropCount = formattedTextCache.count - Self.formattedTextCacheMax * 2 / 3
            let toDrop = formattedTextCacheOrder.prefix(dropCount)
            for k in toDrop {
                formattedTextCache.removeValue(forKey: k)
            }
            formattedTextCacheOrder.removeFirst(toDrop.count)
        }
    }

    // MARK: - Editor buffer accessors

    /// Returns the cached buffer for `id`, or seeds one from the
    /// tab's `.loaded` state if not yet present. Returns nil for
    /// binary / empty / error tabs.
    public func editorBuffer(forTabID id: UUID) -> EditorBuffer? {
        if let cached = editorBuffers[id] { return cached }
        guard let tab = tabs.tabs.first(where: { $0.id == id }),
              case .loaded(let file) = tab.state else { return nil }
        let buf = EditorBuffer(from: file)
        editorBuffers[id] = buf
        return buf
    }

    /// Idempotent seed — preserves an existing buffer with unsaved
    /// edits. Called when the view-mode switch lands on `.editor` and
    /// on lazy-materialize completion for an `.editor`-mode tab.
    public func ensureEditorBuffer(for file: TextFile, tabID: UUID) {
        if editorBuffers[tabID] != nil { return }
        editorBuffers[tabID] = EditorBuffer(from: file)
    }

    /// Replace the buffer for `id`. Used by the save path
    /// (post-stamp refresh) and the editor-text update path.
    public func setEditorBuffer(_ buf: EditorBuffer, forTabID id: UUID) {
        editorBuffers[id] = buf
    }

    /// Drop the buffer for a tab. Called by the close paths via
    /// `cleanupAfterClose`, and explicitly by the dirty-confirm
    /// "Don't Save" branch.
    public func discardEditorBuffer(forTabID id: UUID) {
        editorBuffers.removeValue(forKey: id)
    }

    // MARK: - Materialize tasks

    /// Record an in-flight materialize Task for `id`. Replaces any
    /// existing entry; caller is expected to have cancelled the prior
    /// task before this call if it wanted the old result dropped.
    public func setMaterializeTask(_ task: Task<Void, Never>, forTabID id: UUID) {
        materializeTasks[id] = task
    }

    public func materializeTask(forTabID id: UUID) -> Task<Void, Never>? {
        materializeTasks[id]
    }

    /// Clear the materialize slot for `id`. Doesn't cancel — used by
    /// the task's completion path after it finishes its on-main hop.
    public func clearMaterializeTask(forTabID id: UUID) {
        materializeTasks[id] = nil
    }

    /// Cancel + drop the materialize Task for `id`. Called from every
    /// tab-close path (folded into `cleanupAfterClose`).
    public func cancelMaterialize(forTabID id: UUID) {
        materializeTasks[id]?.cancel()
        materializeTasks[id] = nil
    }

    // MARK: - Split pane

    public func openInSplit(_ url: URL) {
        splitURL = url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func closeSplit() { splitURL = nil }

    // MARK: - Split ↔ tab correlation (TSK-923)
    //
    // The split pane shows a file independently of the tab list, but the
    // user has no cue in the tab strip telling them WHICH open file is
    // pinned to the right pane. These pure predicates let the TabBar draw a
    // "right-pane indicator" badge on the matching tab. Both normalize via
    // `TabsState.dedupKey` (the same `standardizedFileURL.resolvingSymlinks`
    // key the tab list and `openInSplit` already store under) so a caller
    // that passes an unresolved URL still matches — `splitURL` is itself
    // stored resolved, so this is symmetric and order-independent.

    /// True when `url` is the file currently shown in the split (right)
    /// pane. False when no split is open or it shows a different file.
    /// Drives the tab strip's right-pane indicator: the tab whose file is
    /// in the split gets a badge. Pure → host-testable without a render.
    public func isURLInSplit(_ url: URL) -> Bool {
        guard let split = splitURL else { return false }
        return TabsState.dedupKey(url) == TabsState.dedupKey(split)
    }

    /// The id of the open TAB whose file is currently shown in the split
    /// pane, or nil when the split is closed or its file isn't open in any
    /// tab (the split pane can show a file that has no tab — it reads from
    /// disk directly). Lets the strip target the indicator at one tab
    /// without re-scanning by URL in the view body.
    public var splitTabID: UUID? {
        guard let split = splitURL else { return nil }
        let key = TabsState.dedupKey(split)
        return tabs.tabs.first { tab in
            guard let u = tab.url else { return false }
            return TabsState.dedupKey(u) == key
        }?.id
    }
}
