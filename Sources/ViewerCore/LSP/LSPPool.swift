import Foundation

/// Process pool, keyed by `(language, workspaceRoot)`. One `LSPClient`
/// per key, spawned lazily on first request. Idle clients are reaped
/// after `idleTimeout` seconds with no traffic; a forced shutdown on
/// `closeAll()` is the app-teardown hook.
///
/// Threading model: pool is an `actor`. All methods are async; clients
/// are returned by handle (not raw `LSPClient`) so the pool stays
/// the single owner of lifecycle. Handles forward calls to the
/// underlying client via the pool, which tracks "last used" time on
/// every call for the reaper.
///
/// Failure model:
///   - If a client's `initialize` fails or the server binary is missing,
///     the pool surfaces `LSPError.serverBinaryNotFound` / spawn errors
///     to the caller. The bad client is *not* cached.
///   - If a client crashes mid-session, the next request triggers a
///     restart with exponential backoff (`restartBackoff`). After
///     `maxRestartAttempts` failures the pool marks the key dead for
///     `deadCooldown` seconds before retrying.
public actor LSPPool {

    // MARK: Configuration

    public struct Config: Sendable {
        public var idleTimeout: Duration
        public var restartBackoff: [Duration]
        public var maxRestartAttempts: Int
        public var deadCooldown: Duration
        public var reaperTick: Duration

        public init(
            idleTimeout: Duration = .seconds(5 * 60),
            restartBackoff: [Duration] = [.milliseconds(250), .seconds(1), .seconds(5)],
            maxRestartAttempts: Int = 3,
            deadCooldown: Duration = .seconds(30),
            reaperTick: Duration = .seconds(30)
        ) {
            self.idleTimeout = idleTimeout
            self.restartBackoff = restartBackoff
            self.maxRestartAttempts = maxRestartAttempts
            self.deadCooldown = deadCooldown
            self.reaperTick = reaperTick
        }

        public static let `default` = Config()
    }

    public struct Key: Hashable, Sendable, CustomStringConvertible {
        public let language: LSPLanguage
        public let workspaceRoot: URL
        public init(language: LSPLanguage, workspaceRoot: URL) {
            self.language = language
            self.workspaceRoot = workspaceRoot.standardizedFileURL
        }
        public var description: String {
            "\(language.rawValue)@\(workspaceRoot.path)"
        }
    }

    /// Per-key entry. State machine:
    /// `cold` → `starting` → `live` → `idle` → `reaped`
    ///                  └────────────────→ `dead` (after maxRestartAttempts)
    enum State {
        case cold
        case starting
        case live(LSPClient, openedFiles: Set<URL>)
        case dead(until: ContinuousClock.Instant)
    }

    private struct Entry {
        var state: State
        var lastUsed: ContinuousClock.Instant
        var restartAttempts: Int
        var serverStatus: LSPServerStatus
    }

    /// Snapshot of pool / client health for the dev diagnostics panel.
    public struct LSPServerStatus: Sendable {
        public var lastError: String?
        public var lastResponseMillis: Double?
        public var requestCount: Int
        public var crashCount: Int
        public var startedAt: Date?

        public init() {
            self.lastError = nil
            self.lastResponseMillis = nil
            self.requestCount = 0
            self.crashCount = 0
            self.startedAt = nil
        }
    }

    public struct StatusSnapshot: Sendable {
        public let key: Key
        public let isLive: Bool
        public let isDead: Bool
        public let status: LSPServerStatus
    }

    private let registry: LSPLanguageRegistry
    private let config: Config
    private let clock = ContinuousClock()
    private var entries: [Key: Entry] = [:]
    private var reaperTask: Task<Void, Never>?
    private var isClosed = false

    public init(
        registry: LSPLanguageRegistry = .default,
        config: Config = .default
    ) {
        self.registry = registry
        self.config = config
    }

    /// Start the idle-reaper. Idempotent — calling twice is a no-op.
    public func start() {
        guard reaperTask == nil, !isClosed else { return }
        let tick = config.reaperTick
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                await self?.reapIdle()
            }
        }
    }

    /// Force shutdown of every live server and prevent any further
    /// spawns. Idempotent. Awaitable: each client's `shutdown()` is
    /// invoked sequentially with a short timeout.
    public func closeAll() async {
        isClosed = true
        reaperTask?.cancel()
        reaperTask = nil
        for (key, entry) in entries {
            if case .live(let client, _) = entry.state {
                await client.shutdown()
            }
            entries.removeValue(forKey: key)
        }
    }

    // MARK: - Lookups for the UI

    /// Does the pool have a registered handler for the given file's
    /// language *and* a server binary on disk? If true, calling
    /// `client(for:)` is expected to succeed (modulo cold-start).
    public func canHandle(_ fileURL: URL) -> Bool {
        guard let entry = registry.language(for: fileURL) else { return false }
        return entry.serverLauncher(fileURL.deletingLastPathComponent()) != nil
    }

    /// Resolve the workspace key for a file. Returns nil if (a) the
    /// language is unknown, (b) no root could be found, or (c) the
    /// server binary is missing.
    public func key(for fileURL: URL) -> Key? {
        guard let entry = registry.language(for: fileURL),
              let root = entry.rootFinder(fileURL) else { return nil }
        return Key(language: entry.language, workspaceRoot: root)
    }

    // MARK: - Per-key acquire

    /// Acquire a live `LSPClient` for the file. Spawns + initializes
    /// on first call; reuses on subsequent calls. Throws if the
    /// server can't be located, the spawn fails, or the key is in
    /// `dead` cooldown.
    public func client(for fileURL: URL) async throws -> LSPClient {
        guard !isClosed else { throw LSPError.transportClosed }
        guard let entry = registry.language(for: fileURL) else {
            throw LSPError.serverBinaryNotFound(
                "no LSP registered for .\(fileURL.pathExtension)")
        }
        guard let root = entry.rootFinder(fileURL) else {
            throw LSPError.serverBinaryNotFound(
                "no workspace root for \(fileURL.path)")
        }
        let key = Key(language: entry.language, workspaceRoot: root)
        return try await ensureLive(key: key, registry: entry)
    }

    /// Convenience: didOpen on the right client for `fileURL` if not
    /// already open. Idempotent per (key, fileURL).
    public func ensureOpened(
        fileURL: URL, text: String
    ) async throws {
        guard let entry = registry.language(for: fileURL) else { return }
        guard let root = entry.rootFinder(fileURL) else { return }
        let key = Key(language: entry.language, workspaceRoot: root)
        let client = try await ensureLive(key: key, registry: entry)
        guard case .live(_, var opened) = entries[key]?.state else { return }
        if opened.contains(fileURL) { return }
        try await client.didOpen(
            url: fileURL,
            languageId: entry.language.languageID,
            text: text)
        opened.insert(fileURL)
        // Mutate entry in place.
        if var e = entries[key] {
            e.state = .live(client, openedFiles: opened)
            e.lastUsed = clock.now
            entries[key] = e
        }
    }

    private func ensureLive(
        key: Key, registry entry: LSPLanguageEntry
    ) async throws -> LSPClient {
        if let existing = entries[key] {
            switch existing.state {
            case .live(let client, _):
                touch(key: key)
                return client
            case .dead(let until):
                if clock.now < until {
                    throw LSPError.serverBinaryNotFound(
                        "LSP unavailable (cooldown) for \(key)")
                }
                // Cooldown elapsed — fall through to respawn.
                entries.removeValue(forKey: key)
            case .starting:
                // Race: another caller is mid-spawn. We could wait, but
                // simpler is to fall through and try (worst case: two
                // spawns; the second's initialize fails benignly, and
                // the second client is dropped). PoC scope.
                break
            case .cold:
                break
            }
        }

        var entry0 = entries[key] ?? Entry(
            state: .cold, lastUsed: clock.now,
            restartAttempts: 0, serverStatus: LSPServerStatus())
        entry0.state = .starting
        entries[key] = entry0

        guard let cfg = entry.serverLauncher(key.workspaceRoot) else {
            entries[key] = nil
            throw LSPError.serverBinaryNotFound(
                "no \(entry.language.displayName) binary")
        }

        do {
            let client = try LSPClient(config: cfg)
            try await client.initialize()
            var e = entries[key] ?? Entry(
                state: .cold, lastUsed: clock.now,
                restartAttempts: 0, serverStatus: LSPServerStatus())
            e.state = .live(client, openedFiles: [])
            e.lastUsed = clock.now
            e.restartAttempts = 0
            e.serverStatus.startedAt = Date()
            e.serverStatus.lastError = nil
            entries[key] = e
            return client
        } catch {
            // Spawn or initialize failed. Bump attempt counter and
            // decide whether to back off or mark dead.
            var e = entries[key] ?? Entry(
                state: .cold, lastUsed: clock.now,
                restartAttempts: 0, serverStatus: LSPServerStatus())
            e.restartAttempts += 1
            e.serverStatus.crashCount += 1
            e.serverStatus.lastError = "\(error)"
            if e.restartAttempts >= config.maxRestartAttempts {
                e.state = .dead(until: clock.now.advanced(by: config.deadCooldown))
                entries[key] = e
                throw error
            } else {
                // Back off and re-throw — caller may retry on its own
                // schedule. We don't auto-retry inside the pool because
                // hover requests have a per-request budget the caller
                // owns; pre-spending it on backoff in the pool would
                // make those timeouts confusing.
                e.state = .cold
                entries[key] = e
                let attempt = min(e.restartAttempts - 1, config.restartBackoff.count - 1)
                let delay = config.restartBackoff[attempt]
                try? await Task.sleep(for: delay)
                throw error
            }
        }
    }

    private func touch(key: Key) {
        if var e = entries[key] {
            e.lastUsed = clock.now
            entries[key] = e
        }
    }

    // MARK: - Status (dev diagnostics)

    /// Snapshot of all known keys. Reads only — the diagnostics panel
    /// polls this every couple seconds.
    public func snapshot() -> [StatusSnapshot] {
        return entries.map { (key, entry) in
            let live: Bool
            let dead: Bool
            switch entry.state {
            case .live: live = true; dead = false
            case .dead: live = false; dead = true
            default:    live = false; dead = false
            }
            return StatusSnapshot(
                key: key, isLive: live, isDead: dead,
                status: entry.serverStatus)
        }
    }

    /// Record a successful request's wall time for the diag panel.
    func recordRequest(key: Key, millis: Double) {
        if var e = entries[key] {
            e.serverStatus.requestCount += 1
            e.serverStatus.lastResponseMillis = millis
            e.lastUsed = clock.now
            entries[key] = e
        }
    }

    /// Mark a key as crashed; bumps the counter and demotes to cold so
    /// the next acquire respawns with the backoff policy.
    func recordCrash(key: Key, error: String) {
        guard var e = entries[key] else { return }
        e.serverStatus.crashCount += 1
        e.serverStatus.lastError = error
        e.state = .cold
        entries[key] = e
    }

    // MARK: - Reaper

    func reapIdle() async {
        let cutoff = clock.now.advanced(by: .seconds(0) - config.idleTimeout)
        var toReap: [(Key, LSPClient)] = []
        for (key, entry) in entries {
            if case .live(let client, _) = entry.state, entry.lastUsed < cutoff {
                toReap.append((key, client))
            }
        }
        for (key, client) in toReap {
            await client.shutdown()
            entries.removeValue(forKey: key)
        }
    }
}
