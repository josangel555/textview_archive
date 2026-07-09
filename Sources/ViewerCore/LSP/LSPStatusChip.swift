import Foundation

/// The user-facing state of the language server for the *currently focused
/// file*, distilled from the pool's raw health snapshot into the four
/// states a status affordance needs to show. TSK-1444.
///
/// Why this exists: LSP features (hover / go-to-def / completion /
/// diagnostics) degrade **silently** today — if the server never started,
/// crashed, or isn't installed, the feature just "does nothing" with no
/// signal. `LSPPool.snapshot()` carries the raw health (`isLive` / `isDead`
/// / `crashCount` / `lastError`), but two things are missing before it can
/// drive a chip:
///   1. A **missing binary never gets a pool entry** — `ensureLive` throws
///      `serverBinaryNotFound` and drops the key, so "not installed" can't
///      come from the snapshot. It has to be derived from the registry
///      (does this language have a discoverable server binary?).
///   2. The snapshot is per-`(language, workspaceRoot)`; the chip cares
///      about the ONE key that serves the focused file.
///
/// `classify` folds both in. It is **pure** (no I/O, no actor hop) so the
/// whole state machine is host-testable; the view layer feeds it the
/// current language + a precomputed `binaryAvailable` flag (the availability
/// probe shells out, so the model does it off-main and caches it).
public struct LSPStatusChip: Equatable, Sendable {

    /// Four user-facing states. `idle` and `running` are both "healthy";
    /// they're distinct so the chip can show "ready but not started yet"
    /// (cold — no request has spun the server up) vs "live and serving".
    public enum State: String, Equatable, Sendable, CaseIterable {
        /// A live server is serving this file's workspace.
        case running
        /// The server binary is present but no live server exists yet
        /// (cold / reaped / mid-start). The common state right after
        /// opening a file, before the first hover/definition request.
        case idle
        /// The server is dead (restart cooldown) or has crashed at least
        /// once and been demoted — features are degraded until it respawns.
        case failed
        /// No server binary could be located for this language.
        case notInstalled
    }

    /// Semantic tint for the chip. ViewerCore is SwiftUI-free, so the view
    /// maps these to concrete `Color`s (green / red / orange / secondary).
    public enum Tint: String, Equatable, Sendable {
        case ok        // running
        case neutral   // idle
        case error     // failed
        case warning   // notInstalled
    }

    public let language: LSPLanguage
    public let state: State
    /// State-specific supplemental text: the server's `lastError` for
    /// `failed`, the language's `installHint` for `notInstalled`, a request
    /// summary for `running`. `nil` when there's nothing to add.
    public let detail: String?

    public init(language: LSPLanguage, state: State, detail: String?) {
        self.language = language
        self.state = state
        self.detail = detail
    }

    // MARK: - Display (pure — host-testable without a view)

    /// SF Symbol name for the chip's leading glyph.
    public var symbolName: String {
        switch state {
        case .running:      return "checkmark.circle.fill"
        case .idle:         return "circle.dashed"
        case .failed:       return "exclamationmark.triangle.fill"
        case .notInstalled: return "xmark.circle"
        }
    }

    /// Compact chip label, e.g. "Swift" / "Python".
    public var label: String { language.shortName }

    public var tint: Tint {
        switch state {
        case .running:      return .ok
        case .idle:         return .neutral
        case .failed:       return .error
        case .notInstalled: return .warning
        }
    }

    /// One-line accessibility / tooltip description of the state.
    public var accessibilityDescription: String {
        switch state {
        case .running:
            return "\(language.shortName) language server: running"
        case .idle:
            return "\(language.shortName) language server: ready (not started)"
        case .failed:
            let why = detail.map { " — \($0)" } ?? ""
            return "\(language.shortName) language server: failed\(why)"
        case .notInstalled:
            let hint = detail.map { " — install: \($0)" } ?? ""
            return "\(language.shortName) language server: not installed\(hint)"
        }
    }

    // MARK: - Classification (the pure state machine)

    /// Fold the pool's raw health snapshot + registry-derived availability
    /// into the chip state for the focused file's language.
    ///
    /// - Parameters:
    ///   - language: the focused file's LSP language, or `nil` if the file
    ///     has no LSP-eligible extension (or no file is open). `nil` ⇒ no
    ///     chip (returns `nil`).
    ///   - workspaceRoot: the resolved workspace root for the focused file,
    ///     used to disambiguate when the pool holds multiple keys for the
    ///     same language (rare). `nil` falls back to language-only matching.
    ///   - binaryAvailable: whether this language's server binary is
    ///     discoverable on this machine. Consulted ONLY when the pool has no
    ///     entry for the language (a live/dead entry proves availability).
    ///   - snapshot: `LSPPool.snapshot()`.
    /// - Returns: the chip to render, or `nil` to hide the chip entirely.
    public static func classify(
        language: LSPLanguage?,
        workspaceRoot: URL?,
        binaryAvailable: Bool,
        snapshot: [LSPPool.StatusSnapshot]
    ) -> LSPStatusChip? {
        guard let language else { return nil }

        if let entry = bestMatch(
            in: snapshot, language: language, preferredRoot: workspaceRoot
        ) {
            if entry.isLive {
                let reqs = entry.status.requestCount
                let detail = reqs > 0 ? "\(reqs) request\(reqs == 1 ? "" : "s")" : nil
                return LSPStatusChip(language: language, state: .running, detail: detail)
            }
            if entry.isDead {
                return LSPStatusChip(
                    language: language, state: .failed, detail: entry.status.lastError)
            }
            // Neither live nor in dead-cooldown. A non-zero crash count means
            // the server died and was demoted to cold (it will respawn on the
            // next request) — surface that as `failed` so the user sees the
            // degradation window, not a misleading "ready". A zero crash count
            // is a genuine cold/starting entry.
            if entry.status.crashCount > 0 {
                return LSPStatusChip(
                    language: language, state: .failed, detail: entry.status.lastError)
            }
            return LSPStatusChip(language: language, state: .idle, detail: nil)
        }

        // No pool entry for this language yet. If the binary can't be found,
        // the feature is silently unavailable — surface it with the install
        // hint. Otherwise the server simply hasn't been spun up yet (idle).
        if binaryAvailable {
            return LSPStatusChip(language: language, state: .idle, detail: nil)
        }
        return LSPStatusChip(
            language: language, state: .notInstalled, detail: language.installHint)
    }

    /// UAT / testing hook: build a forced chip from the `MDV_LSP_STATUS_FAKE`
    /// env value so a scene can render a deterministic chip without a live
    /// language server. Format: `"<state>"` or `"<state>:<language>"`
    /// (e.g. `failed:python`, `notInstalled:typescript`, `running`). Returns
    /// `nil` for an unrecognized state. TSK-1444.
    public static func fake(fromEnvValue value: String) -> LSPStatusChip? {
        let parts = value.split(separator: ":", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let stateRaw = parts.first, let state = State(rawValue: stateRaw) else {
            return nil
        }
        let language: LSPLanguage = parts.count > 1
            ? (LSPLanguage(rawValue: parts[1]) ?? .swift) : .swift
        let detail: String?
        switch state {
        case .notInstalled: detail = language.installHint
        case .failed:       detail = "server exited (status 1)"
        case .running:      detail = "12 requests"
        case .idle:         detail = nil
        }
        return LSPStatusChip(language: language, state: state, detail: detail)
    }

    /// Pick the snapshot entry that best represents `language` for the
    /// focused file. Preference order: exact `(language, root)` match →
    /// a live entry → a dead entry → any. This matters only in the rare
    /// case of two workspace roots serving the same language in one window.
    private static func bestMatch(
        in snapshot: [LSPPool.StatusSnapshot],
        language: LSPLanguage,
        preferredRoot: URL?
    ) -> LSPPool.StatusSnapshot? {
        let candidates = snapshot.filter { $0.key.language == language }
        guard !candidates.isEmpty else { return nil }
        if let root = preferredRoot?.standardizedFileURL,
           let exact = candidates.first(where: { $0.key.workspaceRoot == root }) {
            return exact
        }
        if let live = candidates.first(where: { $0.isLive }) { return live }
        if let dead = candidates.first(where: { $0.isDead }) { return dead }
        return candidates.first
    }
}
