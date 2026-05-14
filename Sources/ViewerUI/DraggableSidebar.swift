import SwiftUI
import AppKit

struct DraggableSidebar: View {
    @ObservedObject var model: DocumentModel
    @State private var dragStart: Double?

    var body: some View {
        SidebarView(sidebar: model.sidebar, model: model)
            .frame(width: model.sidebarWidth)
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
                                model.setSidebarWidth(start + value.translation.width)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}
