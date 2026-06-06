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
    /// PERF #1: `Show sidebar by default` is a Toggle bound to
    /// `sidebar.isVisible`; direct observation keeps the toggle in
    /// sync without DocumentModel-wide republish.
    @ObservedObject var sidebar: SidebarModel

    public init(model: DocumentModel) {
        self.model = model
        self.sidebar = model.sidebar
    }

    public var body: some View {
        // NavigationStack so sub-pages (Plugins, LSP Diagnostics) push in-place
        // with a native back button instead of opening detached windows the
        // user can't navigate back from.
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appearanceSection
                    Divider()
                    editorSection
                    Divider()
                    viewerSection
                    Divider()
                    privacySection
                    Divider()
                    pluginsSection
                    Divider()
                    lspSection
                    Divider()
                    advancedSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Settings")
        }
        // Resizable window: open at a size that fits the content, but let the
        // user grow it (styleMask gets `.resizable` in SettingsWindowController)
        // and scroll when smaller. A hard fixed frame previously clipped rows.
        .frame(minWidth: 500, idealWidth: 560, maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
    }

    /// Drives the "Clear all bookmarks" confirmation. Clearing is
    /// destructive and irreversible, so we gate it behind a dialog with
    /// a destructive primary (mirrors GitStashTab's Drop confirmation).
    @State private var confirmingClearBookmarks = false

    private var lspSection: some View {
        section("Language servers (LSP)") {
            row("Diagnostics") {
                NavigationLink("Open Diagnostics…") {
                    SettingsSubPage(title: "LSP Diagnostics") {
                        LSPDiagnosticsView(pool: model.lspPool)
                    }
                }
            }
            Text("Per-language LSP servers spawn on first hover / outline request and reap after 5 minutes idle. The diagnostics page shows live state.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    private var pluginsSection: some View {
        section("Plugins") {
            row("Manage installed plugins") {
                NavigationLink("Manage…") {
                    SettingsSubPage(title: "Plugins") {
                        PluginsSettingsView()
                    }
                }
            }
            row("Audit log") {
                Button("Open Log") {
                    NSWorkspace.shared.open(PluginSubprocessHost.auditLogURL())
                }
                .disabled(!FileManager.default.fileExists(
                    atPath: PluginSubprocessHost.auditLogURL().path))
            }
            Text("Plugins live under ~/Library/Application Support/com.markdownviewer.MarkdownViewer/Plugins/. Drop a folder there and relaunch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
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
            // Single unified zoom slider — drives both document
            // content (rendered HTML / source font / hex / find-bar)
            // and chrome (sidebar / tabs / status bar / mode bar) via
            // `DocumentModel.uiSize(_:)`. Previously a second "UI
            // scale" slider sat below this one; collapsed in 2026-05.
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
            row("Show invisible characters") {
                Toggle("", isOn: $model.showInvisibleChars).labelsHidden()
            }
            row("Indentation") {
                Picker("", selection: $model.editorIndentation) {
                    Text("2 spaces").tag(CMIndentation.spaces(2))
                    Text("4 spaces").tag(CMIndentation.spaces(4))
                    Text("Tabs (width 2)").tag(CMIndentation.tabs(width: 2))
                    Text("Tabs (width 4)").tag(CMIndentation.tabs(width: 4))
                    Text("Tabs (width 8)").tag(CMIndentation.tabs(width: 8))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }
            Text("Wrap and Show Invisibles apply to source and editor modes. Indentation drives only the CM6 editor (Tab key inserts).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    private var viewerSection: some View {
        section("Sidebar") {
            row("Show sidebar by default") {
                Toggle("", isOn: Binding(
                    get: { sidebar.isVisible },
                    set: { sidebar.isVisible = $0 }
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
                Button("Clear All") { confirmingClearBookmarks = true }
                    .confirmationDialog(
                        "Clear all bookmarks?",
                        isPresented: $confirmingClearBookmarks,
                        titleVisibility: .visible
                    ) {
                        Button("Clear All Bookmarks", role: .destructive) {
                            model.clearBookmarks()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes every file and line bookmark. This can't be undone.")
                    }
            }
            row("Reset window state") {
                Button("Reset") { resetWindowState() }
            }
            Text("Resets zoom, sidebar width, and the saved window position. Quit and relaunch for the window to re-center.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    /// Clear the persisted UI-state defaults so the next launch starts
    /// fresh. Previously this only dropped zoom + sidebar width, leaving
    /// the AppKit frame-autosave entry (`NSWindow Frame MainWindow`, see
    /// MarkdownViewer/main.swift) untouched — so "Reset window state"
    /// never actually re-centered the window. We now also remove that
    /// key so the next launch falls through to `window.center()`.
    private func resetWindowState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "MarkdownViewer.sidebarWidth")
        defaults.removeObject(forKey: "MarkdownViewer.zoom")
        // Frame autosave key written by NSWindow.setFrameAutosaveName.
        // Keep this literal in sync with `autosaveName` in main.swift.
        defaults.removeObject(forKey: "NSWindow Frame MainWindow")
    }

    private var privacySection: some View {
        section("Privacy & Permissions") {
            row("Full Disk Access") {
                Button("Open System Settings…") { openFullDiskAccessSettings() }
            }
            Text("TextView reads files you open. Some locations (other apps' container folders, system paths) require Full Disk Access. Grant it in System Settings → Privacy & Security → Full Disk Access, then relaunch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    /// Deep-link to the Full Disk Access pane. The
    /// `x-apple.systempreferences:` scheme with the
    /// `Privacy_AllFiles` anchor is the documented way to land directly
    /// on the FDA list; if it ever fails to resolve we fall back to the
    /// Privacy & Security root.
    private func openFullDiskAccessSettings() {
        let fda = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: fda), NSWorkspace.shared.open(url) { return }
        if let root = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(root)
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
/// A pushed Settings sub-page (Plugins, LSP Diagnostics) with an explicit
/// in-content back control. macOS `NavigationStack` only renders its automatic
/// back chevron inside a window toolbar, which this `NSHostingController`-hosted
/// Settings window doesn't have — so the chevron was invisible and the user got
/// stuck on the sub-page with no way back. An explicit Button calling
/// `dismiss()` pops the stack reliably regardless of window chrome.
private struct SettingsSubPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Label("Settings", systemImage: "chevron.backward")
                }
                .buttonStyle(.plain)
                .help("Back to Settings")
                Text(title).font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
    }
}

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
        // Derive the display name from the bundle (CFBundleName ==
        // "TextView") rather than hardcoding the old product name, so a
        // future rebrand updates this title automatically. Falls back to
        // "TextView" when running outside a bundle (e.g. `swift run`).
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "TextView"
        win.title = "\(appName) Settings"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
