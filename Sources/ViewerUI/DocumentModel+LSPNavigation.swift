import Foundation
import ViewerCore

// LSP go-to navigation (TSK-1110 SRP slice; TSK-464) — the four LSP go-to verbs
// (definition / declaration / typeDefinition / implementation) as deliberate
// commands: resolve at a position and jump to the first result (single-pick,
// silent-failure). Cmd-click routes through `handleEditorDefinition`; the palette /
// menu verbs through `navigateViaLSPAtCursor`. The `_lastLSPNavigation` DEBUG probe,
// the `lspLanguageConfigured`/`lspPosition` seams (+LSPShared), and `openPath` stay
// on DocumentModel. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// The four LSP go-to verbs surfaceable as deliberate commands
    /// (TSK-464 — previously only `definition` was reachable, and only
    /// via Cmd-click/right-click in the editor).
    public enum LSPNavigationKind: String, Sendable, CaseIterable {
        case definition
        case declaration
        case typeDefinition
        case implementation
    }

    /// JS posted a Cmd-click. Resolve via LSP `definition`; on a
    /// single result, open the target tab + jump to the line. Multi-
    /// result is single-pick for now (first result) — matches the
    /// source-view's "go to first" default until the picker UI lands.
    public func handleEditorDefinition(
        tabID: UUID, fileURL: URL, request: CMPositionRequest
    ) {
        navigateViaLSP(kind: .definition, tabID: tabID, fileURL: fileURL, request: request)
    }

    /// Generalized LSP go-to: resolve `kind` at the given position and
    /// jump to the first result. Same single-pick + silent-failure
    /// contract as `handleEditorDefinition` (which delegates here).
    public func navigateViaLSP(
        kind: LSPNavigationKind, tabID: UUID, fileURL: URL, request: CMPositionRequest
    ) {
        guard lspLanguageConfigured(for: fileURL) else { return }
        let (lspLine, lspChar) = lspPosition(
            line: request.line, character: request.character)
        #if DEBUG
        _lastLSPNavigation = (kind, fileURL, lspLine, lspChar)
        #endif
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let pool = self.lspPool
                let locs: [LSPLocation]
                switch kind {
                case .definition:
                    locs = try await pool.definition(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                case .declaration:
                    locs = try await pool.declaration(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                case .typeDefinition:
                    locs = try await pool.typeDefinition(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                case .implementation:
                    locs = try await pool.implementation(
                        fileURL: fileURL, line: lspLine, character: lspChar)
                }
                guard let first = locs.first else { return }
                let targetLine = first.range.start.line + 1 // back to 1-based
                guard let targetURL = URL(string: first.uri) else { return }
                await MainActor.run {
                    self.openPath(targetURL, atLine: targetLine)
                }
            } catch {
                // Navigation lookup failures are silent — there's no
                // UI surface for "LSP returned nothing"; users notice
                // by absence of navigation. Logged at trace level.
            }
        }
    }

    /// Command/verb entry: run an LSP go-to at the ACTIVE editor cursor.
    /// Returns false (and does nothing) when there's no selected tab
    /// with a URL or no recorded editor cursor — the command is a no-op
    /// rather than a guess at line 1.
    @discardableResult
    public func navigateViaLSPAtCursor(kind: LSPNavigationKind) -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard let cursor = editor.editorCursorByTab[tab.id] else { return false }
        navigateViaLSP(
            kind: kind, tabID: tab.id, fileURL: url,
            request: CMPositionRequest(line: cursor.line, character: cursor.column))
        return true
    }
}
