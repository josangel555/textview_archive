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

    /// id of the session currently being inline-renamed (nil = none).
    @State private var renamingID: UUID?

    init(sessionsApp: SessionsAppCoordinator) {
        self.sessionsApp = sessionsApp
        self.core = sessionsApp.core
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(core.sessions.enumerated()), id: \.element.id) { index, snap in
                        SessionTabBarItem(
                            snapshot: snap,
                            isSelected: core.activeID == snap.id,
                            isRenaming: renamingID == snap.id,
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
                        if index < core.sessions.count - 1 {
                            Divider().frame(height: 16)
                        }
                    }
                }
            }
            Button(action: openNewSession) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Open Folder in New Session…")
            .padding(.horizontal, 4)
            .accessibilityIdentifier("mdv.sessionTab.new")
            .accessibilityLabel("Open Folder in New Session")
        }
        .frame(height: 30)
        .background(Palette.windowBackground)
        .accessibilityIdentifier("mdv.sessionTabBar")
    }

    /// Mirrors `AppDelegate.openFolderInNewSession(_:)`. We can't call
    /// the AppKit selector from here because SwiftUI views don't have
    /// a stable target chain to the AppDelegate; routing through the
    /// coordinator directly is the documented integration seam.
    private func openNewSession() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open folder in new session"
        if panel.runModal() == .OK, let url = panel.url {
            sessionsApp.openFolder(url, forceNew: true)
        }
    }
}

// MARK: - Item ---------------------------------------------------------

struct SessionTabBarItem: View {
    let snapshot: SessionSnapshot
    let isSelected: Bool
    let isRenaming: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var isHovering = false
    @State private var draftName = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Rectangle().fill(background)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: 14, height: 14)
                    if isRenaming {
                        renameField
                    } else {
                        Text(SessionTabLabel.truncated(snapshot.displayName))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || isSelected ? 0.6 : 0)
                    .help("Close Session")
                    .accessibilityLabel("Close \(snapshot.displayName)")
                    .accessibilityIdentifier("mdv.sessionTab.close.\(snapshot.id.uuidString)")
                }
                .padding(.horizontal, 10)
            }
            .frame(minWidth: 110, idealWidth: 180, maxWidth: 240)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
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

    private var renameField: some View {
        TextField("", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
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

    private var accessibilityLabel: String {
        let base = "Session: \(snapshot.displayName)"
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
