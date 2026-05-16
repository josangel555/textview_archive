import SwiftUI
import AppKit
import ViewerCore

/// Position-agnostic Git panel: tab strip + body. Renders no outer
/// chrome — the host (sidebar accordion, dock pane, detached window)
/// decides on titlebars / collapse controls.
///
/// To host elsewhere later, instantiate `GitPanelView(model:doc:)` in
/// the new container; nothing in this view assumes a sidebar.
struct GitPanelView: View {
    @ObservedObject var model: GitPanelModel
    /// The document model is needed only for opening diff tabs + the
    /// uiSize font scale. Kept as a separate handle so the panel can
    /// later be rewritten against a thinner "host" protocol.
    @ObservedObject var doc: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            body(for: model.selectedTab)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(
            // Window-key observer for the on-focus refresh contract.
            WindowKeyObserver(onBecomeKey: { model.windowDidBecomeKey() })
        )
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(GitPanelModel.Tab.allCases) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
            refreshButton
        }
        .frame(height: 26)
        .padding(.horizontal, 6)
    }

    private func tabButton(_ tab: GitPanelModel.Tab) -> some View {
        let isActive = (model.selectedTab == tab)
        return Button(action: { model.selectTab(tab) }) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: doc.uiSize(10), weight: .semibold))
                    .textCase(.uppercase)
                if let n = model.count(for: tab) {
                    Text("\(n)")
                        .font(.system(size: doc.uiSize(9), weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mdv.gitpanel.tab.\(tab.rawValue)")
    }

    private var refreshButton: some View {
        Button(action: { model.refreshCurrent() }) {
            Image(systemName: model.isRefreshing
                  ? "arrow.triangle.2.circlepath"
                  : "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeating, isActive: model.isRefreshing)
        }
        .buttonStyle(.plain)
        .help("Refresh")
        .keyboardShortcut("r", modifiers: [.command, .option])
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for tab: GitPanelModel.Tab) -> some View {
        switch tab {
        case .status:  GitStatusTab(model: model, doc: doc)
        case .log:     GitLogTab(model: model, doc: doc)
        case .stash:   GitStashTab(model: model, doc: doc)
        case .trees:   GitWorktreesTab(model: model, doc: doc)
        case .remotes: GitRemotesTab(model: model)
        }
    }
}

// MARK: - Window-key observer

/// Tiny NSViewRepresentable that fires a closure when the host window
/// receives `didBecomeKeyNotification`. SwiftUI's `scenePhase` covers
/// app-level activation but not window-level key changes, which is what
/// the refresh contract is keyed on.
private struct WindowKeyObserver: NSViewRepresentable {
    let onBecomeKey: @Sendable () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        let cb = onBecomeKey
        DispatchQueue.main.async {
            context.coordinator.attach(to: v.window, onBecomeKey: cb)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let cb = onBecomeKey
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window, onBecomeKey: cb)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?
        private var attachedWindow: NSWindow?

        func attach(to window: NSWindow?, onBecomeKey: @escaping @Sendable () -> Void) {
            guard window !== attachedWindow else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            attachedWindow = window
            guard let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in onBecomeKey() }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
