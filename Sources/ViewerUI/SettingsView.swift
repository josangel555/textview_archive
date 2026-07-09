import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

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
                    languagesSection
                    Divider()
                    terminalSection
                    Divider()
                    viewerSection
                    Divider()
                    fileAssociationsSection
                    Divider()
                    audioSection
                    Divider()
                    privacySection
                    Divider()
                    pluginsSection
                    Divider()
                    extensionsSection
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

    /// TSK-789: per-language LSP server availability, loaded off-main (the
    /// resolver shells out to xcrun/which). Empty until the .task fills it.
    @State private var lspStatuses: [LSPLanguageRegistry.LanguageStatus] = []

    /// TSK-356: per-group "is TextView the default handler" status, queried via
    /// LaunchServices off-main. Empty until the .task fills it; `refreshToken`
    /// bumps re-run the query after the user flips a default.
    @State private var defaultAppStatuses: [DefaultAppRegistration.GroupStatus] = []
    @State private var defaultAppRefreshToken = 0
    // TSK-1206: walkthrough library items for the Extensions inventory (loaded off-main).
    @State private var walkthroughItems: [ExtensionsInventory.ExtensionItem] = []

    private var lspSection: some View {
        section("Language servers (LSP)") {
            // TSK-789: which languages have LSP support + whether the server
            // binary is installed on this machine (with an install hint when not).
            if lspStatuses.isEmpty {
                row("Supported") {
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(lspStatuses, id: \.language) { st in
                    row(st.language.displayName) {
                        if st.available {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Not found", systemImage: "xmark.circle")
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                if let hint = st.language.installHint {
                                    Text(hint)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
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
        .accessibilityIdentifier("mdv.settings.lspLanguages")
        .task {
            // Off-main: languageStatuses() shells out (xcrun -f / which) per server.
            lspStatuses = await Task.detached(priority: .utility) {
                LSPLanguageRegistry.languageStatuses()
            }.value
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

    /// TSK-1112: at-a-glance list of installed plugins (the merged extensions
    /// inventory; walkthroughs are a tracked follow-on). Distinct from the
    /// Plugins config sub-page — this is the read-only "what's installed" view.
    private var extensionsSection: some View {
        section("Extensions") {
            let plugins = model.extensionsInventory.items(of: .plugin)
            if plugins.isEmpty {
                row("Installed plugins") {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(plugins) { item in
                    row(item.name) {
                        Text(item.version.map { "v\($0)" } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // TSK-1206: the user's walkthrough library, alongside plugins.
            if !walkthroughItems.isEmpty {
                ForEach(walkthroughItems) { item in
                    row(item.name) {
                        Text(item.detail ?? "Walkthrough")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await loadWalkthroughItems() }
    }

    /// TSK-1206 — load the on-disk walkthrough library off-main and project it
    /// into inventory items for the Extensions list.
    private func loadWalkthroughItems() async {
        let items = await Task.detached(priority: .utility) {
            WalkthroughCatalog.entries(in: WalkthroughCatalog.defaultLibraryDirectory())
                .map { ExtensionsInventory.item(from: ExtensionsInventory.snapshot(from: $0)) }
        }.value
        walkthroughItems = items
    }

    private var appearanceSection: some View {
        section("Appearance") {
            row("Font") {
                // TSK-259: monospace family for the text surfaces.
                // nil = the system monospaced font; only fixed-pitch
                // families are offered (a proportional font would break
                // the source view's gutter math).
                Picker("", selection: $model.sourceFontName) {
                    Text("System Default").tag(Optional<String>.none)
                    ForEach(FontPreference.monospaceFamilies(), id: \.self) { family in
                        Text(family).tag(Optional(family))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .accessibilityIdentifier("mdv.settings.fontPicker")
            }
            row("Theme") {
                // TSK-641 stage 2: the catalog picker — built-ins + user +
                // VS Code imports (ThemeStore), with Follow System as nil.
                Picker("", selection: $model.selectedThemeID) {
                    Text("Follow System").tag(Optional<String>.none)
                    ForEach(ThemeStore.shared.all(), id: \.id) { def in
                        Text(def.displayName).tag(Optional(def.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }
            row("") {
                Button("Import VS Code Theme…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do {
                        let def = try VSCodeThemeImporter.importFile(at: url)
                        model.selectedThemeID = def.id
                    } catch {
                        NSSound.beep()
                    }
                }
                .font(.system(size: 11))
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
            // Absolute base size for editor/source content text (TSK-358); the
            // on-screen size is this × Zoom, so Zoom stays a multiplier.
            row("Text Size") {
                Slider(
                    value: $model.contentFontSize,
                    in: PreferencesStore.minContentFontSize...PreferencesStore.maxContentFontSize,
                    step: 1
                )
                .frame(width: 180)
                .accessibilityIdentifier("mdv.settings.contentFontSize")
                Text("\(Int(model.contentFontSize)) pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            Text("Text Size sets the editor/source base size; Zoom multiplies it (and the UI chrome).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
            row("Show indent guides") {
                Toggle("", isOn: $model.editorIndentGuides).labelsHidden()
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

    /// TSK-790 — discoverability: the syntax-highlighting languages the app
    /// supports, with the file extensions that trigger each. Both the read-only
    /// source View (TreeSitter) and the CM6 Edit editor highlight this set.
    private var languagesSection: some View {
        section("Syntax Highlighting") {
            Text("Source View and the editor both highlight these languages, detected by file extension:")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(HighlightLanguage.supportedForDisplay, id: \.self) { lang in
                row(lang.displayName) {
                    Text(lang.fileExtensions.map { ".\($0)" }.joined(separator: "  "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityIdentifier("mdv.settings.languages")
    }

    private var terminalSection: some View {
        section("Terminal") {
            // Colour scheme (TSK-1312): the ANSI 16-colour palette. "Default" is the
            // muted shipped palette; "Classic (xterm)" is standard vivid xterm colours
            // (closer to what CLI tools like claude code expect — the "colors look off" fix).
            row("Colour scheme") {
                Picker("", selection: $model.terminalColorThemeName) {
                    ForEach(AnsiTheme.builtIns, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("mdv.settings.terminal.colorScheme")
            }
            // Pane DOCK edge (TSK-491): which shoulder the whole terminal pane
            // lives in. The discoverable control for "move the terminal to the
            // right" — distinct from the tab-strip position INSIDE the pane.
            row("Pane placement") {
                Picker("", selection: Binding(
                    get: { model.terminalPane.paneEdge },
                    set: { model.terminalPane.setPaneEdge($0) }
                )) {
                    Text("Bottom").tag(TerminalPaneEdge.bottom)
                    Text("Left").tag(TerminalPaneEdge.left)
                    Text("Right").tag(TerminalPaneEdge.right)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("mdv.settings.terminal.paneEdge")
            }
            row("Tab strip position") {
                Picker("", selection: Binding(
                    get: { model.terminalPane.tabPosition },
                    set: { model.terminalPane.setTabPosition($0) }
                )) {
                    Text("Left").tag(TerminalTabPosition.left)
                    Text("Top").tag(TerminalTabPosition.top)
                    Text("Right").tag(TerminalTabPosition.right)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("mdv.settings.terminal.tabPosition")
            }
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

    /// TSK-356 — "Default anything Viewer". TextView registers as an *alternate*
    /// viewer for these type groups (so it shows in Finder's "Open With") but is
    /// intentionally not the system default. This section reports, per group,
    /// whether TextView is currently the default handler and offers a one-click
    /// "Make Default" that flips it via LaunchServices.
    private var fileAssociationsSection: some View {
        section("File Associations") {
            if defaultAppStatuses.isEmpty {
                row("Status") {
                    Text("Checking…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(defaultAppStatuses) { st in
                    row(st.group.name) { fileAssociationControl(st) }
                }
            }
            Text("Set TextView as the default app for these file types. You can still revert in Finder via Get Info → Open With.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .accessibilityIdentifier("mdv.settings.fileAssociations")
        .task(id: defaultAppRefreshToken) {
            // Off-main: LaunchServices queries hit the on-disk LS database.
            defaultAppStatuses = await Task.detached(priority: .utility) {
                DefaultAppRegistration.status(
                    using: LiveRoleHandlerService(),
                    ourBundleID: DefaultAppRegistration.ourBundleID)
            }.value
        }
    }

    @ViewBuilder
    private func fileAssociationControl(
        _ st: DefaultAppRegistration.GroupStatus
    ) -> some View {
        if st.isDefault {
            Label("Default", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .accessibilityIdentifier("mdv.settings.fileAssoc.default.\(st.id)")
        } else {
            HStack(spacing: 6) {
                if st.isPartial {
                    Text("Partial")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                Button("Make Default") { makeDefault(st.group) }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("mdv.settings.fileAssoc.makeDefault.\(st.id)")
            }
        }
    }

    /// Flip the default viewer handler for `group` to TextView, then re-query so
    /// the row updates. The LS write is fast but off-main to keep the UI live; a
    /// failure beeps (the row stays "Make Default").
    private func makeDefault(_ group: DefaultAppRegistration.Group) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DefaultAppRegistration.setDefault(
                    for: group,
                    using: LiveRoleHandlerService(),
                    ourBundleID: DefaultAppRegistration.ourBundleID)
            }.value
            if case .failed = result { NSSound.beep() }
            defaultAppRefreshToken &+= 1  // re-run the .task(id:) query
        }
    }

    /// Audio export (MP3) needs an external `ffmpeg`. The field overrides
    /// auto-discovery; the status line resolves it live via `FFmpegLocator`
    /// so the user sees whether MP3 export will actually work (TSK-528/535).
    private var audioSection: some View {
        section("Audio") {
            row("ffmpeg path") {
                TextField("auto-detect", text: Binding(
                    get: { model.audioFFmpegPath ?? "" },
                    set: { model.audioFFmpegPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .accessibilityIdentifier("mdv.settings.audio.ffmpegPath")
            }
            ffmpegStatusRow
            Text("MP3 export needs an external ffmpeg (not bundled). Leave blank to auto-detect on PATH and common install locations; set a path to override. WAV / AIFF / CAF / AAC don't need it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    @ViewBuilder private var ffmpegStatusRow: some View {
        if let url = FFmpegLocator.resolve(override: model.audioFFmpegPath) {
            Label("MP3 available — \(url.path)", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.leading, 4)
                .accessibilityIdentifier("mdv.settings.audio.ffmpegStatus")
        } else {
            Label("ffmpeg not found — MP3 export disabled", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityIdentifier("mdv.settings.audio.ffmpegStatus")
        }
    }

    private var advancedSection: some View {
        section("Advanced") {
            // TSK-1105: surface the existing sessions-enabled pref (TSK-264).
            row("Multi-session workspace") {
                Toggle("", isOn: $model.sessionsEnabled).labelsHidden()
            }
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
    /// fresh. Delegates to `PreferencesStore.resetWindowState()` (TSK-358),
    /// which clears our own window frame + sidebar width + zoom AND AppKit's
    /// frame-autosave entry (`NSWindow Frame MainWindow`) in one place — the
    /// scattered raw-key literals previously lived here and in main.swift.
    private func resetWindowState() {
        PreferencesStore(defaults: .standard).resetWindowState()
    }

    /// TSK-1496 — the credential warn-badge treatment. 0 = warn badge (default),
    /// 2 = off. Shared with `SecretWarningBanner` via the same defaults key.
    @AppStorage(SecretDetector.treatmentDefaultsKey) private var secretTreatment: Int = 0

    private var privacySection: some View {
        section("Privacy & Permissions") {
            row("Full Disk Access") {
                Button("Open System Settings…") { openFullDiskAccessSettings() }
            }
            Text("TextView reads files you open. Some locations (other apps' container folders, system paths) require Full Disk Access. Grant it in System Settings → Privacy & Security → Full Disk Access, then relaunch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            row("Secret detection") {
                Picker("", selection: $secretTreatment) {
                    Text("Warn badge").tag(0)
                    Text("Off").tag(SecretBannerState.treatmentOff)
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityIdentifier("mdv.settings.secretTreatment")
            }
            Text("Flags likely credentials (AWS/GitHub/Slack/GCP keys, PEM blocks, JWTs, high-entropy assignments) in the open document with a non-modal badge. Values are shown redacted; TextView never modifies the file. Not a guarantee — see the badge details for what it does and doesn't catch.")
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
