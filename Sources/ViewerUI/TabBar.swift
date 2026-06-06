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
    private static let minShrunkWidth: CGFloat = 54

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
        let tabWidth = Self.computedTabWidth(
            available: availableWidth,
            count: model.tabs.tabs.count,
            scale: CGFloat(model.zoom)
        )
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabBarItem(
                                tab: tab,
                                isSelected: model.tabs.selectedIndex == index,
                                isBookmarked: tab.url.map { model.bookmarksStore.contains($0) } ?? false,
                                scale: CGFloat(model.zoom),
                                width: tabWidth,
                                onSelect: { model.selectTab(at: index) },
                                onClose: { model.closeTab(at: index) }
                            )
                            // item12a: scroll anchor so the active tab can be
                            // brought into view via ScrollViewReader.
                            .id(tab.id)
                            .contextMenu {
                                TabContextMenu(model: model, tabIndex: index, tab: tab)
                            }
                            .onDrag {
                                // Encode the tab's stable id, not its index.
                                // Indices go stale the instant tabs reorder
                                // (another drag, a close, a programmatic
                                // move) between drag-start and drop, which
                                // would move the wrong tab. The id is
                                // resolved back to a live index at drop time.
                                NSItemProvider(object: NSString(string: "mdv-tab:\(tab.id.uuidString)"))
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: TabDropDelegate(model: model, targetID: tab.id)
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
                    }
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
            Button(action: { model.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: model.uiSize(11), weight: .medium))
                    .frame(width: model.uiSize(24), height: model.uiSize(24))
            }
            // UX-H (#230): shared icon style for hover/press feedback.
            .buttonStyle(IconHoverButtonStyle())
            // 0c: migrated to the uniform HelpInfo model — native tooltip
            // shows the title, the status bar shows the longer description
            // on hover, and a11y label/hint are set from the same source.
            .helpInfo(title: "New Tab (⌘T)",
                      description: "Open a new empty tab in the current session")
            .padding(.horizontal, model.uiSize(4))
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

private struct TabDropDelegate: DropDelegate {
    let model: DocumentModel
    let targetID: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String,
                  str.hasPrefix("mdv-tab:"),
                  let srcID = UUID(uuidString: String(str.dropFirst("mdv-tab:".count))) else { return }
            Task { @MainActor in
                Self.reorder(model: self.model, srcID: srcID, targetID: self.targetID)
            }
        }
        return true
    }

    /// Resolve both the dragged tab and the drop-target tab back to
    /// live indices *at drop time* (not at drag-start), then move.
    /// Index-based payloads went stale whenever the strip reordered
    /// between picking up a tab and dropping it; resolving by id here
    /// always targets the tabs the user actually grabbed and aimed at,
    /// and bails cleanly if either has since been closed.
    @MainActor
    static func reorder(model: DocumentModel, srcID: UUID, targetID: UUID) {
        guard srcID != targetID else { return }
        let tabs = model.tabs.tabs
        guard let src = tabs.firstIndex(where: { $0.id == srcID }),
              let target = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        // Drop onto a row → place the dragged tab in that row's
        // position; the target tab slides to the other side.
        let dst = src < target ? target + 1 : target
        model.moveTab(from: src, to: dst)
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
            Button("Reveal in Finder") { Finder.reveal(url) }
            Button("Reveal in Sidebar") {
                model.revealInSidebar(url)
            }
        }
    }
}

struct TabBarItem: View {
    let tab: ViewerCore.Tab
    let isSelected: Bool
    let isBookmarked: Bool
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
                        // Bold current tab so the active document is
                        // obvious at a glance.
                        .font(.system(size: 12 * scale, weight: isSelected ? .semibold : .regular))
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
                    if isBookmarked {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8 * scale))
                            .foregroundStyle(.yellow)
                            .helpInfo(title: "Bookmarked",
                                      description: "This file is bookmarked")
                            .accessibilityLabel("Bookmarked")
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
        .onHover { isHovering = $0 }
        .helpInfo(title: tab.title, description: tabHelpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(0.18)
        }
        if isHovering {
            return Palette.controlBackground.opacity(0.4)
        }
        return Color.clear
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
