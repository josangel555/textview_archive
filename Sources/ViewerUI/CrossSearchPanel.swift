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

    /// Active mode. Default `.text` matches the panel's pre-existing
    /// behavior. Kept in `@State` so the scope row re-renders when
    /// future mode-toggle UI lands above.
    @State private var mode: SearchMode = .text

    /// Currently-selected scope. Defaults to the active file when one
    /// is open, else the active folder. `onAppear` reconciles this.
    @State private var scope: SearchScope = .activeFile

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search across folder…", text: $model.crossSearchQuery)
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
                if model.crossSearchIsRunning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.dismissCrossSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
        .onChange(of: scope) { _, _ in runSearch() }
        .accessibilityIdentifier("mdv.crossSearchPanel")
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
            return model.sidebar.rootURL
        }
        return SearchScopeResolver.resolve(
            scope,
            activeFile: model.currentURL,
            activeFolder: model.sidebar.rootURL
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
        if model.currentURL == nil, model.sidebar.rootURL != nil {
            scope = .activeFolder
        } else {
            scope = .activeFile
        }
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
                .disabled(model.sidebar.rootURL == nil || mode.requiresFileScope)
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
            Text(model.sidebar.rootURL == nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.openPath(group.url)
                model.dismissCrossSearch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(group.url.lastPathComponent)
                        .font(.system(.body, design: .default).weight(.medium))
                    Text("(\(group.matches.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(group.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            ForEach(group.matches.prefix(8), id: \.lineNumber) { m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(m.lineNumber)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Text(m.line)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 30)
                .padding(.trailing, 14)
                .padding(.vertical, 1)
            }
            if group.matches.count > 8 {
                Text("+ \(group.matches.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 66)
            }
            Divider().padding(.vertical, 4)
        }
    }
}
