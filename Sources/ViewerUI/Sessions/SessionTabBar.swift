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
                SessionStripContent(sessionsApp: sessionsApp,
                                    core: core,
                                    model: model,
                                    dropChannel: sessionsApp.tabDragChannel,
                                    rowHeight: rowHeight,
                                    renamingID: $renamingID,
                                    openNewSession: openNewSession)
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

/// The scrolling row of session pills, split out of `SessionTabBar` so the
/// reorder drag state lives at a leaf.
///
/// Same PERF #1 reasoning as `TabStripContent` (see its doc comment): the
/// drag needs `@State private var frameBox = StripFrameBox()`, whose
/// initializer allocates a fresh object on every view-value rebuild, costing
/// the owning view SwiftUI's body-skip — it would then re-body on every
/// unrelated parent republish. That is worse here than on the file strip:
/// each `SessionTabBarItem` body calls `SessionGitInfo.badge(forRootPath:)`,
/// which touches the filesystem. Guarded by `SessionStripReBodyTests`
/// (shown RED on the real break before shipping).
private struct SessionStripContent: View {
    @ObservedObject var sessionsApp: SessionsAppCoordinator
    @ObservedObject var core: SessionsCoordinator
    @ObservedObject var model: DocumentModel
    /// Cross-strip drop channel: a live TAB drag hit-tests these pills and
    /// publishes which one it hovers (`hoveredSessionID` → the drop-target
    /// highlight). Observed HERE (the leaf) so the highlight re-bodies the
    /// strip, but only when the hovered pill CHANGES — the channel dedups.
    /// The stable instance comes from `sessionsApp`, so observing it does
    /// not cost this view its body-skip (unlike a fresh `= Object()`
    /// initializer — see the PERF note above).
    @ObservedObject var dropChannel: TabSessionDropChannel
    let rowHeight: CGFloat
    @Binding var renamingID: UUID?
    let openNewSession: () -> Void

    /// Coordinate space the reorder geometry is measured in (the strip's
    /// scrolling content) — see `StripReorder`.
    private static let stripSpace = "mdv.sessionTabStrip"

    @State private var frameBox = StripFrameBox()
    @State private var reorder: StripReorderState?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(core.sessions.enumerated()), id: \.element.id) { index, snap in
                SessionTabBarItem(
                    snapshot: snap,
                    isSelected: core.activeID == snap.id,
                    isRenaming: renamingID == snap.id,
                    isDropTarget: dropChannel.hoveredSessionID == snap.id,
                    uiSize: model.uiSize,
                    // A reorder must not switch sessions — swallow the click
                    // that terminates a drag (`StripFrameBox`).
                    onSelect: {
                        guard !frameBox.shouldSuppressSelect() else { return }
                        sessionsApp.activate(id: snap.id)
                    },
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
                // Drag-to-reorder, same mechanism as the file tab strip
                // (`StripReorder`). Session pills size to their content, so
                // the gap is computed from MEASURED item frames rather than
                // an index × width estimate.
                .stripReorderable(
                    id: snap.id,
                    index: index,
                    ids: core.sessions.map(\.id),
                    space: Self.stripSpace,
                    frames: frameBox,
                    state: $reorder,
                    commit: { draggedID, gap in
                        // Re-resolve against the LIVE session list — a
                        // session can close mid-drag; see
                        // `StripReorder.resolveMove`.
                        guard let move = StripReorder.resolveMove(
                            itemID: draggedID,
                            ids: core.sessions.map(\.id),
                            gap: gap) else { return }
                        // Animated by the shared drop transaction — see TabBar.
                        sessionsApp.moveSession(from: move.source,
                                                to: move.destination)
                    }
                )
                // Cross-strip drop target: publish this pill's GLOBAL frame
                // so a live TAB drag can hit-test it (tab → session move).
                .sessionDropTargetFrame(id: snap.id, into: dropChannel)
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
                // Named save points are also retrievable from the
                // create-session place (2026-07-31). Menu content builds
                // on open — the saved-list read never rides a re-body.
                Divider()
                SavedSessionsMenuSection(sessionsApp: sessionsApp)
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
        // Reorder geometry — pill frames and the drag pointer share this
        // coordinate space so the caret lands on the real gap.
        .coordinateSpace(name: Self.stripSpace)
        .overlay(alignment: .leading) {
            if let x = reorder?.caretX {
                StripInsertionCaret(x: x, height: rowHeight - model.uiSize(12))
            }
        }
    }
}

struct SessionTabBarItem: View {
    let snapshot: SessionSnapshot
    let isSelected: Bool
    let isRenaming: Bool
    /// A live tab drag is hovering this pill: light it up as the drop
    /// target (accent ring + tint) so the user can see WHERE the tab will
    /// land before releasing. Driven by `TabSessionDropChannel`.
    let isDropTarget: Bool
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
            // Drop-target ring: unambiguous "the tab lands HERE" affordance
            // over the tint. Gated by the codified negative-control switch
            // (TSK-1134 pattern) so the T5 pixel guard can prove its own
            // teeth without hand-reverting.
            .overlay {
                if isDropTarget, !MDVNegativeControl.isBroken("SESSION_DROP_HIGHLIGHT") {
                    RoundedRectangle(cornerRadius: uiSize(5))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(uiSize(2))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(
                            "mdv.sessionTab.dropTarget.\(snapshot.id.uuidString)")
                }
            }
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
        // Drop-target tint outranks selection: while a drag is over this
        // pill, "the tab lands here" is the message that matters.
        if isDropTarget, !MDVNegativeControl.isBroken("SESSION_DROP_HIGHLIGHT") {
            return Color(nsColor: .controlAccentColor).opacity(0.28)
        }
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
        // Named save points (2026-07-31): freeze this session — tabs,
        // selection, scroll, unsaved buffers — under a name; restore
        // later as a NEW session. Menu content builds on OPEN, so the
        // saved-list disk read never rides a strip re-body.
        Button("Save Session As\u{2026}") {
            guard let name = SaveSessionPrompt.run(currentName: snapshot.displayName)
            else { return }
            if sessionsApp.saveSession(id: snapshot.id, named: name) != nil {
                ToastCenter.shared.post(.info, "Saved session \u{201C}\(name)\u{201D}")
            } else {
                ToastCenter.shared.post(.error, "Couldn\u{2019}t save the session")
            }
        }
        .accessibilityIdentifier("mdv.sessionTab.saveAs")
        SavedSessionsMenuSection(sessionsApp: sessionsApp)
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

// MARK: - Saved sessions menu section -----------------------------------

/// The "Saved Sessions ▸" retrieval surface, shared by the session-pill
/// context menu and the "+" menu. Its body runs when the OWNING MENU is
/// opened — never on a strip re-body — so listing save points (a small
/// directory read + decode) stays off the render path. Renders nothing
/// when there are no save points.
struct SavedSessionsMenuSection: View {
    @ObservedObject var sessionsApp: SessionsAppCoordinator

    var body: some View {
        let saved = sessionsApp.savedSessions()
        if !saved.isEmpty {
            Menu("Saved Sessions") {
                ForEach(saved, id: \.id) { point in
                    Menu(SessionTabLabel.truncated(point.displayName)) {
                        Button("Open as New Session") {
                            _ = sessionsApp.restoreSavedSession(id: point.id)
                        }
                        .accessibilityIdentifier(
                            "mdv.sessionTab.savedRestore.\(point.id.uuidString)")
                        Text(Self.subtitle(for: point))
                        Divider()
                        Button("Delete Save Point", role: .destructive) {
                            sessionsApp.deleteSavedSession(id: point.id)
                        }
                        .accessibilityIdentifier(
                            "mdv.sessionTab.savedDelete.\(point.id.uuidString)")
                    }
                }
            }
            .accessibilityIdentifier("mdv.sessionTab.savedSessions")
        }
    }

    /// "3 tabs · saved Jul 31, 14:02" — enough to tell twins apart.
    static func subtitle(for point: SessionSnapshot) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        let tabs = point.openTabs.count
        let tabWord = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        return "\(tabWord) \u{00B7} saved \(fmt.string(from: point.savedAt))"
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

// TSK-274's `SessionTabDropDelegate` lived here: a drop target on each
// session pill that accepted a document tab dragged off the file tab strip
// and moved that file into the session. Its only producer was `TabBar`'s
// `.onDrag`, which drag-to-reorder replaced, so the delegate could no
// longer fire — a dead channel that also SWALLOWED file drops (it returned
// true unconditionally, so a file dragged from the sidebar onto a pill did
// nothing instead of falling through to the window's open handler).
//
// 2026-07-31: the DRAG affordance is BACK, on the reorder gesture rather
// than the pasteboard — `TabSessionDropChannel` + `StripExternalTarget`
// let the tab strip's DragGesture hit-test these pills directly (with the
// hovered pill highlighted), so no drop-delegate/item-provider round-trip
// and no swallowed file drops. (`FileDragProviderTests` greps this file to
// keep the pasteboard forms out — don't name them here.) The context
// menu's "Move to Session ▸" stays as the discoverable, host-testable
// path; both call the same
// `SessionsAppCoordinator.moveTab(withID:toSessionID:)`
// (`TabToNewSessionTests`).
