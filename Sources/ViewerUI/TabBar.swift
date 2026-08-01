import SwiftUI
import ViewerCore

struct TabBar: View {
    @ObservedObject var model: DocumentModel

    /// DIRTYDOT (2026-06-03): TabBar must ALSO observe `tabCoordinator`,
    /// not just `model`. The open-tab list, selection, and `Tab.isDirty`
    /// all live on `TabCoordinator.tabs` (`model.tabs` is a forwarder).
    /// PERF #1 (2026-05-25) deliberately SEVERED the
    /// `tabCoordinator.objectWillChange` → `DocumentModel.objectWillChange`
    /// forwarding to stop editor keystrokes / per-tab churn from re-bodying
    /// the whole content tree — that invariant is pinned by
    /// `TabRepublishInvariantTests`/`EditorRepublishInvariantTests`. The
    /// fallout: the editor edit/save/discard paths flip `Tab.isDirty` via
    /// `tabCoordinator.replace` (fires `tabCoordinator.objectWillChange`
    /// ONLY), so a TabBar that observed `model` alone never re-rendered the
    /// accent dirty dot (`mdv.tab.dirtyDot`) on edit and never cleared it on
    /// save. Observing the coordinator directly is the textbook
    /// narrow-observation fix (same shape as the views that observe
    /// `sidebar` directly per the PERF #1 audit) — the strip re-bodies on
    /// tab/selection/dirty ticks without resurrecting the republish storm.
    @ObservedObject var tabCoordinator: TabCoordinator

    init(model: DocumentModel) {
        self.model = model
        self.tabCoordinator = model.tabCoordinator
    }

    /// item12: tab-strip width budget. Idle width per tab + the floor it
    /// shrinks to under crowding (icon + close glyph, label clipped). The
    /// strip first shrinks every tab toward `minShrunkWidth`; once even
    /// the floor doesn't fit, the surrounding ScrollView takes over and
    /// the strip overflows / scrolls (scroll-to-selected already shipped
    /// in WAVE 1). Scaled by zoom so high-zoom tabs stay legible.
    private static let idealTabWidth: CGFloat = 180
    /// TSK-331: shrink floor lowered 54→40 so the strip packs more tabs before
    /// it has to scroll (40pt still fits the file-type icon + the hover close
    /// glyph; the title clips). Past this floor the overflow dropdown (TSK-304)
    /// + ScrollView take over.
    private static let minShrunkWidth: CGFloat = 40

    /// Available strip width, measured by a NON-layout-driving background
    /// reader (see `.background`) rather than a wrapping `GeometryReader`.
    ///
    /// CHROME RESIZE FIX (Bug A, 2026-06-01): the body used to be wrapped
    /// in a `GeometryReader` (introduced WAVE 2b `8ddda05`) purely to feed
    /// `geo.size.width` into `computedTabWidth`. A `GeometryReader` is
    /// GREEDY on both axes yet reports a TINY (10×10) IDEAL size — so the
    /// TabBar's intrinsic width collapsed to 10pt and its vertical sizing
    /// became ambiguous. Sitting inside the chrome VStack's
    /// `.fixedSize(vertical:)` + `layoutPriority(1)` row, that ambiguous
    /// intrinsic size is exactly the kind of unstable composition that
    /// makes the bar mis-lay-out / blank on a live window resize ("top
    /// tab bar disappears on resize"). Measuring width via a
    /// `.background(GeometryReader …)` overlay keeps the value available
    /// to the width budget WITHOUT letting the reader drive the strip's
    /// own layout: a background never changes its parent's sizing, so the
    /// HStack reports a firm `(naturalWidth, 30)` intrinsic size again.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("TabBar")   // TSK-615 re-eval width probe
        #endif
        let tabWidth = Self.computedTabWidth(
            available: availableWidth,
            count: model.tabs.tabs.count,
            scale: CGFloat(model.zoom)
        )
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    TabStripContent(model: model,
                                    tabCoordinator: tabCoordinator,
                                    tabWidth: tabWidth)
                }
                // item12a: keep the active tab visible. Fires on programmatic
                // selection too (⌘1-9, command palette, revealInSidebar,
                // close-shifts-selection) — driven by selectedIndex, not a tap
                // closure — so an off-screen selection always scrolls in.
                .onChange(of: model.tabs.selectedIndex) { _, _ in
                    scrollToSelected(proxy)
                }
                .onAppear { scrollToSelected(proxy, animated: false) }
            }
            // TSK-304: when the strip is crowded (tabs pinned at the shrink
            // floor → more tabs than fit), a pinned overflow dropdown lists
            // every open tab so any one is reachable without scrolling. Hidden
            // when the tabs fit, so it doesn't clutter the common case.
            if TabBar.tabsAreCrowded(available: availableWidth,
                                     count: model.tabs.tabs.count,
                                     scale: CGFloat(model.zoom)) {
                Menu {
                    ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        Button {
                            model.selectTab(at: index)
                        } label: {
                            Text((index == model.tabs.selectedIndex ? "✓ " : "")
                                 + (tab.isDirty ? "• " : "") + tab.title)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: model.uiSize(11), weight: .medium))
                        .frame(width: model.uiSize(24), height: model.uiSize(24))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("All tabs (\(model.tabs.tabs.count)) — jump to any")
                .accessibilityIdentifier("mdv.tab.overflowMenu")
                .padding(.trailing, model.uiSize(4))
            }
        }
        .frame(height: model.uiSize(30))
        // Measure the strip's available width WITHOUT a wrapping
        // GeometryReader (see `availableWidth` doc): a `.background`
        // overlay reads geometry but never alters the parent's layout,
        // so the HStack keeps a firm intrinsic size. The reader fills the
        // background, reports its width, and we mirror it into state on
        // change. `Color.clear` keeps the existing window-background fill
        // behavior unchanged.
        .background(
            GeometryReader { geo in
                Palette.windowBackground
                    .onAppear { availableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in availableWidth = w }
            }
        )
    }

    /// item12: per-tab width under a width budget. Reserve the trailing
    /// "+" new-tab button (~32 pt), divide the rest by the tab count, and
    /// clamp to `[minShrunkWidth … idealTabWidth]` (both zoom-scaled).
    ///
    /// - Few tabs → each gets `idealTabWidth` (clamp upper bound) and the
    ///   strip is left-packed with empty trailing space.
    /// - Crowded → tabs shrink toward `minShrunkWidth` (the lower clamp).
    /// - Past the floor (even shrunk tabs overflow) → the value sticks at
    ///   `minShrunkWidth` and the enclosing ScrollView scrolls.
    static func computedTabWidth(available: CGFloat, count: Int, scale: CGFloat) -> CGFloat {
        let lower = minShrunkWidth * scale
        let upper = idealTabWidth * scale
        guard count > 0, available > 0 else { return upper }
        let usable = max(available - 32, lower)  // reserve the "+" button
        let per = usable / CGFloat(count)
        return min(max(per, lower), upper)
    }

    /// TSK-304: true when the strip is crowded — tabs have shrunk to the
    /// `minShrunkWidth` floor, i.e. there are more tabs than fit at the floor
    /// so the strip is (or is about to be) overflowing/scrolling. Drives the
    /// overflow dropdown's visibility. Pure → unit-tested in `TabBarWidthTests`.
    static func tabsAreCrowded(available: CGFloat, count: Int, scale: CGFloat) -> Bool {
        guard count > 1, available > 0 else { return false }
        let lower = minShrunkWidth * scale
        return computedTabWidth(available: available, count: count, scale: scale) <= lower + 0.5
    }

    /// Bring the currently-selected tab into view. Centers it so a tab near
    /// either edge isn't left half-clipped. No-op when there's no selection.
    private func scrollToSelected(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let i = model.tabs.selectedIndex,
              model.tabs.tabs.indices.contains(i) else { return }
        let id = model.tabs.tabs[i].id
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// The scrolling row of tabs, split out of `TabBar` so the reorder drag
/// state can live at a leaf.
///
/// ## Why this is a separate view (PERF #1 — do not inline it back)
///
/// The drag needs `@State private var frameBox = StripFrameBox()`. That
/// property initializer runs every time a parent builds the view value, so it
/// allocates a NEW object each pass; the fresh view value therefore never
/// compares equal to the previous one and SwiftUI cannot SKIP the body when
/// `ContentView` re-bodies for unrelated reasons. Put it on `TabBar` and the
/// strip re-bodies on EVERY republish — including a find keystroke that
/// touches no tab state. `ChromeBodyEvalCountTests` caught exactly that
/// (`TabBar=1` on find typeahead, sidebar recency tick, and panel toggle).
///
/// It is the fresh ALLOCATION that costs the skip, not "non-POD state":
/// measured on `TabBar`, a `@State var x: [Int] = []` keeps it green while
/// `@State var x = StripFrameBox()` reproduces all three failures. Holding
/// the state one level down keeps `TabBar`'s own stored properties
/// unchanged, so the skip still applies and the strip only re-bodies for
/// tab/selection/dirty ticks and live drags. See LESSONS.md 2026-07-27.
private struct TabStripContent: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var tabCoordinator: TabCoordinator
    let tabWidth: CGFloat

    /// Coordinate space the reorder geometry is measured in — the strip's
    /// scrolling content, so item frames and the drag pointer share an
    /// origin even when the strip is scrolled.
    private static let stripSpace = "mdv.tabStrip"

    @State private var frameBox = StripFrameBox()
    @State private var reorder: StripReorderState?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                TabBarItem(
                    tab: tab,
                    isSelected: model.tabs.selectedIndex == index,
                    isBookmarked: tab.url.map { model.bookmarksStore.contains($0) } ?? false,
                    // TSK-923: right-pane indicator. The tab whose
                    // file is currently shown in the split (right)
                    // pane gets a sidebar-right badge so the user
                    // can see WHICH open file is pinned there.
                    isInSplit: tabCoordinator.splitTabID == tab.id,
                    scale: CGFloat(model.zoom),
                    width: tabWidth,
                    // A reorder must NOT change which tab you are in: swallow
                    // the click that terminates a drag (see
                    // `StripFrameBox.armSelectSuppression`). `index` is also
                    // stale by then — the strip has already reordered — so
                    // acting on it would switch to an unrelated tab.
                    onSelect: {
                        guard !frameBox.shouldSuppressSelect() else { return }
                        model.selectTab(at: index)
                    },
                    onClose: { model.closeTab(at: index) }
                )
                // item12a: scroll anchor so the active tab can be
                // brought into view via ScrollViewReader.
                .id(tab.id)
                .contextMenu {
                    TabContextMenu(model: model, tabIndex: index, tab: tab)
                }
                // Drag-to-reorder. Driven by a DragGesture, NOT
                // `.onDrag`/`.onDrop`: the old pasteboard round-trip
                // carried `public.file-url` alongside the reorder payload,
                // so the drag read as a FILE drag and ContentView's
                // window-level `.onDrop(of: [.fileURL])` caught it and
                // tried to OPEN the tab's file, while the reorder itself
                // was invisible (no insertion indicator). See
                // `StripReorder` for the full rationale + the payload
                // measurement that cleared the data layer.
                .stripReorderable(
                    id: tab.id,
                    index: index,
                    ids: model.tabs.tabs.map(\.id),
                    space: Self.stripSpace,
                    frames: frameBox,
                    state: $reorder,
                    // The same drag can also target a SESSION pill: dropping
                    // there moves the file into that session (and follows it).
                    external: sessionDropTarget(for: tab),
                    commit: { draggedID, gap in
                        // Re-resolve against the LIVE tab list — see
                        // `StripReorder.resolveMove`.
                        guard let move = StripReorder.resolveMove(
                            itemID: draggedID,
                            ids: model.tabs.tabs.map(\.id),
                            gap: gap) else { return }
                        // No withAnimation here: the caller already runs this
                        // inside the drop transaction that releases the drag
                        // offset, so the tab glides from where it was dropped.
                        model.moveTab(from: move.source, to: move.destination)
                    }
                )
                // B4: full-height vertical rule between tabs.
                // The old `Divider().frame(height: 16)` only
                // spanned the middle 16pt of the 28pt-tall tab
                // row, so the seam looked partial and read
                // asymmetrically when one neighbor was the
                // tinted-active tab and the other was clear. A
                // fixed-width separator rectangle pinned to the
                // tab height draws a clean top-to-bottom line
                // that is identical regardless of which side is
                // active.
                //
                // TSK-268: drawn after EVERY tab — including the
                // last/only one — so the trailing tab has a visible
                // right edge (previously gated `index < count-1`,
                // leaving the last tab's right border missing before
                // the `+` button).
                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 1, height: model.uiSize(28))
                    .accessibilityIdentifier("mdv.tab.divider")
            }
            // TSK-261: the "+" sits BESIDE the last tab (inside the
            // scrolling content), not pinned at the far-right edge.
            // `computedTabWidth` still reserves ~32pt for it so it
            // stays visible beside the last tab until the strip
            // genuinely overflows.
            Button(action: { model.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: model.uiSize(11), weight: .medium))
                    .frame(width: model.uiSize(24), height: model.uiSize(24))
            }
            // UX-H (#230): shared icon style for hover/press feedback.
            .buttonStyle(IconHoverButtonStyle())
            // 0c: uniform HelpInfo model — native tooltip + status-bar
            // description + a11y label/hint from one source.
            .helpInfo(title: "New Tab (⌘T)",
                      description: "Open a new empty tab in the current session")
            .padding(.horizontal, model.uiSize(4))
        }
        // Reorder geometry: the strip content is the coordinate space every
        // item frame and the drag pointer are measured in, so the caret
        // lands exactly where the gap is.
        .coordinateSpace(name: Self.stripSpace)
        // Cross-strip geometry: the content's global origin converts drag
        // locations to the space the session pills measure in.
        .stripContentGlobalOrigin(into: frameBox)
        .overlay(alignment: .leading) {
            if let x = reorder?.caretX {
                StripInsertionCaret(x: x, height: model.uiSize(28))
            }
        }
    }

    /// Cross-strip capability for one tab's drag (TSK-274's affordance,
    /// back as a real gesture): dropping the tab onto a session pill calls
    /// `SessionsAppCoordinator.moveTab(withID:toSessionID:)` — moves the
    /// file into that session, activates it, selects the moved file.
    /// Offered only when the tab HAS a file (`moveTab` no-ops on untitled
    /// tabs) and a sessions coordinator is attached (nil in standalone/
    /// test hosts). The ACTIVE session's pill is excluded — a same-session
    /// drop is a no-op, so it must never light up as a target.
    private func sessionDropTarget(for tab: ViewerCore.Tab) -> StripExternalTarget? {
        guard tab.url != nil,
              let sessionsApp = model.sessionsCoordinator else { return nil }
        let channel = sessionsApp.tabDragChannel
        let box = frameBox
        return StripExternalTarget(
            toGlobal: { box.globalPoint(fromStrip: $0) },
            hitTest: { point in
                let core = sessionsApp.core
                return channel.sessionID(
                    at: point,
                    live: Set(core.sessions.map(\.id)),
                    excluding: core.activeID)
            },
            setHovered: { channel.setHovered($0) },
            commit: { tabID, sessionID in
                sessionsApp.moveTab(withID: tabID, toSessionID: sessionID)
            })
    }
}

private struct TabContextMenu: View {
    @ObservedObject var model: DocumentModel
    let tabIndex: Int
    let tab: ViewerCore.Tab

    var body: some View {
        Button("Close Tab") { model.closeTab(at: tabIndex) }
        Button("Close Other Tabs") { model.closeOtherTabs(keeping: tabIndex) }
            .disabled(model.tabs.tabs.count <= 1)
        Button("Close Tabs to the Right") { model.closeTabsToRight(of: tabIndex) }
            .disabled(tabIndex >= model.tabs.tabs.count - 1)
        Divider()
        if let url = tab.url {
            // bug6: force-reload this tab from disk regardless of detected
            // change. Dirty editor buffers route through the Keep/Discard
            // prompt (see DocumentModel.refreshTab) so this never silently
            // discards unsaved edits.
            Button("Refresh") { model.refreshTab(at: tabIndex) }
            Divider()
            // WAVE 2b item 2: open the in-app File History view for this
            // tab's file as a view-hosting tab. Enabled only when the
            // file is in a repo AND tracked (otherwise there's no history
            // to show); `canShowFileHistory` does the discoverRoot +
            // tracked gate.
            Button("File History") { model.openFileHistory(for: url) }
                .disabled(!model.canShowFileHistory(for: url))
            // TSK-1103: the unified Local History viewer (works on any file,
            // not just tracked ones). View saved versions → diff vs current /
            // range cumulative diff / restore.
            Button("Local History") { model.openLocalHistory(for: url) }
                .disabled(!model.canShowLocalHistory(for: url))
            // OPEN-AS FOLD (2026-06-01): the tab-context "Open As…" submenu
            // was fully redundant with the ModeBar "Open As" chip — both act
            // on the CURRENT tab via setCurrentCategoryOverride (this one even
            // called selectTab first to make it current). Folded to the one
            // chip affordance (ContentView.openAsMenu), which now offers the
            // full universal viewer list. The sidebar file-tree "Open As…"
            // (SidebarView) is KEPT — it's a distinct capability (open a
            // non-current file into a viewer in a new tab), not a duplicate.
            Divider()
            Button("Copy Path") { Pasteboard.copy(url.path) }
            // TSK-1256 / OwnerWishlist "Copy Reference": an mdv:// agent reference
            // an agent can open/locate via the element-ref pipeline. The FILE form
            // is durable across sessions (vs the ephemeral tab id).
            Button("Copy Reference") {
                Pasteboard.copy(ElementRef.file(path: url.path, line: nil, endLine: nil).serialized)
            }
            Button("Reveal in Finder") { Finder.reveal(url) }
            // TSK-355: open the tab's file in its default external app.
            Button("Open in Default App") { Finder.openInDefaultApp(url) }
            Button("Reveal in Sidebar") {
                model.revealInSidebar(url)
            }
            Divider()
            // TSK-315: spawn a session rooted at the file's folder with
            // the file open. "Move" also closes this session's tab so the
            // file lives in exactly one session afterwards. Routed through
            // the model's weak coordinator handle (same dispatch surface
            // as the palette verbs) — disabled when no coordinator is
            // attached (standalone/test hosts).
            Button("Open in New Session") {
                model.sessionsCoordinator?.openFileInNewSession(url)
            }
            .disabled(model.sessionsCoordinator == nil)
            Button("Move to New Session") {
                model.sessionsCoordinator?.openFileInNewSession(
                    url, removingFromCurrent: true)
            }
            .disabled(model.sessionsCoordinator == nil)
            // TSK-274 continuity: moving a tab into an EXISTING session used
            // to be drag-only (drop the tab onto a session pill). The strip's
            // drag now reorders, so the move gets an explicit affordance —
            // discoverable, and host-testable instead of pixel-only.
            if let sessions = model.sessionsCoordinator?.core.sessions,
               let activeID = model.sessionsCoordinator?.core.activeID {
                let others = sessions.filter { $0.id != activeID }
                if !others.isEmpty {
                    Menu("Move to Session") {
                        ForEach(others, id: \.id) { snap in
                            Button(snap.displayName) {
                                model.sessionsCoordinator?.moveTab(
                                    withID: tab.id, toSessionID: snap.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct TabBarItem: View {
    let tab: ViewerCore.Tab
    let isSelected: Bool
    let isBookmarked: Bool
    /// TSK-923: this tab's file is the one currently shown in the split
    /// (right) pane. Drives a small `sidebar.right` indicator badge so the
    /// user can tell at a glance which open file is pinned to the right.
    let isInSplit: Bool
    let scale: CGFloat
    /// item12: width assigned by the strip's width budget. The tab shrinks
    /// toward `minShrunkWidth` (icon + close) under crowding; the title
    /// truncates as the width drops.
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    // H4: separate hover tracking for the close control so the circular
    // backdrop only lights up when the pointer is over the close glyph
    // itself, not anywhere on the tab. Standard `.onHover` per-control
    // pattern.
    @State private var isHoveringClose = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Rectangle()
                    .fill(background)
                HStack(spacing: 6 * scale) {
                    if let url = tab.url {
                        FileIconView(url: url, isDirectory: false, size: .tree, scale: scale)
                            .frame(width: 14 * scale, height: 14 * scale)
                    }
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Bold the active document so it's obvious at a glance —
                        // but NOT a preview tab (TSK-902: preview = "just
                        // italics, not bold"). Rule in the host-tested
                        // `TabTitleStyle`.
                        .font(.system(size: 12 * scale,
                                      weight: TabTitleStyle.isBold(
                                        isSelected: isSelected, isPreview: tab.isPreview)
                                        ? .semibold : .regular))
                        // Italic for an ephemeral preview tab (VSCode
                        // convention — TSK-306 Phase 3). Promote (double-click /
                        // Enter / edit) clears `isPreview` → upright.
                        .italic(TabTitleStyle.isItalic(isPreview: tab.isPreview))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if tab.isDirty {
                        // Unsaved-edit dot. Sized to match the close
                        // button so the two glyphs occupy the same
                        // visual column when the close button is
                        // hidden (the unhovered, non-selected state).
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7 * scale, height: 7 * scale)
                            .helpInfo(title: "Unsaved changes",
                                      description: "This tab has edits that haven't been saved")
                            .accessibilityLabel("Unsaved changes")
                            .accessibilityIdentifier("mdv.tab.dirtyDot")
                    }
                    if tab.diskState.showsTabDot {
                        // TSK-371: red disk-change dot — the on-disk file
                        // changed (or was deleted) since we loaded it.
                        // Orthogonal to the accent dirty dot (a tab can be
                        // both edited-by-you AND changed-on-disk), so both
                        // can show at once. Same sizing as the dirty dot.
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7 * scale, height: 7 * scale)
                            .helpInfo(title: tab.diskState.tabDotHelpTitle ?? "Changed on disk",
                                      description: tab.diskState.tabDotHelpDescription ?? "")
                            .accessibilityLabel(tab.diskState.tabDotHelpTitle ?? "Changed on disk")
                            .accessibilityIdentifier("mdv.tab.diskDot")
                    }
                    if isBookmarked {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8 * scale))
                            .foregroundStyle(.yellow)
                            .helpInfo(title: "Bookmarked",
                                      description: "This file is bookmarked")
                            .accessibilityLabel("Bookmarked")
                    }
                    if isInSplit {
                        // TSK-923: right-pane indicator — this tab's file is
                        // shown in the split (right) pane. The accent tint ties
                        // it to the selected-tab accent so the two read as one
                        // surface; `sidebar.right` is the standard glyph for a
                        // right-docked pane.
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 9 * scale, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .helpInfo(title: "Shown in split",
                                      description: "This file is displayed in the right-hand split pane")
                            .accessibilityLabel("Shown in split pane")
                            .accessibilityIdentifier("mdv.tab.splitIndicator")
                    }
                    Button(action: onClose) {
                        // H4: centered `xmark` glyph over a circular
                        // backdrop that fades in only while the pointer
                        // is over the close control. Scales with `scale`
                        // (the zoom factor — same value `model.uiSize`
                        // multiplies by) so the control grows with its
                        // neighbors. The circle is `controlBackground` at
                        // a low opacity so it reads as a subtle hover
                        // chip rather than a hard button.
                        ZStack {
                            Circle()
                                .fill(Palette.controlBackground)
                                .opacity(isHoveringClose ? 0.9 : 0)
                            Image(systemName: "xmark")
                                .font(.system(size: 8 * scale, weight: .bold))
                                .foregroundStyle(isHoveringClose ? Color.primary : Color.secondary)
                        }
                        .frame(width: 16 * scale, height: 16 * scale)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || isSelected ? 1 : 0)
                    // Fade the close button in/out rather than popping
                    // it. Driven by the hover/selection state so the
                    // glyph eases to visible on hover and back out on
                    // leave instead of snapping.
                    .animation(.easeInOut(duration: 0.12), value: isHovering || isSelected)
                    .animation(.easeInOut(duration: 0.12), value: isHoveringClose)
                    .onHover { isHoveringClose = $0 }
                    // NOTE (2026-08-01, probed): under the tab Button's
                    // `.contain`, this child element reports the PARENT
                    // tab's AX frame no matter where the id sits in the
                    // chain — AX drivers must derive the ×'s position from
                    // the tab frame (see AXChromeInteractionTests).
                    .accessibilityIdentifier("mdv.tab.closeButton")
                    // 0c: uniform HelpInfo — title for the bubble, longer
                    // description fed to the status bar on hover.
                    .helpInfo(title: "Close Tab (⌘W)",
                              description: "Close \(tab.title)")
                }
                .padding(.horizontal, 10 * scale)
            }
            // item12: fixed width from the strip's budget (shrinks under
            // crowding). `clipped()` so the label cleanly truncates rather
            // than overflowing its neighbor when the tab is at the floor.
            .frame(width: width, height: 28 * scale)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()   // I-16a/I-07: tabs are clickable — say so
        .onHover { isHovering = $0 }
        .helpInfo(title: tab.title, description: tabHelpText)
        // `.contain`, NOT `.ignore` (AX tier bootstrap, 2026-07-31):
        // `.ignore` dropped every child — including the CLOSE BUTTON —
        // from the AX tree, making it unreachable to assistive clients
        // and the out-of-process AX driver alike
        // (`AXChromeInteractionTests` caught it). Same pattern as the
        // session pill; the tab also gets its own id so AX tests can
        // select a specific tab.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mdv.tab.item.\(tab.id.uuidString)")
    }

    private var background: Color {
        // I-16a (owner 2026-08-01): the ACTIVE tab wears the CONTENT
        // background (white in light mode) so it reads connected to the
        // document — replacing the accent tint; inactive tabs are grey
        // chips, hover brightens one toward active.
        if isSelected {
            return Palette.textBackground
        }
        if isHovering {
            return Palette.controlBackground.opacity(0.70)
        }
        return Palette.controlBackground.opacity(0.45)
    }

    private var tabHelpText: String {
        if let url = tab.url { return url.path }
        return tab.title
    }

    private var accessibilityLabel: String {
        let base = "Tab: \(tab.title)"
        return isSelected ? base + ", selected" : base
    }
}
