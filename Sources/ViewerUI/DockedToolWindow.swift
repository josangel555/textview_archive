import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ViewerCore

// MARK: - Drag-to-snap payload (UX-E / #227)

/// The transferable payload a tool-window drag carries: just the panel's
/// raw-value identity. The shoulder rails (+ the left sidebar) are
/// `.dropDestination`s for this type; dropping calls
/// `panelLayout.move(kind, to: edge)` — the snap. Using SwiftUI's native
/// `Transferable` drag-and-drop keeps the snap mechanism declarative and
/// cross-pane without a bespoke window-level pointer tracker.
struct PanelDragPayload: Codable, Transferable {
    let rawKind: String

    init(_ kind: SidebarPanelKind) { self.rawKind = kind.rawValue }

    var kind: SidebarPanelKind? { SidebarPanelKind(rawValue: rawKind) }

    static var transferRepresentation: some TransferRepresentation {
        // A custom content type so a tool-window drag is recognized ONLY by
        // our rails — it won't be mistaken for a file drop or hijack another
        // drop target.
        CodableRepresentation(contentType: .mdvPanelDrag)
    }
}

extension UTType {
    /// Custom UTI for an in-app tool-window drag (UX-E / #227). Declared
    /// in the app's Info.plist `UTExportedTypeDeclarations` (TSK-327):
    /// `UTType(exportedAs:)` types MUST be declared there — an undeclared
    /// exported UTI is the classic silently-dead drag/drop (the payload
    /// writes but no `dropDestination` ever accepts it).
    static let mdvPanelDrag = UTType(exportedAs: "com.markdownviewer.panel-drag")
}

/// The shared drag-preview chip for a tool-window drag — used by every
/// drag source (docked header, accordion section header, rail icon) so
/// the affordance reads identically wherever the drag starts (TSK-327).
struct PanelDragChip: View {
    let kind: SidebarPanelKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
            Text(kind.displayName)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.windowBackground)
    }
}

// MARK: - Rail drop-zone modifier

/// Makes a shoulder rail (or the sidebar) a SNAP ZONE for a dragged tool
/// window. On hover-while-dragging it shows an accent overlay (the snap
/// affordance); on drop it redocks the panel to `edge`.
struct PanelDropZone: ViewModifier {
    let edge: PanelEdge
    @ObservedObject var panelLayout: PanelLayoutStore
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("mdv.dock.snapZone.\(edge.rawValue)")
                }
            }
            .dropDestination(for: PanelDragPayload.self) { payloads, _ in
                guard let kind = payloads.first?.kind else { return false }
                panelLayout.move(kind, to: edge)
                return true
            } isTargeted: { targeted = $0 }
    }
}

extension View {
    /// Apply the tool-window snap drop-zone for `edge`.
    func panelDropZone(_ edge: PanelEdge, panelLayout: PanelLayoutStore) -> some View {
        modifier(PanelDropZone(edge: edge, panelLayout: panelLayout))
    }
}

// MARK: - Docked tool windows (UX-E / #227)
//
// A "tool window" is a sidebar panel (Git, Problems, Outline, …) that the
// user has dragged off the classic LEFT accordion onto the RIGHT or
// BOTTOM rail. Unlike an accordion section (whose body height is one of N
// stacked, window-clamped slices), a docked tool window is a free-standing
// pane with a single FIXED, user-controlled size:
//
//   * RIGHT  → a fixed WIDTH; the pane fills the band's height, the user
//              drags its LEADING (inner) edge. Dragging inward (left) GROWS
//              the width — with NO maximum (brief item 2): the only bound
//              is the live window edge, enforced by the available-width
//              clamp, never a constant.
//   * BOTTOM → a fixed HEIGHT; the pane fills the band's width, the user
//              drags its TOP edge (drag up = taller), like the terminal.
//
// FIXED-HEIGHT, NOT CONTENT-DRIVEN (brief item 1): the pane's size comes
// from `panelLayout.dockSize(_:on:)` (persisted via `PanelDockLayout`),
// NOT from the content's intrinsic size. The body is given the exact size
// and clipped, so a panel with 2 rows and a panel with 200 rows occupy the
// identical pane.
//
// FLICKER-FREE RESIZE (brief item 3 + LESSONS.md): the drag drives a local
// `@State` size (`liveWidth` for a right pane; `liveBandHeight` on the
// bottom container) applied as the frame during the drag, so the store —
// and every section's @Published forwarding — isn't written ~60 Hz; the
// committed size lands once in `.onEnded`. The available-space measurement
// uses a NON-layout-driving `.background(GeometryReader)` with an
// epsilon-guarded write (the documented pattern that avoids the
// measure→frame→measure feedback that manifests as resize flicker). No
// wrapping GeometryReader drives the pane's own frame.

// MARK: - Right-rail dock container

/// Renders the run of RIGHT-docked tool windows that resolve visible,
/// stacked top-to-bottom, each a fixed-WIDTH pane. The whole column shares
/// one width per panel (each panel owns its own remembered width). Hosted
/// between the center column and the right shoulder rail in `ContentView`.
struct RightDockContainer: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var trackedRepos: TrackedReposChannel
    @ObservedObject var panelLayout: PanelLayoutStore

    /// Live available WIDTH of the window's content region, captured by a
    /// non-layout-driving background reader. Caps the resize so a panel
    /// can't be dragged wider than the window (the live edge bound that
    /// replaces a hard maximum).
    @State private var availableWidth: CGFloat = 0

    private static let measureEpsilon: CGFloat = 0.5

    /// Right-docked panels that resolve visible, in registry order.
    private var visiblePanels: [SidebarPanelKind] {
        DockResolution.visiblePanels(
            on: .right, panelLayout: panelLayout,
            presence: DockResolution.presence(model: model, sidebar: sidebar, trackedRepos: trackedRepos)
        )
    }

    var body: some View {
        let panels = visiblePanels
        if !panels.isEmpty {
            VStack(spacing: 0) {
                ForEach(panels) { kind in
                    if kind != panels.first { Divider() }
                    DockedToolWindow(
                        kind: kind, edge: .right,
                        model: model, sidebar: sidebar,
                        trackedRepos: trackedRepos, panelLayout: panelLayout,
                        availableSpace: availableWidth
                    )
                }
            }
            .frame(maxHeight: .infinity)
            // Measure the window's content width WITHOUT driving layout, so
            // the per-pane resize can clamp to "no wider than the window".
            .background(widthReader)
        }
    }

    private var widthReader: some View {
        GeometryReader { geo in
            // The dock is RIGHT-anchored against the right shoulder rail, so
            // its trailing edge (global maxX) is fixed regardless of how wide
            // the panes grow (they grow leftward). That gives a STABLE upper
            // reference for the resize bound — it doesn't feed back into the
            // pane width. There is intentionally NO fixed maximum (brief #2);
            // this only stops a drag from pushing the panes off the window's
            // left edge. Approximate (absolute coords) — the floor + the
            // corruption ceiling are the hard guarantees.
            let w = geo.frame(in: .global).maxX
            Color.clear
                .onAppear { availableWidth = w }
                .onChange(of: w) { _, new in
                    if abs(new - availableWidth) > Self.measureEpsilon {
                        availableWidth = new
                    }
                }
        }
    }
}

// MARK: - Bottom-rail dock container

/// Renders the run of BOTTOM-docked tool windows that resolve visible,
/// laid out side-by-side, each a fixed-HEIGHT pane sharing the band's
/// height. Hosted below the content (and the terminal pane) in
/// `ContentView`'s center column.
struct BottomDockContainer: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var trackedRepos: TrackedReposChannel
    @ObservedObject var panelLayout: PanelLayoutStore

    @State private var availableHeight: CGFloat = 0
    /// Live band height during a resize drag — applied to the band frame so
    /// the store (and every section's @Published chain) isn't written
    /// ~60 Hz; committed once in `.onEnded`. Flicker-free (LESSONS): the
    /// band frame tracks this @State 1:1, no measure→frame→measure loop.
    @State private var liveBandHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?
    private static let measureEpsilon: CGFloat = 0.5

    private var visiblePanels: [SidebarPanelKind] {
        DockResolution.visiblePanels(
            on: .bottom, panelLayout: panelLayout,
            presence: DockResolution.presence(model: model, sidebar: sidebar, trackedRepos: trackedRepos)
        )
    }

    var body: some View {
        let panels = visiblePanels
        if !panels.isEmpty {
            // All bottom-docked panels share ONE band height (driven by the
            // first panel's stored height). The container owns the single
            // resize handle + the live drag, so the band tracks the cursor
            // 1:1 even with multiple side-by-side panes. Columns split width.
            let driver = panels[0]
            let bandHeight = liveBandHeight ?? panelLayout.dockSize(driver, on: .bottom)
            VStack(spacing: 0) {
                bandResizeHandle(driver: driver)
                HStack(spacing: 0) {
                    ForEach(panels) { kind in
                        if kind != panels.first { Divider() }
                        DockedToolWindow(
                            kind: kind, edge: .bottom,
                            model: model, sidebar: sidebar,
                            trackedRepos: trackedRepos, panelLayout: panelLayout,
                            availableSpace: availableHeight,
                            // The container owns the band resize, so the pane
                            // itself draws no handle; it just fills the band.
                            fixedBandHeight: bandHeight
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: bandHeight)
            }
            .background(heightReader)
        }
    }

    /// The single top-edge resize handle for the whole bottom band. Drag up
    /// → taller (like the terminal). No maximum beyond the live window edge.
    private func bandResizeHandle(driver: SidebarPanelKind) -> some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 5)
            .overlay(Rectangle().fill(Palette.windowBackground).frame(height: 3))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? panelLayout.dockSize(driver, on: .bottom)
                        if dragStartHeight == nil { dragStartHeight = start }
                        let raw = start - value.translation.height
                        let floored = max(raw, PanelDockLayout.minSize)
                        // Clamp to the live window edge (leave ~160pt for the
                        // content above) — no fixed maximum.
                        let ceiling = availableHeight > 0
                            ? max(PanelDockLayout.minSize, availableHeight - 160)
                            : PanelDockLayout.maxSize
                        liveBandHeight = min(floored, ceiling)
                    }
                    .onEnded { _ in
                        if let h = liveBandHeight {
                            panelLayout.setDockSize(h, for: driver, on: .bottom)
                        }
                        liveBandHeight = nil
                        dragStartHeight = nil
                    }
            )
            .accessibilityIdentifier("mdv.dock.bottom.resize")
    }

    private var heightReader: some View {
        GeometryReader { geo in
            let h = geo.frame(in: .global).maxY
            Color.clear
                .onAppear { availableHeight = h }
                .onChange(of: h) { _, new in
                    if abs(new - availableHeight) > Self.measureEpsilon {
                        availableHeight = new
                    }
                }
        }
    }
}

// MARK: - Single docked tool window

/// One free-standing tool window: a header (title + redock menu + close)
/// over the shared panel body, plus a resize handle on the inner edge.
struct DockedToolWindow: View {
    let kind: SidebarPanelKind
    let edge: PanelEdge
    @ObservedObject var model: DocumentModel
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var trackedRepos: TrackedReposChannel
    @ObservedObject var panelLayout: PanelLayoutStore
    /// Live available space on the RIGHT pane's resize axis (window width)
    /// — the upper bound for a width drag, so the pane can never be dragged
    /// off the window. For `.bottom` panes this is the window height (used
    /// only for the interior-body sizing fallback). Zero before measurement.
    let availableSpace: CGFloat
    /// For a `.bottom` pane, the band height the container resolved (shared
    /// across all side-by-side bottom panes; the container owns the single
    /// resize handle + live drag). Ignored for `.right`.
    var fixedBandHeight: CGFloat = PanelDockLayout.defaultBottomHeight

    /// Live WIDTH during a `.right` resize drag — applied as the frame so
    /// the store (and every section's @Published chain) isn't written
    /// 60 Hz; committed once in `.onEnded`. Same idiom as `DraggableSidebar`.
    @State private var liveWidth: CGFloat?

    /// Resolved fixed WIDTH for a `.right` pane: the live drag value if
    /// dragging, else the persisted store value. Content-independent.
    private var resolvedWidth: CGFloat {
        liveWidth ?? panelLayout.dockSize(kind, on: .right)
    }

    var body: some View {
        Group {
            switch edge {
            case .right:
                HStack(spacing: 0) {
                    // Resize handle on the LEADING (inner) edge of the pane.
                    rightResizeHandle
                    paneColumn
                        .frame(width: resolvedWidth)
                }
            case .bottom:
                // The container owns the band height + its single resize
                // handle; an individual bottom pane just fills the band.
                paneColumn
                    .frame(maxHeight: .infinity)
            case .left:
                // Not reachable — left panels render in the accordion.
                paneColumn
            }
        }
    }

    /// Header over the shared panel body.
    private var paneColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SidebarPanelBody.make(
                for: kind,
                model: model,
                sidebar: sidebar,
                trackedRepos: trackedRepos,
                panelLayout: panelLayout,
                // Inject the pane's interior height as the section body
                // height so the section's inner ScrollView fills the tool
                // window (fixed, content-independent) rather than the
                // accordion clamp.
                bodyHeight: interiorBodyHeight
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // FIXED-SIZE envelope: clip so a content overflow can't grow
            // the pane past its user-set size (brief item 1).
            .clipped()
        }
        .background(Palette.textBackground)
    }

    /// Interior height available to the section body. For a `.bottom` pane
    /// it's the band height minus the header; for `.right` it's flexible
    /// (the column fills the band), so we pass a generous value and let the
    /// section's own `maxHeight` fill.
    private var interiorBodyHeight: CGFloat {
        switch edge {
        case .bottom:
            return max(60, fixedBandHeight - model.uiSize(Self.headerHeight))
        case .right, .left:
            // Right panes fill the band's full window height; the section's
            // ScrollView uses maxHeight:.infinity so this injected value is
            // only a hint for sections that size their body as a fixed
            // frame. A generous (zoom-scaled) value lets them fill rather
            // than self-limit to the small accordion default.
            return model.uiSize(560)
        }
    }

    private static let headerHeight: CGFloat = 26

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: model.uiSize(11), weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
            Text(kind.displayName)
                .font(.system(size: model.uiSize(11), weight: .semibold))
                .foregroundStyle(Palette.secondaryLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
            redockMenu
            closeButton
        }
        .padding(.horizontal, 8)
        .frame(height: model.uiSize(Self.headerHeight))
        .background(Palette.windowBackground)
        .contentShape(Rectangle())
        // DRAG-TO-SNAP (UX-E / #227): the whole header is the drag handle.
        // Dragging it onto another dock's snap zone (a shoulder rail or the
        // sidebar — `panelDropZone`) redocks the panel. The redock menu is
        // the explicit, discoverable alternative.
        .draggable(PanelDragPayload(kind)) {
            // Drag preview: a compact chip naming the panel.
            PanelDragChip(kind: kind)
        }
        .accessibilityIdentifier("mdv.dock.\(edge.rawValue).\(kind.rawValue).header")
    }

    /// Explicit redock control — the discoverable, always-works counterpart
    /// to drag-to-snap. Moving a panel updates its dock assignment in the
    /// store (persisted) via `panelLayout.move`.
    private var redockMenu: some View {
        Menu {
            ForEach(PanelEdge.allCases, id: \.self) { dest in
                Button {
                    panelLayout.move(kind, to: dest)
                } label: {
                    Label("Move to \(dest.displayName)", systemImage: dest.systemImage)
                }
                // Grey the current dock + any illegal placement (the
                // placement validator is the single arbiter of legality).
                .disabled(dest == edge || !PanelPlacement.isLegal(kind, to: dest))
            }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move this tool window to another dock")
        .accessibilityIdentifier("mdv.dock.\(edge.rawValue).\(kind.rawValue).redock")
    }

    private var closeButton: some View {
        Button {
            // Closing a docked tool window hides the panel (explicit
            // `.hidden`). Its rail button can bring it back.
            panelLayout.setOverride(kind, .hidden)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
        }
        .buttonStyle(.plain)
        .help("Hide this tool window")
        .accessibilityIdentifier("mdv.dock.\(edge.rawValue).\(kind.rawValue).close")
    }

    // MARK: - Resize handle

    /// Vertical resize handle on the LEADING (inner) edge of a `.right`
    /// pane. Drag inward (left) → wider, with NO fixed maximum (brief #2):
    /// the only upper bound is the live window edge.
    private var rightResizeHandle: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: 5)
            .overlay(Rectangle().fill(Palette.windowBackground).frame(width: 3))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = liveWidth ?? panelLayout.dockSize(kind, on: .right)
                        if liveWidth == nil { liveWidth = start }
                        // Drag LEFT (negative translation.width) grows width.
                        let raw = start - value.translation.width
                        liveWidth = clampWidthToWindow(raw)
                    }
                    .onEnded { _ in
                        if let w = liveWidth {
                            panelLayout.setDockSize(w, for: kind, on: .right)
                        }
                        liveWidth = nil
                    }
            )
            .accessibilityIdentifier("mdv.dock.right.\(kind.rawValue).resize")
    }

    /// Clamp a candidate WIDTH to the floor and the live window edge. NO
    /// fixed maximum — the only upper bound is the window itself (leave
    /// ~200pt for the sidebar + content). Before measurement
    /// (`availableSpace <= 0`) fall back to the corruption ceiling.
    private func clampWidthToWindow(_ raw: CGFloat) -> CGFloat {
        let floored = max(raw, PanelDockLayout.minSize)
        guard availableSpace > 0 else {
            return min(floored, PanelDockLayout.maxSize)
        }
        let windowCeiling = max(PanelDockLayout.minSize, availableSpace - 200)
        return min(floored, windowCeiling)
    }
}

// MARK: - Dock resolution helper

/// Shared resolution logic for which panels are docked + visible on a
/// given non-left edge. Pure read off the stores; centralised so the
/// right + bottom containers (and the snap-zone overlay) agree.
@MainActor
enum DockResolution {
    /// The per-panel data-presence map for the current model state — the
    /// SAME heuristic the rails + accordion read (`SidebarDataPresence`),
    /// so a docked panel's visibility agrees with its rail button.
    static func presence(
        model: DocumentModel, sidebar: SidebarModel, trackedRepos: TrackedReposChannel
    ) -> [SidebarPanelKind: Bool] {
        SidebarDataPresence.evaluate(
            SidebarDataPresence.Inputs(
                hasRoot: sidebar.rootURL != nil,
                hasRepo: trackedRepos.trackedRoots.isEmpty == false,
                hasLSPLanguage: model.currentURL.flatMap {
                    LSPLanguageRegistry.default.language(for: $0)
                } != nil,
                claudeHasTranscripts: sidebar.claudeHasTranscripts,
                hasRecents: model.recents.isEmpty == false
            )
        )
    }

    /// Panels docked to `edge` that resolve visible, in registry order.
    static func visiblePanels(
        on edge: PanelEdge,
        panelLayout: PanelLayoutStore,
        presence: [SidebarPanelKind: Bool]
    ) -> [SidebarPanelKind] {
        panelLayout.railPanels(on: edge).filter { kind in
            // A non-dockable panel (FILES) is never a free-standing tool
            // window. Single source of truth: `isDockable`, the same rule
            // `PanelPlacement` enforces at assignment time — so a panel
            // can't be both rejected by the validator yet shown here.
            kind.isDockable
                && panelLayout.isVisible(kind, dataPresent: presence[kind] ?? false)
        }
    }
}
