import Foundation
import ViewerCore
import ViewerKit

/// Curated diagnostic-snapshot accessor for `DocumentModel`.
///
/// HOT-FILE RULE: added as an extension in a NEW file rather than editing the
/// 2700-line `DocumentModel.swift`, to avoid colliding with the stage-2b
/// hot-zone agent.
///
/// We HAND-CURATE a flat `DiagnosticSnapshot` rather than deriving `Codable`
/// from the live model (PRIORITIZED_PLAN item 17; triage "do NOT auto-derive
/// Codable"). The model is full of closures/stores/NSObjects and — critically
/// — full document bytes; a curated snapshot of *facts* (paths, sizes, state
/// kinds) is both serialisable and safe. Document **content** never enters the
/// snapshot; absolute paths are carried raw here and redacted at export time
/// by `DiagnosticSnapshot.redactingPaths()` / `DiagnosticDumpWriter`.
@MainActor
extension DocumentModel {

    /// Capture the synchronous portion of the diagnostic snapshot: process
    /// info, the curated tab/document state, the temp files we own, and this
    /// process's open file descriptors. The (async, actor-bound) LSP
    /// subprocess list is filled separately by `diagnosticSubprocesses()` so
    /// this stays a cheap, non-blocking main-actor read.
    public func diagnosticSnapshot() -> DiagnosticSnapshot {
        let tabsState = tabs
        let tabSummaries: [DiagnosticTabSummary] = tabsState.tabs.map { tab in
            DiagnosticTabSummary(
                title: tab.title,
                path: tab.url?.path,
                stateKind: Self.stateKind(tab.state),
                viewMode: tab.viewMode.rawValue,
                isDirty: tab.isDirty,
                diskState: tab.diskState.rawValue,
                byteCount: Self.byteCount(tab.state))
        }

        // Observability roll-up: counts only, never event bodies (the buffer
        // holds raw message strings — a content-leak surface we never expose
        // here). The default sink is a no-op until the app installs a
        // RingBufferSink, so cast defensively.
        var bufferedEvents = 0
        var totalEmitted: UInt64 = 0
        if let ring = Obs.shared as? RingBufferSink {
            bufferedEvents = ring.bufferedCount
            totalEmitted = ring.emittedCount
        }

        return DiagnosticSnapshot(
            pid: getpid(),
            capturedAtUnixNanos: ObsClock.nowNanos(),
            isDebugBuild: DiagnosticGate.isDebugBuild,
            tabs: tabSummaries,
            selectedTabIndex: tabsState.selectedIndex,
            sidebarRootPath: sidebar.rootURL?.path,
            recentsCount: recents.count,
            bookmarksCount: bookmarks.count,
            tempFiles: DiagnosticProbes.ownedTempFiles(),
            openFDs: DiagnosticProbes.openFileDescriptors(),
            subprocesses: [],
            obsBufferedEvents: bufferedEvents,
            obsTotalEmitted: totalEmitted)
    }

    /// Async companion: snapshot the LSP pool's live servers as
    /// `DiagnosticSubprocess` rows. The pool is an actor, so this awaits; the
    /// window calls it after the synchronous snapshot and merges the result.
    public func diagnosticSubprocesses() async -> [DiagnosticSubprocess] {
        let statuses = await lspPool.snapshot()
        return statuses.map { s in
            let status: String
            if s.isLive { status = "live" }
            else if s.isDead { status = "dead" }
            else { status = "cold" }
            return DiagnosticSubprocess(
                subsystem: "lsp",
                label: s.key.description,            // "<lang>@<workspaceRoot.path>"
                status: status,
                path: s.key.workspaceRoot.path)
        }
    }

    /// Convenience: full snapshot including the async subprocess list.
    public func fullDiagnosticSnapshot() async -> DiagnosticSnapshot {
        let base = diagnosticSnapshot()
        let subs = await diagnosticSubprocesses()
        return DiagnosticSnapshot(
            pid: base.pid,
            capturedAtUnixNanos: base.capturedAtUnixNanos,
            isDebugBuild: base.isDebugBuild,
            tabs: base.tabs,
            selectedTabIndex: base.selectedTabIndex,
            sidebarRootPath: base.sidebarRootPath,
            recentsCount: base.recentsCount,
            bookmarksCount: base.bookmarksCount,
            tempFiles: base.tempFiles,
            openFDs: base.openFDs,
            subprocesses: subs,
            obsBufferedEvents: base.obsBufferedEvents,
            obsTotalEmitted: base.obsTotalEmitted)
    }

    // MARK: - Curation helpers (case-only; never reach into payload content)

    private static func stateKind(_ state: DocumentState) -> String {
        switch state {
        case .empty:   return "empty"
        case .loaded:  return "loaded"
        case .binary:  return "binary"
        case .error:   return "error"
        case .preview: return "preview"
        case .loading: return "loading"
        }
    }

    /// Size fact (not content) for a loaded/binary tab; nil otherwise.
    private static func byteCount(_ state: DocumentState) -> Int? {
        switch state {
        case .loaded(let f):  return f.byteCount
        case .binary(let b):  return b.totalByteCount
        default:              return nil
        }
    }
}
