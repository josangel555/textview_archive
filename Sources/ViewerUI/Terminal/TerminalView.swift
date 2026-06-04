import SwiftUI
import AppKit
import ViewerCore

/// `NSViewRepresentable` bridge for the direct-drawing `TerminalNSView`.
///
/// COMPOSITOR NOTE (LESSONS): the documented compositor pathology is
/// specific to an `NSTextView` inside an `NSScrollView` with a ruler —
/// the ruler's `tile()` forces a reentrant SwiftUI layout pass. This view
/// uses NEITHER a scroll view NOR a ruler NOR `NSTextView`; it's a plain
/// custom `NSView` painting into its own layer, so the pathology does not
/// apply. (We still keep it a sibling LATE in the outer VStack — below
/// the content band — so even the general "siblings before a hosted
/// AppKit view" caveat is moot.)
///
/// Observation: this view observes the `TerminalModel` DIRECTLY via
/// `@ObservedObject` and re-bodies only on the throttled `version` bump —
/// the model never republishes into `DocumentModel` (narrow pattern).
struct TerminalRepresentable: NSViewRepresentable {
    @ObservedObject var model: TerminalModel
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView(
            initialScreen: model.screenSnapshot,
            fontSize: fontSize
        )
        let coord = context.coordinator
        view.onInput = { data in coord.model.sendInput(data) }
        view.onResize = { rows, cols in coord.model.resize(rows: rows, cols: cols) }
        // Spawn the shell on first appearance (idempotent).
        coord.model.start()
        return view
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // Reading `model.version` in `body` is what makes SwiftUI call
        // this on a frame bump; pull the fresh snapshot + push it in.
        _ = model.version
        nsView.update(screen: model.screenSnapshot, fontSize: fontSize)
    }

    @MainActor
    final class Coordinator {
        let model: TerminalModel
        init(model: TerminalModel) { self.model = model }
    }
}

/// The bottom terminal pane: a thin header (title + restart/close) over
/// the live terminal surface. Fixed-height; the height + open state are
/// owned by `TerminalPaneStore` and persisted there.
struct TerminalPaneView: View {
    @ObservedObject var model: TerminalModel
    let fontSize: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                TerminalRepresentable(model: model, fontSize: fontSize)
                if model.hasExited {
                    exitedOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.textBackground)
        .accessibilityIdentifier("mdv.terminal.pane")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: fontSize * 0.85, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
            Text("Terminal")
                .font(.system(size: fontSize * 0.85, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
            Spacer(minLength: 0)
            if model.hasExited {
                Button {
                    model.restart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Restart shell")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close terminal")
            .accessibilityIdentifier("mdv.terminal.close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Palette.windowBackground)
    }

    private var exitedOverlay: some View {
        VStack(spacing: 8) {
            Text("[process exited]")
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.secondaryLabel)
            Button("Restart shell") { model.restart() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.textBackground.opacity(0.85))
    }
}

/// A thin draggable divider above the terminal pane. Dragging UP grows
/// the pane, DOWN shrinks it; `TerminalPaneStore.setHeight` clamps +
/// persists. Cursor flips to the vertical-resize arrow on hover.
struct TerminalResizeHandle: View {
    @ObservedObject var store: TerminalPaneStore
    /// Height captured at the start of a drag so deltas are absolute, not
    /// cumulative-per-frame.
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 5)
            .overlay(
                Rectangle().fill(Palette.windowBackground).frame(height: 3)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? store.height
                        if dragStartHeight == nil { dragStartHeight = start }
                        // Drag up (negative translation height) → taller.
                        store.setHeight(start - value.translation.height)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .accessibilityIdentifier("mdv.terminal.resize")
    }
}
