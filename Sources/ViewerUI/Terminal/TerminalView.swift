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
    /// Cycle terminal tabs (⌃Tab / ⌃⇧Tab). `true` = next. Provided by the
    /// pane (which owns the store); defaults to a no-op for previews/standalone.
    var onCycleTab: (Bool) -> Void = { _ in }
    /// New / close terminal tab (⌘T / ⌘W while focused).
    var onNewTab: () -> Void = {}
    var onCloseTab: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView(
            initialScreen: model.screenSnapshot,
            fontSize: fontSize
        )
        let coord = context.coordinator
        view.onInput = { data in coord.model.sendInput(data) }
        view.onResize = { rows, cols in coord.model.resize(rows: rows, cols: cols) }
        view.onCycleTab = onCycleTab
        view.onNewTab = onNewTab
        view.onCloseTab = onCloseTab
        // Spawn the shell on first appearance (idempotent).
        coord.model.start()
        // Grab keyboard focus once the view is in a window. Without this the
        // shell prompt renders but keystrokes go nowhere until the user happens
        // to click exactly on the grid (the reported "shows a prompt but won't
        // type" bug) — mouseDown-to-focus alone is too easy to miss. Deferred a
        // tick so the window/responder chain is wired.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
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

/// The bottom terminal pane: a tab strip (one chip per shell + a "+" to
/// add) over the selected tab's live terminal surface. Fixed-height; the
/// height, open state, and tab set are owned by `TerminalPaneStore`.
struct TerminalPaneView: View {
    @ObservedObject var store: TerminalPaneStore
    let fontSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ZStack {
                if let terminal = store.terminal {
                    // `.id(selectedTabID)` gives each tab its own NSView +
                    // coordinator, so switching tabs swaps the live surface
                    // rather than rebinding one view to a different model.
                    TerminalRepresentable(
                        model: terminal,
                        fontSize: fontSize,
                        onCycleTab: { forward in store.cycleTab(forward: forward) },
                        onNewTab: { store.addTab() },
                        onCloseTab: { if let id = store.selectedTabID { store.closeTab(id) } }
                    )
                    .id(store.selectedTabID)
                    if terminal.hasExited {
                        exitedOverlay(terminal)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.textBackground)
        .accessibilityIdentifier("mdv.terminal.pane")
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: fontSize * 0.85, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        tabChip(tab)
                    }
                }
            }

            Button { store.addTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: fontSize * 0.8, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("New terminal tab")
            .accessibilityIdentifier("mdv.terminal.newTab")

            Spacer(minLength: 0)

            if let t = store.terminal, t.hasExited {
                Button { t.restart() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Restart shell")
            }
            Button { store.setOpen(false) } label: {
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

    private func tabChip(_ tab: TerminalTab) -> some View {
        let selected = tab.id == store.selectedTabID
        return HStack(spacing: 4) {
            Text("\(tab.number)")
                .font(.system(size: fontSize * 0.8, weight: selected ? .semibold : .regular,
                              design: .monospaced))
                .foregroundStyle(selected ? Palette.labelColor : Palette.secondaryLabel)
            // Close affordance — only the selected tab shows it inline to
            // keep the strip tidy; any tab can be closed once selected.
            if selected && store.tabs.count > 1 {
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: fontSize * 0.62, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Close this tab")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(selected ? Palette.textBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Palette.separator : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(tab.id) }
        .accessibilityIdentifier("mdv.terminal.tab.\(tab.number)")
    }

    private func exitedOverlay(_ model: TerminalModel) -> some View {
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
