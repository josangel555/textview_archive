import Foundation

// MARK: - ReviewSidecar
//
// v2 §1.3/§1.4: the non-review files living inside `<repoRoot>/.textview/`.
// Two distinct concerns, both kept OUT of the tested `Review`/`ReviewStore`
// shapes:
//
//   • `session.json`  — review-scoped UI cursor (active review, draft
//                        export instructions, last-export mirror). Local,
//                        git-ignored even when reviews are tracked.
//   • `config.json`   — repo-level settings (tracked-vs-ignored, audit
//                        trail). Drives the `.gitignore` / `.gitattributes`
//                        the app writes on first use.
//
// Everything reads/writes through `JSONFileStore` (atomic, never-throws,
// shared ISO-8601 encoder), so these inherit the same crash-safety and
// size-guard surface as the review files.

// MARK: - SidecarSession (session.json)

/// Review-scoped session state persisted at `<repoRoot>/.textview/session.json`.
/// Deliberately tiny — it is a *cursor*, not review data. Cursor/scroll
/// position is out of scope (owned by the Sessions feature).
public struct SidecarSession: Codable, Equatable, Sendable {

    /// Bump on any breaking change; loads of a newer version are refused
    /// (mirrors `Review`'s forward-compat refusal).
    public static let currentSchema: Int = 1

    public var schemaVersion: Int

    /// Which review the Review tab reopens to. `nil` = none active.
    public var activeReviewId: String?

    /// Export instructions the user edited; survives relaunch. `nil` =
    /// use `ReviewExporter.defaultInstructions`.
    public var draftInstructions: String?

    /// Mirror of the newest export, for at-a-glance UI ("sent 3m ago").
    public var lastExport: LastExport?

    public struct LastExport: Codable, Equatable, Sendable {
        public let reviewId: String
        public let at: Date
        public let target: ReviewExportRecord.Target

        public init(reviewId: String, at: Date, target: ReviewExportRecord.Target) {
            self.reviewId = reviewId
            self.at = at
            self.target = target
        }
    }

    public init(
        schemaVersion: Int = SidecarSession.currentSchema,
        activeReviewId: String? = nil,
        draftInstructions: String? = nil,
        lastExport: LastExport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeReviewId = activeReviewId
        self.draftInstructions = draftInstructions
        self.lastExport = lastExport
    }
}

// MARK: - SidecarConfig (config.json)

/// Repo-level sidecar settings persisted at
/// `<repoRoot>/.textview/config.json`.
public struct SidecarConfig: Codable, Equatable, Sendable {

    public static let currentSchema: Int = 1

    public var schemaVersion: Int

    /// Whether `.textview/reviews/` is committed (default) or git-ignored.
    /// Drives which `.gitignore` body the app writes (§1.3).
    public var tracked: Bool

    /// Whether the optional append-only audit sidecar is written (§2.4).
    /// Off by default; the audit dir is git-ignored regardless.
    public var auditTrail: Bool

    public init(
        schemaVersion: Int = SidecarConfig.currentSchema,
        tracked: Bool = true,
        auditTrail: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.tracked = tracked
        self.auditTrail = auditTrail
    }
}

// MARK: - SidecarStore
//
// Read/write the two sidecar files + emit the git-tracking files. Stateless
// (just the sidecar root URL), so it's `Sendable` like `ReviewStore`.

public final class SidecarStore: Sendable {

    /// Same 10 MiB ceiling `ReviewStore` uses — a sidecar JSON bigger than
    /// this is corruption, not a legitimate cursor/config.
    public static let maxFileSize: Int = 10 * 1024 * 1024

    /// The `.textview/` root (NOT the `reviews/` tenant). Resolve via
    /// `ReviewStore.sidecarRoot(repoRoot:)`.
    public let sidecarRoot: URL

    public init(sidecarRoot: URL) {
        self.sidecarRoot = sidecarRoot
    }

    /// Convenience: resolve the sidecar root from a repo root + env, then
    /// build a store over it.
    public static func projectLocal(
        repoRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SidecarStore {
        SidecarStore(sidecarRoot: ReviewStore.sidecarRoot(
            repoRoot: repoRoot, environment: environment
        ))
    }

    // MARK: file URLs

    private var sessionURL: URL { sidecarRoot.appendingPathComponent("session.json") }
    private var configURL: URL { sidecarRoot.appendingPathComponent("config.json") }
    private var gitignoreURL: URL { sidecarRoot.appendingPathComponent(".gitignore") }
    private var gitattributesURL: URL { sidecarRoot.appendingPathComponent(".gitattributes") }

    // MARK: session.json

    /// Load `session.json`. Returns `nil` on missing / oversize / corrupt /
    /// schema-too-new (mirrors `ReviewStore.load`'s forward-compat refusal).
    public func loadSession() -> SidecarSession? {
        guard let s = JSONFileStore.read(
            SidecarSession.self, from: sessionURL, maxSize: Self.maxFileSize
        ) else { return nil }
        guard s.schemaVersion <= SidecarSession.currentSchema else { return nil }
        return s
    }

    @discardableResult
    public func saveSession(_ session: SidecarSession) -> Bool {
        JSONFileStore.write(session, to: sessionURL)
    }

    // MARK: config.json

    /// Load `config.json`, defaulting to `SidecarConfig()` (tracked, no
    /// audit) when the file is missing — so a fresh repo behaves as the
    /// recommended default without forcing the caller to write config first.
    /// A corrupt / schema-too-new file also falls back to the default.
    public func loadConfig() -> SidecarConfig {
        guard let c = JSONFileStore.read(
            SidecarConfig.self, from: configURL, maxSize: Self.maxFileSize
        ), c.schemaVersion <= SidecarConfig.currentSchema else {
            return SidecarConfig()
        }
        return c
    }

    @discardableResult
    public func saveConfig(_ config: SidecarConfig) -> Bool {
        JSONFileStore.write(config, to: configURL)
    }

    // MARK: git-tracking files (§1.3)

    /// `.gitignore` body for the TRACKED default — reviews are committed,
    /// but the derived/transient bits are always excluded.
    public static let trackedGitignore = """
    # TextView sidecar — reviews are committed by default (see config.json).
    # These entries are always excluded regardless of the tracked choice:
    reviews/audit/
    session.json
    """

    /// `.gitignore` body for the IGNORED opt-out — ignore everything but
    /// keep the ignore rule itself visible in git so the choice is auditable.
    public static let ignoredGitignore = """
    # TextView sidecar — reviews NOT tracked in git (config.json tracked=false).
    # Ignore everything in this sidecar…
    *
    # …except the ignore rule itself, so the choice is visible in git.
    !.gitignore
    """

    /// `.gitattributes` body written when tracked — normalize JSON line
    /// endings so the snapshot files don't churn across machines.
    public static let trackedGitattributes = """
    # Normalize review JSON so it doesn't churn on CRLF/LF flips.
    reviews/*.json text eol=lf
    """

    /// Write the `.gitignore` (and, when tracked, `.gitattributes`) that
    /// match `config.tracked`. Idempotent and best-effort — overwriting the
    /// app-owned tracking files is intentional (they're derived from config,
    /// not user-authored). Safe to call on every sidecar open.
    @discardableResult
    public func writeGitTrackingFiles(for config: SidecarConfig) -> Bool {
        try? FileManager.default.createDirectory(
            at: sidecarRoot, withIntermediateDirectories: true
        )
        let body = config.tracked ? Self.trackedGitignore : Self.ignoredGitignore
        let ignoreOK = writeText(body, to: gitignoreURL)
        // `.gitattributes` only matters when files are tracked.
        if config.tracked {
            return writeText(Self.trackedGitattributes, to: gitattributesURL) && ignoreOK
        }
        return ignoreOK
    }

    private func writeText(_ text: String, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Ensure a trailing newline (POSIX text file convention; keeps git
        // from flagging "no newline at end of file").
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        do {
            try payload.data(using: .utf8)!.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
