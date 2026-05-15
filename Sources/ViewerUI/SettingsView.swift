import AppKit
import SwiftUI
import ViewerCore

/// Kitchen-sink Settings page. Single page, no tabs, every knob flat
/// so it's obvious what exists. Tabs/categories can wait until we
/// have enough settings to actually need them.
///
/// Open via Cmd+, (App menu → Settings…). The host is a small
/// AppKit window wrapped around an `NSHostingController`. We keep
/// the AppKit boundary OUTSIDE the SwiftUI hierarchy (LESSONS.md):
/// a fresh window with one HostingController as its content view
/// has no sibling-blank concerns.
public struct SettingsView: View {
    @ObservedObject var model: DocumentModel

    public init(model: DocumentModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                appearanceSection
                Divider()
                editorSection
                Divider()
                viewerSection
                Divider()
                advancedSection
            }
            .padding(20)
        }
        .frame(width: 460, height: 540)
    }

    private var appearanceSection: some View {
        section("Appearance") {
            row("Theme") {
                Picker("", selection: themeBinding) {
                    Text("Follow System").tag(Optional<SyntaxTheme.Name>.none)
                    Text("Xcode Light").tag(Optional(SyntaxTheme.Name.xcodeLight))
                    Text("Xcode Dark").tag(Optional(SyntaxTheme.Name.xcodeDark))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }
            row("Zoom") {
                Slider(
                    value: $model.zoom,
                    in: PreferencesStore.minZoom...PreferencesStore.maxZoom,
                    step: PreferencesStore.zoomStep
                )
                .frame(width: 180)
                Text("\(Int(model.zoom * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
        }
    }

    private var editorSection: some View {
        section("Editor") {
            row("Wrap long lines") {
                Toggle("", isOn: $model.sourceWordWrap).labelsHidden()
            }
        }
    }

    private var viewerSection: some View {
        section("Sidebar") {
            row("Show sidebar by default") {
                Toggle("", isOn: Binding(
                    get: { model.sidebar.isVisible },
                    set: { model.sidebar.isVisible = $0 }
                )).labelsHidden()
            }
            row("Width") {
                Slider(
                    value: $model.sidebarWidth,
                    in: PreferencesStore.minSidebarWidth...PreferencesStore.maxSidebarWidth
                )
                .frame(width: 180)
                Text("\(Int(model.sidebarWidth))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
        }
    }

    private var advancedSection: some View {
        section("Advanced") {
            row("Clear bookmarks") {
                Button("Clear All") { model.clearBookmarks() }
            }
            row("Reset window state") {
                Button("Reset") {
                    UserDefaults.standard.removeObject(forKey: "MarkdownViewer.sidebarWidth")
                    UserDefaults.standard.removeObject(forKey: "MarkdownViewer.zoom")
                }
            }
            Text("Quit and relaunch for window reset to take effect.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    private var themeBinding: Binding<SyntaxTheme.Name?> {
        Binding(
            get: { model.themeOverride },
            set: { model.themeOverride = $0 }
        )
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ body: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 6) { body() }
                .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func row<Content: View>(
        _ label: String,
        @ViewBuilder _ body: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 200, alignment: .leading)
                .foregroundStyle(.secondary)
            body()
            Spacer(minLength: 0)
        }
    }
}

/// Manages a single settings window across re-opens (Cmd+, doesn't
/// stack windows). Lives in `AppDelegate` via this small holder.
public final class SettingsWindowController {
    private var window: NSWindow?

    public init() {}

    @MainActor
    public func show(model: DocumentModel) {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "MarkdownViewer Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
