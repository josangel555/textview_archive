import AppKit
import SwiftUI
import ViewerCore

/// Finder-style "Go to the folder…" prompt (⇧⌘G). Paste an absolute
/// path, hit Return, the app opens it. Also surfaces an "Open System
/// Dialog…" escape hatch for users who'd rather navigate via the
/// native NSOpenPanel — useful as the empty-session entry point.
///
/// # Accessibility identifiers (for UI tests on the VM)
///
/// All interactive elements expose stable `mdv.goto.*` identifiers so
/// the test-author agent can target them without scraping titles or
/// frames. Listed here so they're easy to grep:
///
///   - `mdv.goto.panel`            — the overlay container
///   - `mdv.goto.field`            — the path text field (autofocus)
///   - `mdv.goto.error`            — inline error text (only present
///                                   when validation fails)
///   - `mdv.goto.openButton`       — primary Open button
///   - `mdv.goto.openNewSessionButton`
///                                 — Shift-Return / "Open in New
///                                   Session" button (only enabled
///                                   when the path is a folder)
///   - `mdv.goto.systemDialogButton` — opens NSOpenPanel (files +
///                                   folders) and routes the pick
///                                   through `DocumentModel.openPath`.
///   - `mdv.goto.cancelButton`     — dismisses without opening
///   - `mdv.goto.historyHint`      — visible footer text describing
///                                   the Up/Down history affordance
///
/// History (Up/Down arrows on an empty field) cycles the persisted
/// `GoToPathHistoryStore` — capped at 10 entries.
struct GoToPathPrompt: View {
    @ObservedObject var model: DocumentModel
    /// Optional sessions coordinator. Used by "Open System Dialog…"
    /// when invoked as the empty-session entry point so a picked
    /// folder spawns a *new* session (forceNew). Nil falls back to
    /// `model.openPath` which mutates the active session.
    var sessionsApp: SessionsAppCoordinator?
    @State private var path: String = ""
    @State private var errorMessage: String? = nil
    @State private var historyIndex: Int? = nil
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                TextField("/Users/you/path/to/file-or-folder", text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit { submit(newSession: false) }
                    .onChange(of: path) { _, _ in
                        // Any typed change invalidates the history
                        // cursor — Up/Down again starts from newest.
                        historyIndex = nil
                        errorMessage = nil
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                    )
                    .accessibilityIdentifier("mdv.goto.field")
                    // TSK-314: the new-session flow opens prefilled with
                    // "~" (model-driven) so Enter immediately opens home.
                    // Seed only an untouched field — never clobber typing.
                    .onAppear {
                        if path.isEmpty, let prefill = model.goToPathPrefill {
                            path = prefill
                        }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .accessibilityIdentifier("mdv.goto.error")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            footer
        }
        .frame(width: 540)
        .background(Palette.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(radius: 24)
        .background(keyboardShortcuts)
        .accessibilityIdentifier("mdv.goto.panel")
        .onAppear {
            fieldFocused = true
            // Seed with the most recent entry's parent dir? No — match
            // Finder, which opens empty. Power-users hit Up immediately
            // for history.
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line")
                .foregroundStyle(.secondary)
            Text("Go to file or folder")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: { submit(newSession: false) }) {
                Label("Open", systemImage: "return")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("mdv.goto.openButton")

            Button(action: { submit(newSession: true) }) {
                Text("Open in New Session")
            }
            .disabled(!canOpenInNewSession)
            .accessibilityIdentifier("mdv.goto.openNewSessionButton")

            Button(action: { openSystemDialog() }) {
                Text("Open System Dialog…")
            }
            .accessibilityIdentifier("mdv.goto.systemDialogButton")

            Spacer()

            Text("↑↓ history  ·  ⎋ cancel")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mdv.goto.historyHint")

            Button(action: { model.dismissGoToPath() }) {
                Text("Cancel")
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("mdv.goto.cancelButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Hidden buttons to catch Up/Down without stealing left/right
    /// arrow from the text field's cursor motion. Same trick as the
    /// command palette.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("", action: { cycleHistory(delta: 1) })  // newer-ish → older
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("", action: { cycleHistory(delta: -1) })
                .keyboardShortcut(.upArrow, modifiers: [])
            // Shift+Return → "Open in New Session" for folders.
            Button("", action: { submit(newSession: true) })
                .keyboardShortcut(.return, modifiers: [.shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Logic

    /// True iff the current text resolves to an existing directory —
    /// the only case where "Open in New Session" is meaningful.
    private var canOpenInNewSession: Bool {
        guard model.openFolderInNewSession != nil else { return false }
        guard case .success(let expanded) = GoToPathExpansion.expand(path) else {
            return false
        }
        return GoToPathExpansion.isDirectory(expanded)
    }

    private func submit(newSession: Bool) {
        switch GoToPathExpansion.resolveExisting(path) {
        case .failure(let err):
            let message = userMessage(for: err)
            errorMessage = message
            // A11Y-15: the inline red error text isn't focusable, so
            // VoiceOver users would never hear that the path was
            // rejected. Announce it.
            AccessibilityAnnouncer.announce(message)
            return
        case .success(let url):
            // Persist the expanded absolute path for history.
            model.recordGoToPath(url.path)
            // `goToPathNewSessionIntent`: the prompt was invoked from the
            // SessionTabBar `+` (empty-session entry point), so a folder
            // confirm spawns a new session even on the default Return
            // path (TSK-600).
            if newSession || model.goToPathNewSessionIntent,
               GoToPathExpansion.isDirectory(url.path),
               let openInNew = model.openFolderInNewSession {
                openInNew(url)
            } else {
                // openPath auto-routes file vs folder via FileManager.
                model.openPath(url)
            }
            model.dismissGoToPath()
            path = ""
            errorMessage = nil
            historyIndex = nil
        }
    }

    /// Native NSOpenPanel escape hatch — picks either a file or a
    /// folder. When `sessionsApp` is set and the user picks a folder
    /// while the prompt was invoked as the empty-session entry point,
    /// the pick spawns a new session via `openFolder(forceNew: true)`.
    /// Otherwise routes through `openPath` (active session).
    private func openSystemDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open file or folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.recordGoToPath(url.path)
        var isDir: ObjCBool = false
        let isDirectory = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDir
        ) && isDir.boolValue
        if isDirectory, let sessionsApp {
            sessionsApp.openFolder(url, forceNew: true)
        } else {
            model.openPath(url)
        }
        model.dismissGoToPath()
        path = ""
        errorMessage = nil
        historyIndex = nil
    }

    private func userMessage(for err: GoToPathExpansion.Error) -> String {
        switch err {
        case .empty:    return "Enter an absolute path."
        case .relative: return "Path must be absolute (start with / or ~)."
        case .notFound: return "No file or folder at that path."
        }
    }

    /// Up = older (index +1) / Down = newer (index −1). On an empty
    /// field, Up enters history at newest (index 0); Down exits back
    /// to empty when stepping past the newest entry.
    private func cycleHistory(delta: Int) {
        let entries = model.goToPathHistory.recent()
        guard !entries.isEmpty else { return }

        // Only consume Up/Down when the field is empty OR the user is
        // already cycling history. Otherwise the arrows are useful for
        // intra-field cursor motion (... though in a single-line
        // TextField on macOS, Up/Down don't move the caret — keeping
        // the guard cheap defensively).
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if historyIndex == nil && !trimmed.isEmpty { return }

        let next: Int
        switch (historyIndex, delta) {
        case (nil, 1):  // empty + Down — nothing newer than nothing
            return
        case (nil, _):  // empty + Up → newest
            next = 0
        case (.some(let i), _):
            next = i + delta
        }
        if next < 0 {
            historyIndex = nil
            path = ""
        } else if next >= entries.count {
            historyIndex = entries.count - 1
        } else {
            historyIndex = next
            path = entries[next]
        }
    }
}
