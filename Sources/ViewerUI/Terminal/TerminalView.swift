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
            fontSize: fontSize,
            // Restore the per-tab scroll position so a tab switch (which
            // recreates this view via `.id`) doesn't snap back to the
            // bottom. TSK-489.
            initialScrollOffset: model.scrollOffset
        )
        let coord = context.coordinator
        view.onInput = { data in coord.model.sendInput(data) }
        view.onResize = { rows, cols in coord.model.resize(rows: rows, cols: cols) }
        view.onCycleTab = onCycleTab
        view.onNewTab = onNewTab
        view.onCloseTab = onCloseTab
        view.onScrollOffsetChange = { off in coord.model.scrollOffset = off }
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
        // Strip placement (TSK-488): left (default) / top / right. The strip
        // runs vertically for left/right, horizontally for top.
        Group {
            switch store.tabPosition {
            case .top:
                VStack(spacing: 0) {
                    horizontalTabStrip
                    Divider()
                    terminalSurface
                }
            case .left:
                HStack(spacing: 0) {
                    verticalTabStrip
                    Divider()
                    terminalSurface
                }
            case .right:
                HStack(spacing: 0) {
                    terminalSurface
                    Divider()
                    verticalTabStrip
                }
            }
        }
        .background(Palette.textBackground)
        .accessibilityIdentifier("mdv.terminal.pane")
    }

    /// The live terminal surface for the selected tab. `.id(selectedTabID)`
    /// gives each tab its own NSView + coordinator so switching swaps the
    /// surface rather than rebinding one view to a different model. (Scroll
    /// position survives the swap because it lives on the per-tab
    /// `TerminalModel`, not the view — TSK-489.)
    private var terminalSurface: some View {
        ZStack {
            if let terminal = store.terminal {
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

    /// Horizontal strip (tab position = top).
    private var horizontalTabStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: fontSize * 0.85, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
            HStack(spacing: 4) { ForEach(store.tabs) { tabChip($0, fillWidth: false) } }
            newTabButton
            Spacer(minLength: 0)
            restartButtonIfExited
            closePaneButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Palette.windowBackground)
    }

    /// Vertical strip (tab position = left/right) — a fixed-width column.
    private var verticalTabStrip: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: fontSize * 0.85, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
            VStack(spacing: 4) { ForEach(store.tabs) { tabChip($0, fillWidth: true) } }
            newTabButton
            Spacer(minLength: 0)
            restartButtonIfExited
            closePaneButton
        }
        .frame(width: max(46, fontSize * 3.6))
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Palette.windowBackground)
    }

    private var newTabButton: some View {
        Button { store.addTab() } label: {
            Image(systemName: "plus").font(.system(size: fontSize * 0.8, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("New terminal tab")
        .accessibilityIdentifier("mdv.terminal.newTab")
    }

    @ViewBuilder
    private var restartButtonIfExited: some View {
        if let t = store.terminal, t.hasExited {
            Button { t.restart() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Restart shell")
        }
    }

    private var closePaneButton: some View {
        Button { store.setOpen(false) } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .help("Close terminal")
            .accessibilityIdentifier("mdv.terminal.close")
    }

    /// A single terminal tab, rendered as an explicit chip so it reads as a
    /// tab even when there's only one (owner: "even if only one tab, show
    /// tab"). Selected → accent-filled with white text; unselected →
    /// control-filled with a hairline border. `fillWidth` makes the chip
    /// span the vertical rail (left/right) so the column looks like stacked
    /// tabs; the horizontal (top) strip leaves chips at their natural width.
    private func tabChip(_ tab: TerminalTab, fillWidth: Bool) -> some View {
        let selected = tab.id == store.selectedTabID
        return HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: fontSize * 0.72, weight: .semibold))
            Text("\(tab.number)")
                .font(.system(size: fontSize * 0.92, weight: .bold, design: .monospaced))
            // Close affordance — only the selected tab shows it inline to
            // keep the strip tidy; any tab can be closed once selected.
            if selected && store.tabs.count > 1 {
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: fontSize * 0.72))
                }
                .buttonStyle(.plain)
                .help("Close this tab")
            }
        }
        .foregroundStyle(selected ? Color.white : Palette.labelColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: 28)
        // Selected → the user's ACCENT colour (always vivid, even when the
        // strip isn't first responder — `selectedContentBackgroundColor`
        // renders MUTED/grey when unemphasised, which made the single tab
        // blend into the rail: the "I see a gap but no tabs" report).
        // Unselected → a filled control chip with a hairline border so it
        // still reads as a tab.
        .background(selected ? Color.accentColor : Palette.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.accentColor : Palette.separator, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(tab.id) }
        .help("Terminal \(tab.number)")
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
