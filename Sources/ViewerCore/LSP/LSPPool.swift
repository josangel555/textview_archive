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
        /// Per-file LSP version counter. Bumped on every
        /// `didChange` so sourcekit-lsp can detect out-of-order
        /// notifications. Starts at 1 on `didOpen`.
        var fileVersions: [URL: Int] = [:]
        /// PERF-01: per-file content hash of the text last shipped to
        /// the server (via `didOpen` / `didChange`). Lets `didChange`
        /// skip the notification + version bump when the text is
        /// byte-identical to what the server already has — the common
        /// case on a tab switch, where the outline re-runs
        /// `ensureOpened` + `didChange` with the same unchanged buffer.
        /// Re-shipping the full document text on every focus change is
        /// pure waste (and re-triggers a server re-parse).
        var fileHashes: [URL: Int] = [:]
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

    // Public so callers (DocumentModel command guards) consult the SAME
    // registry this pool routes with — not LSPLanguageRegistry.default —
    // which is what makes the fake-server e2e injectable (TSK-627).
    // Immutable Sendable: synchronously readable cross-actor.
    public nonisolated let registry: LSPLanguageRegistry
    private let config: Config
    private let clock = ContinuousClock()
    private var entries: [Key: Entry] = [:]
    private var reaperTask: Task<Void, Never>?
    private var isClosed = false

    /// Per-pool callback for server-pushed publishDiagnostics events.
    /// Wired by the app once at startup; LSPClient instances spawned
    /// hereafter inherit it via `setOnDiagnostics`. Optional — running
    /// the pool without a diagnostics sink is fine (notifications
    /// drop on the floor).
    private var onDiagnostics: (@Sendable (URL, [LSPDiagnostic]) -> Void)?

    /// Install the diagnostics callback. Applies to all future-spawned
    /// clients; doesn't retroactively rewire already-live ones. (In
    /// practice the app wires this once at startup before any clients
    /// spawn — sequence isn't a problem.)
    public func setOnDiagnostics(
        _ handler: @escaping @Sendable (URL, [LSPDiagnostic]) -> Void
    ) {
        self.onDiagnostics = handler
    }

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
    /// spawns. Idempotent. Awaitable: each live client's `shutdown()` is
    /// invoked CONCURRENTLY (via a `TaskGroup`), so total teardown time is
    /// ≈ the slowest single shutdown rather than their sum. This matters
    /// at app-quit: `LSPClient.shutdown()` costs up to ~2.4s (2s request
    /// timeout + grace + SIGTERM poll), and a sequential loop over N live
    /// servers blew past the bounded quit deadline once N≥2, reparenting
    /// the un-shut clients to launchd (the leak TSK-485 fixes).
    ///
    /// `isClosed` is latched first so any `ensureLive` that wakes up
    /// mid-teardown bails (`client(for:)` guards on it). Because each
    /// `await shutdown()` is a suspension point, a spawn that was
    /// already past the `isClosed` guard could still install a fresh
    /// `.live` entry while we're iterating. We therefore drain in a
    /// loop until no live client remains, rather than a single pass —
    /// otherwise that late entry would leak its subprocess (RC-1 deinit
    /// is the backstop, but we want a clean reap here).
    public func closeAll() async {
        isClosed = true
        reaperTask?.cancel()
        reaperTask = nil
        while true {
            var live: [(Key, LSPClient)] = []
            for (key, entry) in entries {
                if case .live(let client, _) = entry.state {
                    live.append((key, client))
                }
            }
            if live.isEmpty { break }
            // Shut the live clients down CONCURRENTLY. Each child task only
            // touches its own `client` (an actor → Sendable) and returns its
            // `Key` (Sendable); the actor-isolated parent loop is the sole
            // mutator of `entries`, so there's no shared-state race. The
            // outer `while` still re-scans for any entry that went `.live`
            // after the `isClosed` latch (a spawn past the guard), so this
            // pass plus the loop keeps the no-leak drain guarantee.
            await withTaskGroup(of: Key.self) { group in
                for (key, client) in live {
                    group.addTask {
                        await client.shutdown()
                        return key
                    }
                }
                for await key in group {
                    entries.removeValue(forKey: key)
                }
            }
        }
        // Drop any residual non-live entries (cold/starting/dead) — no
        // client to shut down, but we don't want stale state lingering.
        entries.removeAll()
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
        guard case .live(_, let opened) = entries[key]?.state else { return }
        if opened.contains(fileURL) { return }
        try await client.didOpen(
            url: fileURL,
            languageId: entry.language.languageID(for: fileURL),
            text: text)
        // CONC-007: re-read the entry AFTER the `didOpen` await and apply
        // a *minimal in-place* mutation. The prior code snapshotted the
        // whole `Entry` before the await and wrote it back wholesale,
        // clobbering any concurrent change (another file's didChange
        // version bump, a recordRequest status update, or a crash demote
        // that happened while we were suspended). Re-reading the fresh
        // entry and only touching the fields we own avoids the lost
        // update. If the entry vanished or is no longer live (reaped /
        // crashed mid-await), we drop the bookkeeping — the next acquire
        // will respawn and re-open.
        guard var fresh = entries[key],
              case .live(let liveClient, var freshOpened) = fresh.state,
              liveClient === client else { return }
        freshOpened.insert(fileURL)
        fresh.state = .live(liveClient, openedFiles: freshOpened)
        fresh.lastUsed = clock.now
        fresh.fileVersions[fileURL] = 1
        // PERF-01: record the hash of the text we just `didOpen`ed so a
        // following `didChange` with the same text is a no-op.
        fresh.fileHashes[fileURL] = Self.contentHash(text)
        entries[key] = fresh
    }

    /// Notify the server that `fileURL`'s on-disk content changed.
    /// Caller is the file watcher / reload path. No-op when the file
    /// isn't currently open (`ensureOpened` hasn't been called yet)
    /// or when the language has no LSP. Bumps the per-file version
    /// counter so out-of-order notifications are detectable.
    public func didChange(fileURL: URL, text: String) async throws {
        guard let entry = registry.language(for: fileURL) else { return }
        guard let root = entry.rootFinder(fileURL) else { return }
        let key = Key(language: entry.language, workspaceRoot: root)
        guard let e = entries[key],
              case .live(let client, let opened) = e.state,
              opened.contains(fileURL) else { return }
        // PERF-01: skip the notification entirely when the text is
        // byte-identical to what the server already has. This is the
        // hot path on tab switches — the outline re-runs ensureOpened +
        // didChange with the same unchanged buffer, and re-shipping the
        // full document forces a needless server re-parse on every focus
        // change. A 64-bit content hash makes the gate O(text length)
        // once (cheaper than the JSON-encode + write + server parse it
        // avoids); a collision would only cause a missed update, which
        // for a read-only viewer is benign (next real edit re-syncs).
        let newHash = Self.contentHash(text)
        if e.fileHashes[fileURL] == newHash { return }
        let nextVersion = (e.fileVersions[fileURL] ?? 1) + 1
        try await client.didChange(
            url: fileURL,
            text: text,
            version: nextVersion
        )
        // CONC-007: re-read after the `didChange` await and commit the
        // version bump against the FRESH entry, not the pre-await
        // snapshot. The old code wrote back the stale whole-`Entry` copy,
        // silently reverting any concurrent mutation (e.g. a parallel
        // didChange to another file, or recordRequest). We also guard
        // monotonicity: if a concurrent didChange already advanced the
        // counter past `nextVersion`, keep the higher value so the
        // server never sees a version go backwards.
        guard var fresh = entries[key],
              case .live(let liveClient, _) = fresh.state,
              liveClient === client else { return }
        let committed = max(nextVersion, fresh.fileVersions[fileURL] ?? 0)
        fresh.fileVersions[fileURL] = committed
        fresh.fileHashes[fileURL] = newHash
        fresh.lastUsed = clock.now
        entries[key] = fresh
    }

    /// Notify the server that `fileURL` was just saved to disk (caller is the
    /// editor-save success path). No-op when the file isn't currently open
    /// (`ensureOpened` hasn't run) or the language has no LSP — same guards as
    /// `didChange`, minus the version/hash bookkeeping (a save carries no new
    /// content version; the server already has the latest via `didChange`).
    /// Unblocks on-save server behaviour (format/lint/index-on-save).
    public func didSave(fileURL: URL, text: String? = nil) async throws {
        guard let entry = registry.language(for: fileURL) else { return }
        guard let root = entry.rootFinder(fileURL) else { return }
        let key = Key(language: entry.language, workspaceRoot: root)
        guard let e = entries[key],
              case .live(let client, let opened) = e.state,
              opened.contains(fileURL) else { return }
        try await client.didSave(url: fileURL, text: text)
    }

    /// Forget all per-file state the pool tracks for `fileURL`: removes
    /// it from the live entry's `openedFiles` set and prunes the
    /// `fileVersions` / `fileHashes` dictionaries. Idempotent and a
    /// no-op when the file isn't tracked, the language has no LSP, or no
    /// live entry exists.
    ///
    /// S3/leak: without this, `openedFiles` / `fileVersions` /
    /// `fileHashes` grow unbounded for the life of a warm pool entry —
    /// every distinct file ever opened in a workspace leaks three map
    /// entries, since `ensureOpened` only inserts and `didChange` only
    /// updates. Callers wire this into the tab-close path, guarded by the
    /// existing "no surviving tab uses this URL" check, so a file shared
    /// by multiple tabs isn't forgotten while still displayed.
    ///
    /// We deliberately do NOT send `textDocument/didClose` to the server:
    /// `LSPClient` exposes no `didClose`, and the viewer's open/close
    /// lifecycle is decoupled from tab visibility (`DocumentModel`'s
    /// tab-close path intentionally avoids `didClose` to keep the
    /// server's view of the document in sync with the buffer it last
    /// saw). The accepted trade-off is a bounded server-side document
    /// leak (reclaimed on idle-reap / server restart / app teardown)
    /// while the Swift-side maps — the unbounded-growth hazard this
    /// addresses — are pruned promptly. A subsequent `ensureOpened`
    /// re-`didOpen`s the file and re-seeds version 1, so re-opening a
    /// previously-closed file is correct.
    public func closeFile(fileURL: URL) {
        guard let entry = registry.language(for: fileURL) else { return }
        guard let root = entry.rootFinder(fileURL) else { return }
        let key = Key(language: entry.language, workspaceRoot: root)
        guard var e = entries[key] else { return }
        var mutated = false
        if e.fileVersions.removeValue(forKey: fileURL) != nil { mutated = true }
        if e.fileHashes.removeValue(forKey: fileURL) != nil { mutated = true }
        if case .live(let client, var opened) = e.state,
           opened.remove(fileURL) != nil {
            e.state = .live(client, openedFiles: opened)
            mutated = true
        }
        guard mutated else { return }
        // Don't touch `lastUsed`: forgetting a file is bookkeeping, not
        // server traffic — it must not keep an otherwise-idle entry alive
        // past the reaper cutoff.
        entries[key] = e
    }

    /// Stable 64-bit content hash for the PERF-01 didChange gate. We use
    /// the UTF-8 bytes through `Hasher` rather than `String.hashValue`
    /// because the latter is seeded per-process-run (randomized) — fine
    /// within a single run, but using the byte-level hash keeps the
    /// gate's behavior obvious and avoids any surprise if the value ever
    /// escapes the process. Collisions only risk a missed sync, benign
    /// for a read-only viewer.
    private static func contentHash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
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
            if let onDiag = onDiagnostics {
                await client.setOnDiagnostics(onDiag)
            }
            // CONC-002: wire the crash callback so an EOF/framing failure
            // *between requests* (no in-flight call to carry the error
            // back through the routed-request catch) still demotes the
            // entry. Without this, `setOnCrash` was dead code: a server
            // that died idle would keep its stale `.live` entry until the
            // next request happened to fail. We hop back onto the actor
            // via a Task (the callback is @Sendable, fired from the
            // reader thread's failAllPending). `recordCrash` also shuts
            // down the now-dead client (RC-3).
            await client.setOnCrash { [weak self] err in
                Task { await self?.recordCrash(key: key, error: "\(err)") }
            }
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

    /// Test-only: current per-file LSP version for `fileURL`, or nil if
    /// the file isn't tracked. Lets PERF-01 tests assert that an
    /// unchanged-text `didChange` does NOT bump the version while a
    /// real edit does. Not part of the production surface.
    func _testFileVersion(for fileURL: URL) -> Int? {
        guard let entry = registry.language(for: fileURL),
              let root = entry.rootFinder(fileURL) else { return nil }
        let key = Key(language: entry.language, workspaceRoot: root)
        return entries[key]?.fileVersions[fileURL]
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

    // MARK: - Timed request wrappers

    // Pool-routed request entry points. Callers that previously did
    //   let client = try await pool.client(for: url)
    //   let result = try await client.foo(...)
    // should switch to `try await pool.foo(fileURL: url, ...)` so the
    // diagnostics panel reflects live request counts and timings. The
    // legacy `client(for:)` accessor is preserved for tests + code
    // paths that need direct client access (e.g. shutdown).

    public func documentSymbol(
        fileURL: URL, token: LSPCancellationToken? = nil
    ) async throws -> [LSPDocumentSymbol] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.documentSymbol(url: fileURL, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    /// `textDocument/rename` (TSK-640) routed through the pool —
    /// per-file uri → edits; apply via LSPTextEditApplier.
    public func rename(
        fileURL: URL, line: Int, character: Int, newName: String,
        token: LSPCancellationToken? = nil
    ) async throws -> [String: [LSPTextEdit]] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.rename(
                url: fileURL, line: line, character: character,
                newName: newName, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    /// `textDocument/codeAction` (TSK-640) routed through the pool.
    public func codeActions(
        fileURL: URL, range: LSPRange,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPCodeAction] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.codeActions(
                url: fileURL, range: range, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    public func hover(
        fileURL: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> LSPHover? {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.hover(
                url: fileURL, line: line, character: character, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    public func definition(
        fileURL: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.definition(
                url: fileURL, line: line, character: character, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    /// `textDocument/completion` (TSK-463) routed through the pool so the
    /// diagnostics panel reflects the request count + timing like the
    /// other capability methods.
    public func completion(
        fileURL: URL, line: Int, character: Int,
        triggerCharacter: String? = nil,
        token: LSPCancellationToken? = nil
    ) async throws -> LSPCompletionList {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.completion(
                url: fileURL, line: line, character: character,
                triggerCharacter: triggerCharacter, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    public func references(
        fileURL: URL, line: Int, character: Int,
        includeDeclaration: Bool = true,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.references(
                url: fileURL, line: line, character: character,
                includeDeclaration: includeDeclaration, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    public func declaration(
        fileURL: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.declaration(
                url: fileURL, line: line, character: character, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    public func typeDefinition(
        fileURL: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.typeDefinition(
                url: fileURL, line: line, character: character, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    public func implementation(
        fileURL: URL, line: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.implementation(
                url: fileURL, line: line, character: character, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    /// `textDocument/formatting` (TSK-627) — routed like every other
    /// per-file request: spins up / reuses the workspace's server.
    public func formatting(
        fileURL: URL, options: LSPFormattingOptions = LSPFormattingOptions(),
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPTextEdit] {
        let (client, key) = try await routedClient(for: fileURL)
        let start = clock.now
        do {
            let result = try await client.formatting(
                url: fileURL, options: options, token: token)
            recordRequest(key: key, millis: millisElapsed(since: start))
            return result
        } catch {
            recordCrash(key: key, error: "\(error)")
            throw error
        }
    }

    /// `workspace/symbol` across all live clients. Each call fans out
    /// to every currently-live client, merges + dedupes by
    /// `(uri, range.start)`, and sorts by name. Empty when no live
    /// clients (caller should provoke one by opening a file first).
    public func workspaceSymbol(
        query: String, token: LSPCancellationToken? = nil
    ) async throws -> [LSPWorkspaceSymbol] {
        // Snapshot the live clients so the fan-out doesn't see entries
        // mutate mid-iteration.
        var liveKeys: [(Key, LSPClient)] = []
        for (key, entry) in entries {
            if case .live(let client, _) = entry.state {
                liveKeys.append((key, client))
            }
        }
        guard !liveKeys.isEmpty else { return [] }
        // Sequential — most workspaces have ≤2 servers live; the
        // complexity of a TaskGroup + Sendable token sharing is not
        // worth the latency win at this scale.
        var merged: [LSPWorkspaceSymbol] = []
        var seen = Set<String>()
        for (key, client) in liveKeys {
            // CONC-003: an `LSPCancellationToken` binds to a single
            // (id, owner) — sharing the caller's `token` across N
            // clients would only ever cancel the FIRST client's request.
            // Instead we (a) mint a fresh per-client token so each
            // request is independently bindable/cancellable, and (b)
            // check structured-concurrency cancellation between clients
            // so a cancelled enclosing Task stops the fan-out promptly.
            // If the caller pre-cancelled their shared token, mirror that
            // onto the per-client token before issuing the request.
            try Task.checkCancellation()
            let childToken: LSPCancellationToken? = (token != nil)
                ? LSPCancellationToken() : nil
            if token?.isCancelled == true { childToken?.cancel() }
            let start = clock.now
            do {
                let result = try await client.workspaceSymbol(
                    query: query, token: childToken)
                recordRequest(key: key, millis: millisElapsed(since: start))
                for sym in result {
                    let dedupeKey = "\(sym.location.uri)#\(sym.location.range.start.line):\(sym.location.range.start.character)"
                    if seen.insert(dedupeKey).inserted {
                        merged.append(sym)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Per-client failures don't fail the whole fan-out —
                // partial results are still useful. Record + continue.
                recordCrash(key: key, error: "\(error)")
            }
        }
        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func routedClient(for fileURL: URL) async throws -> (LSPClient, Key) {
        guard let entry = registry.language(for: fileURL),
              let root = entry.rootFinder(fileURL) else {
            throw LSPError.serverBinaryNotFound(
                "no LSP route for \(fileURL.path)")
        }
        let key = Key(language: entry.language, workspaceRoot: root)
        let client = try await ensureLive(key: key, registry: entry)
        return (client, key)
    }

    private func millisElapsed(since start: ContinuousClock.Instant) -> Double {
        let delta = clock.now - start
        // Duration → milliseconds. components.seconds + attoseconds/1e15.
        let secs = Double(delta.components.seconds)
        let attos = Double(delta.components.attoseconds)
        return secs * 1000 + attos / 1e15
    }

    /// Mark a key as crashed; bumps the counter and demotes to cold so
    /// the next acquire respawns with the backoff policy.
    ///
    /// RC-3: if the entry was `.live`, the prior client is now defunct
    /// (the crash callback fires from the reader thread's
    /// `failAllPending`, or a routed request threw). We must reclaim it
    /// — `terminate()` + reap the subprocess and close fds — before we
    /// drop the reference, otherwise the demoted-but-not-shutdown client
    /// leaks until its `deinit` (RC-1) eventually runs. We fire the
    /// `shutdown()` on a detached task so demotion stays synchronous and
    /// we don't serialize the pool actor behind a teardown handshake.
    func recordCrash(key: Key, error: String) {
        guard var e = entries[key] else { return }
        let priorClient: LSPClient?
        if case .live(let client, _) = e.state {
            priorClient = client
        } else {
            priorClient = nil
        }
        e.serverStatus.crashCount += 1
        e.serverStatus.lastError = error
        e.state = .cold
        entries[key] = e
        if let priorClient {
            Task.detached { await priorClient.shutdown() }
        }
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
