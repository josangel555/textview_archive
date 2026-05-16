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

    var body: some View {
        SidebarView(sidebar: model.sidebar, model: model)
            .frame(width: currentWidth)
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { hover in
                        if hover {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? model.sidebarWidth
                                if dragStart == nil { dragStart = model.sidebarWidth }
                                // Clamp at the controller so dragging
                                // off-screen doesn't produce silly widths.
                                let raw = start + value.translation.width
                                let clamped = min(
                                    max(raw, PreferencesStore.minSidebarWidth),
                                    PreferencesStore.maxSidebarWidth
                                )
                                liveWidth = clamped
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
