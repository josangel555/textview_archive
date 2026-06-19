import Foundation

/// Unified, host-testable roll-up of the TWO diagnostics surfaces the
/// app currently keeps apart:
///
/// 1. **Real diagnostics** — `textDocument/publishDiagnostics` entries,
///    today held in `LSPDiagnosticsStore` (keyed by file URL) and
///    rendered by `LSPProblemsPanel`.
/// 2. **Server health** — per-server liveness / crash / latency, today
///    polled into `LSPDiagnosticsView` from `[LSPPool.StatusSnapshot]`.
///
/// This view-model collapses both into one value type computed over
/// *plain inputs* — `[(URL, [LSPDiagnostic])]` + `[LSPPool.StatusSnapshot]`.
/// It owns NO pool, NO actor, NO `ObservableObject`: callers pass in the
/// already-extracted snapshots, so it is fully exercisable from a host
/// unit test (no GUI / VM, no live server). `LSPProblemsPanel` and
/// `LSPDiagnosticsView` can later read it instead of duplicating the
/// count/sort/filter/empty-message logic each maintains independently.
///
/// Pure / `Sendable`: every member is a value computed once at `init`,
/// so the whole struct is safe to hand across isolation domains.
///
/// Reference: LSP design plan §2.2 (unified Problems model), §4(b)
/// (server-health visibility). See `LSPProblemsPanel.emptyMessage` and
/// UAT LSP-01 for the "not analyzed vs no problems" distinction this
/// model encodes as `EmptyState`.
public struct LSPProblemsViewModel: Sendable {

    // MARK: - Inputs (retained for grouped/filtered re-derivation)

    /// Diagnostics grouped by file, sorted: URLs by path, then each
    /// file's diagnostics by (line, character). This is the canonical
    /// rendering order — a consumer can iterate it straight without
    /// re-sorting. Empty diagnostic lists are dropped (an empty publish
    /// means "no problems for this file", matching `LSPDiagnosticsStore`'s
    /// remove-on-empty semantics).
    public let fileGroups: [FileGroup]

    /// Per-server health roll-up, one entry per `StatusSnapshot`, sorted
    /// by the server key's description for stable ordering.
    public let servers: [ServerHealth]

    // MARK: - Diagnostic count roll-ups

    /// Total diagnostics across all files (all severities).
    public let totalCount: Int
    public let errorCount: Int
    public let warningCount: Int
    public let informationCount: Int
    public let hintCount: Int

    /// Number of distinct files carrying at least one diagnostic.
    public let fileCount: Int

    // MARK: - Nested types

    /// One file's diagnostics, pre-sorted for rendering.
    public struct FileGroup: Sendable, Equatable {
        public let url: URL
        public let diagnostics: [LSPDiagnostic]

        public var errorCount: Int { diagnostics.lazy.filter { $0.severity == .error }.count }
        public var warningCount: Int { diagnostics.lazy.filter { $0.severity == .warning }.count }

        public init(url: URL, diagnostics: [LSPDiagnostic]) {
            self.url = url
            self.diagnostics = diagnostics
        }
    }

    /// Health roll-up for one language server, distilled from a
    /// `StatusSnapshot` into the fields a status row actually renders.
    public struct ServerHealth: Sendable, Equatable {
        public let key: LSPPool.Key
        /// Coarse lifecycle bucket — what a status dot/label shows.
        public let state: State
        public let crashCount: Int
        public let requestCount: Int
        public let lastError: String?
        public let lastResponseMillis: Double?

        public enum State: String, Sendable {
            case live
            case dead
            /// Neither live nor dead — `cold` / `starting` in the pool's
            /// state machine. Surfaced to the user as "starting".
            case starting

            /// User-facing label for a status badge.
            public var label: String {
                switch self {
                case .live:     return "live"
                case .dead:     return "dead"
                case .starting: return "starting"
                }
            }
        }

        public init(key: LSPPool.Key, state: State, crashCount: Int,
                    requestCount: Int, lastError: String?,
                    lastResponseMillis: Double?) {
            self.key = key
            self.state = state
            self.crashCount = crashCount
            self.requestCount = requestCount
            self.lastError = lastError
            self.lastResponseMillis = lastResponseMillis
        }

        /// One-line health summary, e.g.
        /// `"Swift (sourcekit-lsp): live · 12 reqs · 1 crash · 3ms"`.
        /// `· N crash` is omitted when crash-free; the last error is
        /// appended when present.
        public var summary: String {
            var parts: [String] = [state.label]
            parts.append("\(requestCount) " + (requestCount == 1 ? "req" : "reqs"))
            if crashCount > 0 {
                parts.append("\(crashCount) " + (crashCount == 1 ? "crash" : "crashes"))
            }
            if let ms = lastResponseMillis {
                parts.append(String(format: "%.0fms", ms))
            }
            var line = "\(key.language.displayName): " + parts.joined(separator: " · ")
            if let err = lastError, !err.isEmpty {
                line += " — \(err)"
            }
            return line
        }
    }

    /// Severity filter for `filtered(by:)`. Mirrors the panel's filter
    /// pill set: `all`, errors-only, warnings-only — but expressed over
    /// the model so the host test can pin the filtered result without a
    /// SwiftUI view.
    public enum SeverityFilter: Sendable, Equatable {
        case all
        case severity(LSPDiagnostic.Severity)

        public static let errors: SeverityFilter = .severity(.error)
        public static let warnings: SeverityFilter = .severity(.warning)
    }

    /// What the empty state of the Problems list should say. Encodes the
    /// LSP-01 distinction: an empty store for a file the server was never
    /// asked about ("not analyzed") must NOT read as a green all-clear.
    public enum EmptyState: Sendable, Equatable {
        /// At least one diagnostic exists — the list is non-empty.
        case nonEmpty
        /// No diagnostics, and the active file is a supported language
        /// that was never opened to a server (Source view never sends
        /// `didOpen`). Show "Not analyzed", not "no problems".
        case notAnalyzed
        /// No diagnostics and the active file was analyzed (or there is
        /// no LSP-relevant active file) — a genuine clean bill of health.
        case noProblems
    }

    // MARK: - Construction

    /// Build the roll-up from the two raw inputs.
    ///
    /// - Parameters:
    ///   - diagnosticsByFile: `(url, diagnostics)` pairs straight from an
    ///     `LSPDiagnosticsStore.byURL` (order irrelevant — re-sorted here).
    ///     Files with an empty diagnostic list are dropped.
    ///   - serverStatuses: `LSPPool.snapshot()` output (order irrelevant —
    ///     re-sorted by key description).
    public init(
        diagnosticsByFile: [(url: URL, diagnostics: [LSPDiagnostic])],
        serverStatuses: [LSPPool.StatusSnapshot]
    ) {
        // --- File groups: drop empty, sort URLs by path, diags by pos.
        let groups: [FileGroup] = diagnosticsByFile
            .filter { !$0.diagnostics.isEmpty }
            .sorted { $0.url.path < $1.url.path }
            .map { pair in
                let sorted = pair.diagnostics.sorted { lhs, rhs in
                    if lhs.range.start.line != rhs.range.start.line {
                        return lhs.range.start.line < rhs.range.start.line
                    }
                    return lhs.range.start.character < rhs.range.start.character
                }
                return FileGroup(url: pair.url, diagnostics: sorted)
            }
        self.fileGroups = groups
        self.fileCount = groups.count

        // --- Count roll-ups (single pass over all diagnostics).
        var total = 0, errors = 0, warnings = 0, infos = 0, hints = 0
        for g in groups {
            for d in g.diagnostics {
                total += 1
                switch d.severity {
                case .error:       errors += 1
                case .warning:     warnings += 1
                case .information: infos += 1
                case .hint:        hints += 1
                }
            }
        }
        self.totalCount = total
        self.errorCount = errors
        self.warningCount = warnings
        self.informationCount = infos
        self.hintCount = hints

        // --- Server health roll-up.
        self.servers = serverStatuses
            .map { snap in
                let state: ServerHealth.State
                if snap.isLive { state = .live }
                else if snap.isDead { state = .dead }
                else { state = .starting }
                return ServerHealth(
                    key: snap.key,
                    state: state,
                    crashCount: snap.status.crashCount,
                    requestCount: snap.status.requestCount,
                    lastError: snap.status.lastError,
                    lastResponseMillis: snap.status.lastResponseMillis)
            }
            .sorted { $0.key.description < $1.key.description }
    }

    // MARK: - Derived views

    /// Flat list of `(url, diagnostic)` across all files, in rendering
    /// order (file-group order, then in-file order). The shape the
    /// existing `LSPProblemsPanel` rows iterate.
    public var allFlat: [(url: URL, diagnostic: LSPDiagnostic)] {
        var out: [(URL, LSPDiagnostic)] = []
        out.reserveCapacity(totalCount)
        for g in fileGroups {
            for d in g.diagnostics { out.append((g.url, d)) }
        }
        return out
    }

    /// Flat list filtered by severity. `.all` returns `allFlat`.
    public func filtered(by filter: SeverityFilter) -> [(url: URL, diagnostic: LSPDiagnostic)] {
        switch filter {
        case .all:
            return allFlat
        case .severity(let sev):
            return allFlat.filter { $0.diagnostic.severity == sev }
        }
    }

    // MARK: - Empty-state / message selection

    /// Decide which empty state to present given whether the active file
    /// is a supported-but-unanalyzed file. Mirrors the LSP-01 logic in
    /// `LSPProblemsPanel.emptyMessage`, but as pure data so it is
    /// host-testable.
    ///
    /// - Parameter activeFileUnanalyzed: true when the active file has a
    ///   registered LSP language but no diagnostics in the store (Source
    ///   view path — never `didOpen`'d).
    public func emptyState(activeFileUnanalyzed: Bool) -> EmptyState {
        guard totalCount == 0 else { return .nonEmpty }
        return activeFileUnanalyzed ? .notAnalyzed : .noProblems
    }

    /// The user-facing message for the empty/filtered Problems list.
    ///
    /// - `hasActiveFilter` true when a non-`.all` severity filter is
    ///   active AND it produced zero rows despite the store being
    ///   non-empty — yields "No problems match this filter."
    public func emptyMessage(activeFileUnanalyzed: Bool, hasActiveFilter: Bool) -> String {
        if totalCount > 0 && hasActiveFilter {
            return "No problems match this filter."
        }
        switch emptyState(activeFileUnanalyzed: activeFileUnanalyzed) {
        case .nonEmpty, .noProblems:
            return "No problems detected."
        case .notAnalyzed:
            return "Not analyzed. Open in Editor to see problems."
        }
    }

    // MARK: - Server-health roll-up summary

    /// Count of servers currently live.
    public var liveServerCount: Int { servers.lazy.filter { $0.state == .live }.count }
    /// Count of servers currently dead.
    public var deadServerCount: Int { servers.lazy.filter { $0.state == .dead }.count }
    /// Total crash count across all tracked servers.
    public var totalCrashCount: Int { servers.reduce(0) { $0 + $1.crashCount } }
    /// Whether any tracked server is dead OR has crashed at least once —
    /// the condition for a degraded-health indicator.
    public var hasUnhealthyServer: Bool {
        servers.contains { $0.state == .dead || $0.crashCount > 0 }
    }

    /// One-line summary of the whole server fleet's health, e.g.
    /// `"2 servers · 1 live, 1 dead · 1 crash"`. When no servers are
    /// tracked: `"No language servers active."`.
    public var serverHealthSummary: String {
        guard !servers.isEmpty else { return "No language servers active." }
        let n = servers.count
        var line = "\(n) " + (n == 1 ? "server" : "servers")
        line += " · \(liveServerCount) live"
        if deadServerCount > 0 {
            line += ", \(deadServerCount) dead"
        }
        let crashes = totalCrashCount
        if crashes > 0 {
            line += " · \(crashes) " + (crashes == 1 ? "crash" : "crashes")
        }
        return line
    }
}
