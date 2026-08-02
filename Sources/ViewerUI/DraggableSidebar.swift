import SwiftUI
import AppKit
import ViewerCore

struct DraggableSidebar: View {
    @ObservedObject var model: DocumentModel
    @State private var dragStart: Double?
    /// Drag-time width local; we apply this as the frame value during
    /// the drag so the model's `@Published sidebarWidth` setter — and
    /// the entire sidebar's @Published forwarding chain — doesn't
    /// fire ~60 Hz. The model's `setSidebarWidthLive` still gets the
    /// committed value at the end, and the @State change is local +
    /// cheap. Without this, every drag tick re-renders BookmarksSection
    /// / RecentChanges / SearchAnywhere / FileTree concurrently, which
    /// shows up as drag-handle jitter / lag.
    @State private var liveWidth: Double?

    private var currentWidth: Double {
        liveWidth ?? model.sidebarWidth
    }

    /// Minimum width the content area (editor/preview) keeps when the sidebar is
    /// dragged wide (TSK-918) — the sidebar can grow up to `window − this`.
    private static let minContentWidth: Double = 360

    var body: some View {
        // `panelLayout` + `trackedRepos` are read off the model and handed
        // to SidebarView so the accordion resolves per-panel visibility and
        // git badges through the SAME stores the rails / registry drive.
        // SidebarView observes both directly (`@ObservedObject`) — no
        // forwarding through DraggableSidebar.
        SidebarView(
            sidebar: model.sidebar,
            model: model,
            trackedRepos: model.trackedRepos,
            panelLayout: model.panelLayout
        )
            .frame(width: currentWidth)
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    // AX id so the resize drag tooth can grab the REAL strip
                    // (derived grab-points missed it — 2026-08-01).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("mdv.sidebar.widthHandle")
                    .onHover { hover in
                        if hover {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        // ⛔ .global, NOT the default .local (owner recording
                        // 2026-08-01): the handle MOVES with the resize, so
                        // local-space translation under-reports by the applied
                        // delta each frame — the width becomes an oscillator
                        // (flicker) tracking the pointer at HALF speed (the
                        // boundary trailed ~450px on a ~900px drag). Window
                        // space is static during the drag; translation exact.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? model.sidebarWidth
                                if dragStart == nil { dragStart = model.sidebarWidth }
                                // TSK-918: no fixed cap — clamp window-relative
                                // so the sidebar can grow freely yet never starve
                                // the content area (≥ minContentWidth). The live
                                // window width feeds the pure `PanelResize` clamp.
                                let raw = start + value.translation.width
                                let available = Double(
                                    NSApp.keyWindow?.contentView?.bounds.width ?? 1200)
                                liveWidth = PanelResize.clampWidth(
                                    raw, available: available,
                                    minContent: Self.minContentWidth,
                                    minPanel: PreferencesStore.minSidebarWidth)
                            }
                            .onEnded { _ in
                                if let w = liveWidth {
                                    model.setSidebarWidthLive(w)
                                    model.persistSidebarWidth()
                                }
                                liveWidth = nil
                                dragStart = nil
                            }
                    )
            }
    }
}
