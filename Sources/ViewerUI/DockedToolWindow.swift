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

/// Process-wide "a tool-window drag is in flight" signal (owner
/// 2026-08-09): empty shoulders hide (TSK-1316), so without this there was
/// NOWHERE to drop an icon onto a bare edge — the reveal parameter existed
/// but nothing ever drove it. The shared drag-preview chip flips the flag
/// on appear/disappear (the preview lives exactly as long as the drag
/// session); a pressed-button poll is the belt-and-braces end signal in
/// case the preview teardown is ever swallowed.
@MainActor
final class PanelDragMonitor: ObservableObject {
    static let shared = PanelDragMonitor()
    @Published private(set) var isDragging = false
    private var pollTimer: Timer?

    func begin() {
        guard !isDragging else { return }
        isDragging = true
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            // Left button released ⇒ the drag session is over even if the
            // preview's onDisappear never fired.
            if NSEvent.pressedMouseButtons & 0x1 == 0 {
                Task { @MainActor in PanelDragMonitor.shared.end() }
            }
        }
    }

    func end() {
        pollTimer?.invalidate()
        pollTimer = nil
        if isDragging { isDragging = false }
    }
}

/// The shared drag-preview chip for a tool-window drag — used by every
/// drag source (docked header, accordion section header, rail icon) so
/// the affordance reads identically wherever the drag starts (TSK-327).
/// Doubles as the drag-session sensor for `PanelDragMonitor` (it appears
/// when the drag starts and disappears when it ends).
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
        .onAppear { PanelDragMonitor.shared.begin() }
        .onDisappear { PanelDragMonitor.shared.end() }
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

// (The TSK-1317 terminal drag-to-dock special case — TerminalDragPayload /
// TerminalDropZone / applyTerminalShoulderDrop — is GONE, owner rework
// 2026-08-09: the terminal is `SidebarPanelKind.terminal` and rides the
// ordinary `PanelDragPayload` / `panelDropZone` path like every panel.)

// MARK: - Docked tool windows (UX-E / #227)
//
// A "tool window" is a sidebar panel (Git, Problems, Outline, …) that the
// user has dragged off the classic LEFT accordion onto the RIGHT or
// BOTTOM rail. The two docks render differently (owner rework 2026-08-09):
//
//   * RIGHT  → each panel is a free-standing `DockedToolWindow` pane with a
//              fixed WIDTH; the user drags its LEADING (inner) edge.
//              Dragging inward (left) GROWS the width — with NO maximum
//              (brief item 2): the only bound is the live window edge,
//              enforced by the available-width clamp, never a constant.
//   * BOTTOM → the `BottomDockContainer` TAB BAND: one visible panel at a
//              time picked by a tab strip, over ONE shared resizable band
//              height (`PanelLayoutStore.bottomBandHeight`).
//
// FIXED-SIZE, NOT CONTENT-DRIVEN (brief item 1): pane sizes come from the
// store (`dockSize(_:on:)` for right widths, `bottomBandHeight` for the
// bottom band), NOT from the content's intrinsic size. The body is given
// the exact size and clipped, so a panel with 2 rows and a panel with 200
// rows occupy the identical pane.
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

// MARK: - Bottom-rail dock container (TABBED — owner rework 2026-08-09)

/// Renders the bottom dock as a TAB BAND: one visible panel at a time,
/// picked by a tab strip, over a SHARED resizable band height. The old
/// side-by-side columns split the band into unusable slivers as soon as
/// two panels were bottom-docked (owner screenshot 03:44) — tabs give
/// every panel the full width, like every IDE bottom panel.
///
///   ┌────────── 12px gutter band (drag = resize, grabber pill) ─────────┐
///   │ [◫ Git] [⚠ Problems] [🕓 Recent]              ⣿ move   ✕ hide │  ← tab strip
///   ├────────────────────────────────────────────────────────────────────┤
///   │                 selected panel body (full width)                   │
///   └────────────────────────────────────────────────────────────────────┘
///
/// Selection + band height persist on `PanelLayoutStore`
/// (`bottomSelection` / `bottomBandHeight`); `BottomDockTabs.resolve`
/// maps the stored choice onto the visible set (hidden choice → first).
/// Hosted below the content in `ContentView`'s center column.
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
    /// Balanced-push guard for the resize cursor (the UIRESP-10 pattern —
    // (resize cursor is region-based .pointerStyle now — 2026-08-22)
    private static let measureEpsilon: CGFloat = 0.5

    /// Selected-tab tint — the file-tab-strip idiom (light accent wash +
    /// solid accent bar), so "active tab" reads identically across strips.
    private static let selectedTabTint = Color.accentColor.opacity(0.25)

    private var visiblePanels: [SidebarPanelKind] {
        DockResolution.visiblePanels(
            on: .bottom, panelLayout: panelLayout,
            presence: DockResolution.presence(model: model, sidebar: sidebar, trackedRepos: trackedRepos)
        )
    }

    private var stripHeight: CGFloat { model.uiSize(26) }

    var body: some View {
        let panels = visiblePanels
        if !panels.isEmpty {
            let selected = BottomDockTabs.resolve(
                selection: panelLayout.bottomSelection, visible: panels)
            let bandHeight = liveBandHeight ?? panelLayout.bottomBandHeight
            VStack(spacing: 0) {
                resizeGutter
                tabStrip(panels: panels, selected: selected)
                Divider()
                if let selected {
                    SidebarPanelBody.make(
                        for: selected,
                        model: model, sidebar: sidebar,
                        trackedRepos: trackedRepos, panelLayout: panelLayout,
                        // Interior hint for sections that size their body as a
                        // fixed frame; the band frame + clip below are the
                        // hard envelope.
                        bodyHeight: max(60, bandHeight - stripHeight)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // FIXED-SIZE envelope: content overflow can never grow the
                    // band or bleed past it (the "Nothing staged" bleed class).
                    .clipped()
                }
            }
            // Band = strip + body; the 12px gutter rides on top of it.
            .frame(height: 12 + bandHeight)
            .background(Palette.textBackground)
            .background(heightReader)
        }
    }

    // MARK: strip

    private func tabStrip(panels: [SidebarPanelKind], selected: SidebarPanelKind?) -> some View {
        HStack(spacing: 2) {
            ForEach(panels) { kind in
                tabChip(kind, isSelected: kind == selected)
            }
            Spacer(minLength: 0)
            if let selected {
                redockMenu(for: selected)
                hideButton(for: selected)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: stripHeight)
        .background(Palette.windowBackground)
    }

    private func tabChip(_ kind: SidebarPanelKind, isSelected: Bool) -> some View {
        Button {
            panelLayout.selectBottomPanel(kind)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: model.uiSize(10), weight: .medium))
                Text(kind.displayName)
                    .font(.system(size: model.uiSize(11),
                                  weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Palette.labelColor : Palette.secondaryLabel)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(isSelected ? Self.selectedTabTint : Color.clear)
            .overlay(alignment: .top) {
                if isSelected {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingCursor()   // I-07: tabs are clickable — say so
        // The chip is a drag source like every tool-window header/icon
        // (TSK-327): drag it onto a shoulder to redock the panel.
        .draggable(PanelDragPayload(kind)) { PanelDragChip(kind: kind) }
        .contextMenu { moveMenuItems(for: kind) }
        .help(kind.displayName)
        .accessibilityIdentifier("mdv.dock.bottom.tab.\(kind.rawValue)")
    }

    private func moveMenuItems(for kind: SidebarPanelKind) -> some View {
        ForEach(PanelEdge.allCases, id: \.self) { dest in
            Button {
                panelLayout.move(kind, to: dest)
            } label: {
                Label("Move to \(dest.displayName)", systemImage: dest.systemImage)
            }
            .disabled(dest == .bottom || !PanelPlacement.isLegal(kind, to: dest))
        }
    }

    private func redockMenu(for kind: SidebarPanelKind) -> some View {
        Menu {
            moveMenuItems(for: kind)
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move this tool window to another dock")
        .accessibilityIdentifier("mdv.dock.bottom.redock")
    }

    private func hideButton(for kind: SidebarPanelKind) -> some View {
        Button {
            panelLayout.setOverride(kind, .hidden)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
        }
        .buttonStyle(.plain)
        .help("Hide this tool window")
        .accessibilityIdentifier("mdv.dock.bottom.close")
    }

    // MARK: resize

    /// The visible resize gutter across the top of the band — the sidebar
    /// divider idiom (owner 2026-08-09): the band you see IS the click
    /// target, with a centred grabber pill. Drag up → taller. No fixed
    /// maximum beyond the live window edge.
    private var resizeGutter: some View {
        ZStack {
            Rectangle()
                .fill(Palette.underPageBackground)
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 26, height: 3)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .resizePointer(vertical: true)   // 2026-08-22: off the leaky NSCursor stack
        .gesture(
            // .global — the gutter moves with the band; local-space
            // translation oscillates + half-tracks (see DraggableSidebar).
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? panelLayout.bottomBandHeight
                    if dragStartHeight == nil { dragStartHeight = start }
                    liveBandHeight = clampBand(start - value.translation.height)
                }
                .onEnded { _ in
                    if let h = liveBandHeight {
                        panelLayout.setBottomBandHeight(h)
                    }
                    liveBandHeight = nil
                    dragStartHeight = nil
                }
        )
        .accessibilityIdentifier("mdv.dock.bottom.resize")
    }

    /// Floor + live-window ceiling (leave ~160pt for the content above) —
    /// no fixed maximum. Pre-measurement falls back to the corruption
    /// ceiling.
    private func clampBand(_ raw: CGFloat) -> CGFloat {
        let floored = max(raw, PanelDockLayout.minSize)
        let ceiling = availableHeight > 0
            ? max(PanelDockLayout.minSize, availableHeight - 160)
            : PanelDockLayout.maxSize
        return min(floored, ceiling)
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
    /// off the window. Zero before measurement.
    let availableSpace: CGFloat

    /// Live WIDTH during a `.right` resize drag — applied as the frame so
    /// the store (and every section's @Published chain) isn't written
    /// 60 Hz; committed once in `.onEnded`. Same idiom as `DraggableSidebar`.
    @State private var liveWidth: CGFloat?
    /// Width at drag start — the FIXED base the whole drag is relative to.
    /// (The old code re-read `liveWidth` as the base each tick, integrating
    /// the CUMULATIVE translation twice — runaway growth on top of the
    /// local-space oscillation.)
    @State private var dragStartWidth: CGFloat?

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
            case .bottom, .left:
                // Not reachable — bottom panels render in the tabbed
                // `BottomDockContainer`; left panels render in the accordion.
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

    /// Interior height hint for the section body. Right panes fill the
    /// band's full window height; the section's ScrollView uses
    /// maxHeight:.infinity so this injected value is only a hint for
    /// sections that size their body as a fixed frame. A generous
    /// (zoom-scaled) value lets them fill rather than self-limit to the
    /// small accordion default.
    private var interiorBodyHeight: CGFloat {
        model.uiSize(560)
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
        // .contain — surface the header id to the out-of-process AX reader
        // (a bare container id may never materialize; 2026-08-01 rule).
        .accessibilityElement(children: .contain)
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
            .resizePointer(vertical: false)   // 2026-08-22: off the leaky NSCursor stack
            .gesture(
                // .global + fixed drag-start base — see DraggableSidebar.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? panelLayout.dockSize(kind, on: .right)
                        if dragStartWidth == nil { dragStartWidth = start }
                        // Drag LEFT (negative translation.width) grows width.
                        liveWidth = clampWidthToWindow(start - value.translation.width)
                    }
                    .onEnded { _ in
                        if let w = liveWidth {
                            panelLayout.setDockSize(w, for: kind, on: .right)
                        }
                        liveWidth = nil
                        dragStartWidth = nil
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
