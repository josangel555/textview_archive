import AppKit
import SwiftUI
import ViewerCore

/// Cross-file search overlay. Mirrors the command palette's visual
/// style but lists grep-style results — file groups with line-number
/// hits. Activation: Cmd+Shift+F. Click a row to open the file.
///
/// # Search modes
///
/// The panel is structured around a `SearchMode` even though the
/// current build only implements text-grep across a folder. Other
/// modes (`files` for filename-only search, `jq`, `css`, `xpath` for
/// single-file query languages) are reserved so the scope picker UI
/// behaves correctly when those modes land. The LSP roadmap branch
/// adds a sixth `symbol` mode — see its MARK.
///
/// # Accessibility identifiers
///   - `mdv.crossSearchPanel`           — outer container
///   - `mdv.unifiedSearch.scopeLabel`   — visible scope row label
///   - `mdv.unifiedSearch.scopePicker`  — scope dropdown menu
///   - `mdv.unifiedSearch.scope.activeFile`
///   - `mdv.unifiedSearch.scope.activeFolder`
///   - `mdv.unifiedSearch.scope.pickFile`
///   - `mdv.unifiedSearch.scope.pickFolder`
struct CrossSearchPanel: View {
    @ObservedObject var model: DocumentModel
    /// PERF #1: observe sidebar directly. The panel reads
    /// `sidebar.rootURL` from multiple body sites (scope picker
    /// labels, disable conditions, fallback resolution), so a
    /// `sidebar.rootURL` change has to drive a body re-eval. The
    /// (removed) DocumentModel-wide forwarding used to do this.
    @ObservedObject var sidebar: SidebarModel
    @FocusState private var fieldFocused: Bool

    // MARK: - Scope picker (search-scope agent)

    /// Search mode the panel is currently driving. Today only `.text`
    /// is engine-backed; the rest of the cases shape the scope-picker
    /// UI so it's ready for the upcoming Files / jq / CSS / XPath
    /// engines without churning every keyboard handler when they
    /// land. The LSP agent owns the parallel `.symbol` mode.
    enum SearchMode: Equatable {
        case text     // cross-file text grep (folder scope)
        case files    // filename match (folder scope)
        case jq       // JSON query (single file)
        case css      // CSS selector against HTML (single file)
        case xpath    // XPath against XML/HTML (single file)

        /// True when the mode operates over multiple files and
        /// therefore requires a folder scope.
        var requiresFolderScope: Bool {
            switch self {
            case .text, .files: return true
            case .jq, .css, .xpath: return false
            }
        }

        /// True when the mode only ever runs against a single file —
        /// the file-scope buttons should be the only ones enabled.
        var requiresFileScope: Bool {
            switch self {
            case .jq, .css, .xpath: return true
            case .text, .files: return false
            }
        }
    }

    /// Active mode, derived from the model's Text|FileName toggle (TSK-758).
    /// Both `.text` and `.files` require a folder scope, so the scope row
    /// behaves identically; the reserved single-file modes (jq/css/xpath)
    /// aren't reachable from the toggle yet.
    private var mode: SearchMode {
        model.crossSearchFilenameMode ? .files : .text
    }

    /// Currently-selected scope. Defaults to the active file when one
    /// is open, else the active folder. `onAppear` reconciles this.
    @State private var scope: SearchScope = .activeFile

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(model.crossSearchFilenameMode
                          ? "Search file names…" : "Search across folder…",
                          text: $model.crossSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { runSearch() }
                Toggle(isOn: $model.crossSearchCaseSensitive) {
                    Text("Aa").font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match case")
                .accessibilityLabel("Match case")
                .accessibilityValue(model.crossSearchCaseSensitive ? "On" : "Off")
                Toggle(isOn: $model.crossSearchUseRegex) {
                    Text(".*").font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Use regular expression")
                .accessibilityLabel("Use regular expression")
                .accessibilityValue(model.crossSearchUseRegex ? "On" : "Off")
                .accessibilityIdentifier("mdv.unifiedSearch.regexToggle")
                // TSK-726 — disclose the project-wide replace row. Disabled in
                // filename mode (nothing to replace inside file contents).
                Toggle(isOn: $model.crossSearchReplaceVisible) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(model.crossSearchFilenameMode)
                .help("Show replace")
                .accessibilityLabel("Show replace")
                .accessibilityIdentifier("mdv.crossSearch.replaceToggle")
                if model.crossSearchIsRunning {
                    // TSK-1465 — live walk feedback + a real cancel (stops the
                    // walk; whatever was found so far still lands).
                    ProgressView().controlSize(.small)
                    if let progress = model.crossSearchProgress, progress.scanned > 0 {
                        Text("\(progress.scanned) scanned · \(progress.matches) found")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("mdv.crossSearch.progress")
                    }
                    Button("Stop") { model.cancelCrossSearch() }
                        .controlSize(.small)
                        .help("Stop searching and keep the matches found so far")
                        .accessibilityIdentifier("mdv.crossSearch.cancel")
                }
                Button {
                    model.dismissCrossSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close search (Esc)")
                .accessibilityLabel("Close search")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // TSK-726 — project-wide replace row, disclosed by the toggle above.
            if model.crossSearchReplaceVisible && !model.crossSearchFilenameMode {
                Divider()
                replaceRow
                // TSK-1465 — the confirm step: what WOULD change, before any
                // byte moves. Non-nil only after "Preview Replace".
                if let preview = model.crossSearchReplacePreview {
                    Divider()
                    replacePreviewSection(preview)
                }
            }

            modeRow

            Divider()

            scopeRow

            Divider()

            if model.crossSearchQuery.isEmpty {
                placeholder
            } else if model.crossSearchResults.isEmpty {
                Text(model.crossSearchIsRunning ? "Searching…" : "No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.crossSearchResults) { group in
                            CrossSearchFileGroupView(group: group, model: model)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: 760, maxHeight: 520)
        // G5: previously `.thinMaterial`, which renders as a translucent
        // grey fill — the panel read as a muddy grey card rather than a
        // clean search surface. Use the standard text-background swatch
        // (pure white in light mode, the elevated dark tone in dark
        // mode) clipped to the same rounded rect so the panel reads
        // white/opaque like the command palette and editor surfaces.
        .background(
            Palette.textBackground,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.separator, lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.25), radius: 20, y: 8)
        .onAppear {
            fieldFocused = true
            reconcileInitialScope()
            // Honor an externally pre-set scope (e.g. "Search in
            // Folder" right-click) by syncing local @State to it.
            if let pre = model.crossSearchPresetScope {
                scope = pre
                model.crossSearchPresetScope = nil
            }
            if !model.crossSearchQuery.isEmpty { runSearch() }
        }
        .onChange(of: model.crossSearchQuery) { _, _ in runSearch() }
        .onChange(of: model.crossSearchCaseSensitive) { _, _ in runSearch() }
        .onChange(of: model.crossSearchFilenameMode) { _, _ in runSearch() }
        .onChange(of: model.crossSearchUseRegex) { _, _ in runSearch() }
        .onChange(of: scope) { _, _ in runSearch() }
        .accessibilityIdentifier("mdv.crossSearchPanel")
    }

    // MARK: - Replace row (TSK-726)

    /// Project-wide replace: a replacement field + "Replace All" over the files
    /// currently listed in the results. The rewrite preserves each file's
    /// encoding / permissions and is atomic + symlink-safe (engine side). Only
    /// shown in content-search mode.
    private var replaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundStyle(.secondary)
            TextField("Replace with…", text: $model.crossSearchReplacement)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit { model.runCrossFileReplacePreview() }
                .accessibilityIdentifier("mdv.crossSearch.replaceField")
            if let status = model.crossSearchReplaceStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("mdv.crossSearch.replaceStatus")
            }
            // TSK-1465 — replace is a two-step: PREVIEW (no writes), then a
            // confirm in the section below. The one-click blind write is gone.
            Button("Preview Replace") { model.runCrossFileReplacePreview() }
                .controlSize(.small)
                .disabled(model.crossSearchResults.isEmpty
                          || model.crossSearchQuery.isEmpty
                          || model.crossSearchIsRunning)
                .help("Show what would change — per file — before writing anything")
                .accessibilityIdentifier("mdv.crossSearch.replaceAll")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// TSK-1465 — the confirm step: totals + per-file would-be counts (and
    /// per-file failures), then an explicit destructive confirm. Computed by
    /// the SAME engine path as the write, so it can't disagree with it.
    private func replacePreviewSection(_ preview: [CrossFileReplace.FileOutcome]) -> some View {
        let summary = CrossFileReplace.Summary(outcomes: preview)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text(summary.totalReplacements == 0
                     ? "Nothing to replace."
                     : "Will replace \(summary.totalReplacements) occurrence\(summary.totalReplacements == 1 ? "" : "s") in \(summary.filesChanged) file\(summary.filesChanged == 1 ? "" : "s").")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("mdv.crossSearch.previewSummary")
                Spacer()
                Button("Cancel") { model.cancelCrossFileReplacePreview() }
                    .controlSize(.small)
                    .accessibilityIdentifier("mdv.crossSearch.previewCancel")
                Button("Replace", role: .destructive) { model.confirmCrossFileReplace() }
                    .controlSize(.small)
                    .disabled(summary.totalReplacements == 0)
                    .help("Write the previewed replacements to disk")
                    .accessibilityIdentifier("mdv.crossSearch.previewConfirm")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preview, id: \.url) { outcome in
                        HStack(spacing: 6) {
                            Text(outcome.url.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let error = outcome.error {
                                Text(error)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            } else {
                                Text("\(outcome.replacements)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 110)
            .accessibilityIdentifier("mdv.crossSearch.previewList")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Scope picker (search-scope agent)

    /// Resolved URL the engine should run against, taking the current
    /// mode into account. Pure-logic via `SearchScopeResolver`.
    private var resolvedScopeURL: URL? {
        // If the mode requires a folder but the scope is file-shaped,
        // auto-fall-back to the active folder so we never run a
        // text-grep against a single file URL.
        if SearchScopeResolver.needsFolderFallback(
            scope: scope,
            modeRequiresFolder: mode.requiresFolderScope
        ) {
            return sidebar.rootURL
        }
        return SearchScopeResolver.resolve(
            scope,
            activeFile: model.currentURL,
            activeFolder: sidebar.rootURL
        )
    }

    /// Default scope when the panel first appears: prefer the active
    /// file; fall back to the active folder. Modes that only operate
    /// over folders auto-collapse via `resolvedScopeURL`.
    private func reconcileInitialScope() {
        // If a folder-only mode is active and the scope is file-shaped,
        // snap to `.activeFolder` so the UI matches the executed scope
        // (Files mode in particular — searching for filenames inside a
        // single file is nonsensical).
        if mode.requiresFolderScope, !scope.isFolder {
            scope = .activeFolder
            return
        }
        if model.currentURL == nil, sidebar.rootURL != nil {
            scope = .activeFolder
        } else {
            scope = .activeFile
        }
    }

    /// Text | FileName mode picker + the regex-error hint (TSK-758).
    private var modeRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.crossSearchFilenameMode) {
                Text("Text").tag(false)
                Text("File name").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Search file contents, or file names")
            .accessibilityIdentifier("mdv.unifiedSearch.modePicker")

            if let err = model.crossSearchRegexError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("mdv.unifiedSearch.regexError")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var scopeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: scope.isFolder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(scopeDisplayString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mdv.unifiedSearch.scopeLabel")

            if mode.requiresFileScope {
                Text("single file only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("This mode only operates on a single file.")
            } else if mode.requiresFolderScope {
                Text("folder scope")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("This mode requires a folder.")
            }

            Menu {
                Button {
                    scope = .activeFile
                } label: {
                    Label("Active File", systemImage: "doc.text")
                }
                .disabled(model.currentURL == nil || mode.requiresFolderScope)
                .accessibilityIdentifier("mdv.unifiedSearch.scope.activeFile")

                Button {
                    scope = .activeFolder
                } label: {
                    Label("Active Folder", systemImage: "folder")
                }
                .disabled(sidebar.rootURL == nil || mode.requiresFileScope)
                .accessibilityIdentifier("mdv.unifiedSearch.scope.activeFolder")

                Divider()

                Button {
                    pickFile()
                } label: {
                    Label("Pick File…", systemImage: "doc.badge.plus")
                }
                .disabled(mode.requiresFolderScope)
                .accessibilityIdentifier("mdv.unifiedSearch.scope.pickFile")

                Button {
                    pickFolder()
                } label: {
                    Label("Pick Folder…", systemImage: "folder.badge.plus")
                }
                .disabled(mode.requiresFileScope)
                .accessibilityIdentifier("mdv.unifiedSearch.scope.pickFolder")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change search scope")
            .accessibilityIdentifier("mdv.unifiedSearch.scopePicker")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Human-readable scope label for the visible row. Shows the
    /// resolved URL when one exists, falling back to a hint string.
    private var scopeDisplayString: String {
        if let url = resolvedScopeURL {
            return url.path
        }
        switch scope {
        case .activeFile:
            return "No active file — open a tab or pick a file."
        case .activeFolder:
            return "No active folder — pick a folder."
        case .pickedFile(let url), .pickedFolder(let url):
            return url.path
        }
    }

    /// Routes through `DocumentModel.runCrossSearch(scope:)` so the
    /// engine sees the right URL. For folder-shaped scopes that maps
    /// to the existing CrossFileSearch root; file-shaped scopes are
    /// reserved for future single-file engines (jq / CSS / XPath /
    /// symbol). When a file scope is selected today, we fall back to
    /// the file's parent folder so the user still gets *some* result
    /// — surfaced explicitly so the behavior is predictable.
    private func runSearch() {
        let url: URL? = {
            if let resolved = resolvedScopeURL {
                if mode.requiresFolderScope && !resolved.hasDirectoryPath {
                    return resolved.deletingLastPathComponent()
                }
                return resolved
            }
            return nil
        }()
        model.runCrossSearch(scope: url)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Pick file to search"
        if panel.runModal() == .OK, let url = panel.url {
            scope = .pickedFile(url)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Pick folder to search"
        if panel.runModal() == .OK, let url = panel.url {
            scope = .pickedFolder(url)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(sidebar.rootURL == nil
                 ? "Open a folder to search across files."
                 : "Type to search the folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct CrossSearchFileGroupView: View {
    let group: CrossFileSearch.FileMatches
    @ObservedObject var model: DocumentModel
    /// TSK-1465 — per-file collapse: fold a noisy file's matches away while
    /// scanning the rest. View-local (resets on a new search — deliberate).
    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // The collapse chevron is a SEPARATE target from the header
                // (which opens the file) so the two actions don't fight.
                if !group.matches.isEmpty {
                    Button {
                        isCollapsed.toggle()
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                    .help(isCollapsed ? "Show this file's matches" : "Hide this file's matches")
                    .accessibilityIdentifier("mdv.crossSearch.groupCollapse")
                }
                Button {
                    model.openPath(group.url)
                    model.dismissCrossSearch()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(group.url.lastPathComponent)
                            .font(.system(.body, design: .default).weight(.medium))
                        // Filename-mode hits carry no line matches (TSK-758) — the
                        // file itself is the result, so the "(N)" count is hidden.
                        if !group.matches.isEmpty {
                            Text("(\(group.matches.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(group.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(.trailing, 14)
                    .padding(.leading, group.matches.isEmpty ? 14 : 4)
                    .padding(.vertical, 4)
                }
                // UIRESP-06: file-group header reads as clickable (opens the
                // file) with hover background + pointing-hand cursor.
                .buttonStyle(RowHoverButtonStyle(cornerRadius: 0))
                .accessibilityLabel("Open \(group.url.lastPathComponent), \(group.matches.count) matches")
            }

            ForEach(isCollapsed ? [] : Array(group.matches.prefix(8)), id: \.lineNumber) { m in
                // Search result jump (jump-wiring agent): each match
                // row opens the file at its 1-based line. Previously
                // only the file header was clickable, which dropped
                // the user at line 1 with no further hint.
                Button {
                    model.openPath(group.url, atLine: m.lineNumber)
                    model.dismissCrossSearch()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(m.lineNumber)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(m.line)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 30)
                    .padding(.trailing, 14)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                // UIRESP-06: match row opens the file at the line.
                .buttonStyle(RowHoverButtonStyle(cornerRadius: 0))
                .accessibilityLabel("Line \(m.lineNumber): \(m.line)")
            }
            if !isCollapsed, group.matches.count > 8 {
                Text("+ \(group.matches.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 66)
            }
            Divider().padding(.vertical, 4)
        }
    }
}
