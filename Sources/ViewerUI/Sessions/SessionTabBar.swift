import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Top row of the nested tabs UI. One pill per session managed by the
/// app-level `SessionsAppCoordinator`; below it the per-file `TabBar`
/// continues to drive `DocumentModel.tabs`.
///
/// Visual style mirrors `TabBar` — same 30pt strip, same 28pt pill,
/// same close-button hover-reveal, same active-tab accent overlay.
///
/// ## Accessibility identifiers
///
/// VM-side UI tests target these stable ids — keep them in sync with
/// the test author's `mdv.sessionTab.*` mapping:
///
/// - `mdv.sessionTabBar`           — the whole row container
/// - `mdv.sessionTab.<uuid>`       — each session pill (click target)
/// - `mdv.sessionTab.close.<uuid>` — the × close button
/// - `mdv.sessionTab.rename.<uuid>` — the inline rename TextField when
///                                    a rename is in progress
/// - `mdv.sessionTab.new`          — the trailing "+" button
struct SessionTabBar: View {
    @ObservedObject var sessionsApp: SessionsAppCoordinator
    @ObservedObject var core: SessionsCoordinator
    /// Observed so the strip re-bodies on a zoom change — the row height +
    /// every font/glyph below scales through `model.uiSize(...)`, matching
    /// the rest of the chrome (TabBar / ModeBar / StatusBar).
    @ObservedObject var model: DocumentModel

    /// id of the session currently being inline-renamed (nil = none).
    @State private var renamingID: UUID?

    init(sessionsApp: SessionsAppCoordinator) {
        self.sessionsApp = sessionsApp
        self.core = sessionsApp.core
        self.model = sessionsApp.model
    }

    /// B1: the row is now TWO lines (name + git/branch sub-line), so it needs
    /// more height than the old single-line 30pt strip. Scales with zoom like
    /// the rest of the chrome.
    private var rowHeight: CGFloat { model.uiSize(46) }

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("SessionTabBar")   // TSK-615 re-eval width probe
        #endif
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(core.sessions.enumerated()), id: \.element.id) { index, snap in
                        SessionTabBarItem(
                            snapshot: snap,
                            isSelected: core.activeID == snap.id,
                            isRenaming: renamingID == snap.id,
                            uiSize: model.uiSize,
                            onSelect: { sessionsApp.activate(id: snap.id) },
                            onClose: { sessionsApp.close(id: snap.id) },
                            onCommitRename: { newName in
                                sessionsApp.rename(id: snap.id, to: newName)
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil }
                        )
                        .contextMenu {
                            SessionTabContextMenu(
                                sessionsApp: sessionsApp,
                                snapshot: snap,
                                onRequestRename: { renamingID = snap.id }
                            )
                        }
                        // TSK-274: a document tab dragged from the tab
                        // strip drops onto a session pill to MOVE the
                        // file into that session.
                        .onDrop(of: [.plainText], delegate: SessionTabDropDelegate(
                            sessionsApp: sessionsApp, targetSessionID: snap.id))
                        // B4-adjacent: a full top-to-bottom divider reads
                        // cleaner between a taller two-line cell than the old
                        // 16pt stub did. (B4 proper is a separate item.)
                        if index < core.sessions.count - 1 {
                            Divider().frame(height: rowHeight - model.uiSize(12))
                        }
                    }
                    // TSK-261: the "+" sits BESIDE the last session tab (inside
                    // the scrolling content), not pinned at the far-right edge.
                    // TSK-373: it's now a Menu — a bare click opens a folder in a
                    // new session (the long-standing primaryAction), while the
                    // menu offers "New Session ▸ Kind" (Code Review / Agent
                    // Session / Project view / …), each seeding that kind's panel
                    // layout via the already-wired openNewSession(kind:) path.
                    Menu {
                        Button("Open Folder in New Session…", action: openNewSession)
                        Divider()
                        ForEach(NewSessionMenuItems.all) { item in
                            Button {
                                sessionsApp.openNewSession(kind: item.kind)
                            } label: {
                                Label(item.title, systemImage: item.symbolName)
                            }
                            .accessibilityIdentifier("mdv.sessionTab.new.kind.\(item.kind.rawValue)")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: model.uiSize(11), weight: .medium))
                            .frame(width: model.uiSize(24), height: model.uiSize(24))
                    } primaryAction: {
                        openNewSession()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: model.uiSize(28))
                    .helpInfo(title: "New Session",
                              description: "Open a folder in a new session — or pick a kind")
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("mdv.sessionTab.new")
                    .uiClickTarget("mdv.sessionTab.new")
                    .accessibilityLabel("New Session")
                }
            }
            // TSK-313: double-click the EMPTY strip area = new session at ~
            // (browser idiom). Buttons/tab cells sit above this in the hit
            // chain, so clicks on tabs / + / close are unaffected.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                sessionsApp.openHomeSession()
            }
            // TSK-262: persistent trailing action icons pinned at the far
            // right of the session-tab row — Settings, File search, Omni.
            // (The "+" sits beside the last tab inside the scroll content;
            // these are app-wide actions, so they stay pinned + always visible.)
            HStack(spacing: model.uiSize(2)) {
                sessionActionButton(symbol: "gearshape", title: "Settings",
                                    help: "Open Settings",
                                    id: "mdv.sessionTab.settings") {
                    NSApp.sendAction(#selector(AppMenuActions.showSettings(_:)), to: nil, from: nil)
                }
                sessionActionButton(symbol: "magnifyingglass", title: "Search Files",
                                    help: "Search across files in this session",
                                    id: "mdv.sessionTab.search") {
                    model.showCrossSearch()
                }
                sessionActionButton(symbol: "command", title: "Command Palette",
                                    help: "Open the command palette",
                                    id: "mdv.sessionTab.omni") {
                    model.showPalette()
                }
            }
            .padding(.horizontal, model.uiSize(4))
        }
        .frame(height: rowHeight)
        .background(Palette.windowBackground)
        .accessibilityIdentifier("mdv.sessionTabBar")
        .uiClickTarget("mdv.sessionTabBar")
    }

    /// One pinned trailing action icon for the session-tab row (TSK-262).
    /// Mirrors the `+` button's `IconHoverButtonStyle` + `helpInfo` styling.
    @ViewBuilder
    private func sessionActionButton(
        symbol: String, title: String, help: String, id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: model.uiSize(11), weight: .medium))
                .frame(width: model.uiSize(24), height: model.uiSize(24))
        }
        .buttonStyle(IconHoverButtonStyle())
        .helpInfo(title: title, description: help)
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
    }

    /// `+` button entry point. Rather than upfront-prompting via
    /// NSOpenPanel, arm the coordinator's first-paint GoTo gate — the
    /// content view sees the bump, opens `GoToPathPrompt`, and the
    /// user either types a path or clicks "Open System Dialog…" to
    /// reach the native picker. This gives the freshly-spawned
    /// session an explicit entry point instead of a blank window.
    private func openNewSession() {
        sessionsApp.requestNewSessionViaGoTo()
    }
}

// MARK: - Item ---------------------------------------------------------

struct SessionTabBarItem: View {
    let snapshot: SessionSnapshot
    let isSelected: Bool
    let isRenaming: Bool
    /// Zoom-aware sizing helper threaded from `SessionTabBar` (== `DocumentModel
    /// .uiSize`). Every font / glyph / pill dimension scales through it.
    let uiSize: (CGFloat) -> CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var isHovering = false
    @State private var draftName = ""
    @FocusState private var isEditorFocused: Bool

    /// B1: git-root + branch for this session's folder, read subprocess-free
    /// from `.git/HEAD`. Computed once per body pass — `SessionGitInfo` is a
    /// couple of small filesystem reads (or a single `fileExists` for the
    /// common non-repo case), cheap enough for a row body. NOT cached in
    /// `@State`: the snapshot's `sidebarRootPath` is the only input and it
    /// changes only on a real session edit, which already re-bodies the strip.
    private var gitBadge: SessionGitInfo.Badge {
        SessionGitInfo.badge(forRootPath: snapshot.sidebarRootPath)
    }

    var body: some View {
        let badge = gitBadge
        return Button(action: onSelect) {
            ZStack {
                Rectangle().fill(background)
                HStack(spacing: uiSize(6)) {
                    Image(systemName: "folder")
                        .font(.system(size: uiSize(11), weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: uiSize(15), height: uiSize(15))
                    // Two-line cell: session name on top, git/branch sub-line
                    // below. The sub-line is omitted (and the name re-centers)
                    // when the folder isn't a repo, so a non-repo session
                    // doesn't carry an empty second row.
                    VStack(alignment: .leading, spacing: uiSize(2)) {
                        if isRenaming {
                            renameField
                        } else {
                            Text(SessionTabLabel.truncated(snapshot.displayName))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.system(size: uiSize(12), weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if badge.isRepoRoot {
                            gitSubLine(badge)
                        }
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: uiSize(9), weight: .bold))
                            .frame(width: uiSize(18), height: uiSize(18))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || isSelected ? 0.6 : 0)
                    .helpInfo(title: "Close Session",
                              description: "Close \(snapshot.displayName)")
                    .accessibilityLabel("Close \(snapshot.displayName)")
                    .accessibilityIdentifier("mdv.sessionTab.close.\(snapshot.id.uuidString)")
                }
                .padding(.horizontal, uiSize(10))
            }
            .frame(minWidth: uiSize(120), idealWidth: uiSize(190), maxWidth: uiSize(260))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .helpInfo(title: snapshot.displayName, description: sessionTooltipDescription)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(badge))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mdv.sessionTab.\(snapshot.id.uuidString)")
        // Pre-fill the editor on every rename activation. Using
        // `.onChange(of:initial:)` so we also seed the first time the
        // view appears already in `isRenaming = true` (rare, but
        // happens if a context-menu rename fires immediately).
        .onChange(of: isRenaming, initial: true) { _, nowRenaming in
            if nowRenaming {
                draftName = snapshot.displayName
                isEditorFocused = true
            }
        }
    }

    /// B1 sub-line: a git-root glyph plus the branch name (or "git" when the
    /// branch is unresolvable — detached HEAD / unreadable ref). The whole
    /// sub-line is `.secondary`, smaller than the name, so the session name
    /// stays the primary read.
    private func gitSubLine(_ badge: SessionGitInfo.Badge) -> some View {
        HStack(spacing: uiSize(3)) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: uiSize(9), weight: .medium))
                .foregroundStyle(.secondary)
            Text(badge.branch ?? "git")
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: uiSize(10), weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.branch.map { "Git branch \($0)" } ?? "Git repository")
        .accessibilityIdentifier("mdv.sessionTab.git.\(snapshot.id.uuidString)")
    }

    private var renameField: some View {
        TextField("", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: uiSize(12), weight: isSelected ? .semibold : .regular))
            .focused($isEditorFocused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onSubmit { onCommitRename(draftName) }
            .onExitCommand { onCancelRename() }
            .accessibilityIdentifier("mdv.sessionTab.rename.\(snapshot.id.uuidString)")
    }

    private var background: Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(0.18)
        }
        if isHovering {
            return Palette.controlBackground.opacity(0.4)
        }
        return Color.clear
    }

    private var helpText: String {
        if let path = snapshot.sidebarRootPath, !path.isEmpty {
            return "\(snapshot.displayName) — \(path)"
        }
        return snapshot.displayName
    }

    /// UX-H: tooltip body — the session's folder path (the title already
    /// carries the display name, so the description need not repeat it).
    private var sessionTooltipDescription: String {
        if let path = snapshot.sidebarRootPath, !path.isEmpty { return path }
        return ""
    }

    private func accessibilityLabel(_ badge: SessionGitInfo.Badge) -> String {
        var base = "Session: \(snapshot.displayName)"
        if badge.isRepoRoot {
            base += badge.branch.map { ", git branch \($0)" } ?? ", git repository"
        }
        return isSelected ? base + ", selected" : base
    }
}

// MARK: - Context menu -------------------------------------------------

private struct SessionTabContextMenu: View {
    @ObservedObject var sessionsApp: SessionsAppCoordinator
    let snapshot: SessionSnapshot
    let onRequestRename: () -> Void

    var body: some View {
        Button("Rename Session") { onRequestRename() }
        Button("Close Session") { sessionsApp.close(id: snapshot.id) }
        Button("Close Other Sessions") {
            sessionsApp.closeOthers(except: snapshot.id)
        }
        .disabled(sessionsApp.core.sessions.count <= 1)
        Divider()
        if let path = snapshot.sidebarRootPath, !path.isEmpty {
            Button("Copy Path") { Pasteboard.copy(path) }
            Button("Reveal in Finder") {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

// MARK: - Pure logic ---------------------------------------------------

/// Pure label helpers — exposed for unit testing without spinning up
/// a SwiftUI view tree.
public enum SessionTabLabel {
    /// Truncate a session display name so it fits inside the pill
    /// without relying on SwiftUI's middle-truncation alone. We trim
    /// to `limit` characters and insert a middle ellipsis so the
    /// leading + trailing components remain recognisable (e.g. a
    /// path-leaf prefix and a worktree disambiguator suffix).
    ///
    /// The SwiftUI text view already does middle truncation at render
    /// time; this exists for a11y labels, tooltips, and tests where
    /// we want a deterministic string.
    public static func truncated(_ name: String, limit: Int = 32) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit >= 5 else { return trimmed }
        // Reserve 1 char for the ellipsis; split the remainder so the
        // head is slightly longer than the tail (more recognisable).
        let budget = limit - 1
        let head = budget - budget / 2
        let tail = budget / 2
        let prefix = trimmed.prefix(head)
        let suffix = trimmed.suffix(tail)
        return "\(prefix)…\(suffix)"
    }
}

/// TSK-274: drop target on a session pill for a dragged document tab
/// (payload: `TabDragPayload`, the same wire format the tab strip's
/// reorder delegate consumes). Resolution to a live tab + the move
/// itself happen in `SessionsAppCoordinator.moveTab` at drop time.
private struct SessionTabDropDelegate: DropDelegate {
    let sessionsApp: SessionsAppCoordinator
    let targetSessionID: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String,
                  let tabID = TabDragPayload.tabID(from: str) else { return }
            Task { @MainActor in
                sessionsApp.moveTab(withID: tabID, toSessionID: targetSessionID)
            }
        }
        return true
    }
}
