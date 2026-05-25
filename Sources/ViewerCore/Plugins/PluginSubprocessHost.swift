import Foundation

/// Tier B plugin host — spawns a plugin subprocess per request and
/// dispatches a single JSON envelope over stdin/stdout. Per design
/// §3.2, but tightened for v1:
///
///   - **One process per call.** No daemon, no warm pool. Cold start
///     is acceptable for the row volumes our sidebar shows (10s, not
///     1000s); a warm pool can come later if profiling demands it.
///   - **Env scrub: HOME only.** The full §3.2 scrubbed-env table
///     listed `TV_PLUGIN_DIR`, `TV_HOST_VERSION` etc. — v1 ships the
///     minimum that lets a plugin find `~/.cache` via `HOME` and
///     nothing else. **No** `PATH`, **no** `USER`, **no** `*_TOKEN`,
///     **no** `AWS_*`/`OPENAI_API_KEY`/etc. The plugin's `bin` is an
///     absolute path the host resolves itself; subprocesses that need
///     more env have to ship it inline (e.g. a wrapper script that
///     hard-codes a `PATH`).
///   - **5s wall-clock timeout** (hard SIGKILL on exceed).
///   - **1 MB stdout cap.** Beyond that we close the read pipe and
///     fail the call. Tier B is for "describe the current state"
///     responses, not for streaming megabytes.
///   - **Audit log: JSONL.** One line per call, at
///     `~/Library/Logs/com.markdownviewer.MarkdownViewer/plugins.log`.
///     Captures plugin id + capability + bin path + exit code +
///     duration. *Not* the stdout/stderr bytes (PII risk; the user
///     can re-run with debug to capture those).
///
/// The host is `Sendable` and contains no per-call mutable state —
/// each call holds its own `Process` + pipes locally. Safe to call
/// from concurrent contexts; serialisation (if needed) is the
/// caller's job.
public struct PluginSubprocessHost: Sendable {

    /// What the host gives the plugin on stdin. v1 envelope is
    /// deliberately small: a discriminator (`kind`), an opaque
    /// per-call id, and a free-form `args` object the plugin can
    /// read. Extending is additive — a v2 envelope will keep these
    /// fields and add more, and plugins that don't read the new
    /// fields continue to work.
    public struct RequestEnvelope: Encodable, Sendable {
        public let version: Int      // protocol version; v1 = 1
        public let kind: String       // "listRows" for the v1 sidebar
        public let invocationID: String
        public let args: [String: String]

        public init(
            kind: String,
            invocationID: String = UUID().uuidString,
            args: [String: String] = [:]
        ) {
            self.version = 1
            self.kind = kind
            self.invocationID = invocationID
            self.args = args
        }
    }

    /// What the plugin returns on stdout. v1 supports one response
    /// shape: a `rows` array of sidebar rows. Future contribution
    /// types add new top-level fields, never repurpose existing ones.
    /// Unknown fields are ignored (forward-compat).
    public struct ResponseEnvelope: Decodable, Sendable {
        public let rows: [Row]?

        public struct Row: Decodable, Sendable, Equatable {
            public let id: String
            public let label: String
            public let detail: String?
        }
    }

    /// Per-call result. Audit-log fields surface here too so the
    /// caller (and Settings → Plugins → "Show log") can render
    /// recent activity without re-reading the file.
    public struct CallResult: Sendable {
        public enum Outcome: Sendable {
            case ok(ResponseEnvelope)
            case timedOut
            case stdoutOverflow
            case nonZeroExit(Int32, stderrTail: String)
            case spawnFailed(String)
            case decodeFailed(String)
        }
        public let outcome: Outcome
        public let durationMs: Int
        public let invocationID: String
    }

    /// Where the audit log lives. Public so Settings → Plugins →
    /// "Show log" can open it directly.
    public static func auditLogURL() -> URL {
        let library = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
            .appendingPathComponent("plugins.log")
    }

    /// Hard caps. Public so tests can assert on them without poking
    /// at implementation details.
    public static let defaultTimeoutMs: Int = 5_000
    public static let maxTimeoutMs: Int = 30_000
    public static let stdoutCapBytes: Int = 1 << 20  // 1 MB
    public static let stderrTailBytes: Int = 4096

    /// Override hook for tests — when non-nil, audit entries are
    /// appended here instead of the real log URL.
    private let auditURLOverride: URL?

    public init(auditURLOverride: URL? = nil) {
        self.auditURLOverride = auditURLOverride
    }

    /// Invoke `bin` (resolved as `pluginFolder/<bin>`) with `args`,
    /// piping `request` as JSON on stdin and decoding the JSON
    /// response from stdout. Always returns a `CallResult`; never
    /// throws. Audit log written before returning regardless of
    /// outcome.
    public func call(
        pluginID: String,
        pluginFolder: URL,
        bin: String,
        args: [String],
        timeoutMs requestedTimeout: Int?,
        request: RequestEnvelope
    ) -> CallResult {
        let started = Date()
        let timeoutMs = min(requestedTimeout ?? Self.defaultTimeoutMs, Self.maxTimeoutMs)
        let executable = pluginFolder.appendingPathComponent(bin)

        // Pre-flight: bin must exist and be executable inside the
        // plugin folder. Refuse path traversal (any `..` segment).
        // The path-traversal check operates on the *manifest-supplied*
        // string, not the resolved URL, so a clever symlink can still
        // escape — that's an OS sandbox problem, out of scope for v1.
        if bin.contains("..") {
            return finish(.spawnFailed("bin path contains '..': \(bin)"),
                          pluginID: pluginID, bin: bin,
                          startedAt: started, invocationID: request.invocationID)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return finish(.spawnFailed("bin not found: \(executable.path)"),
                          pluginID: pluginID, bin: bin,
                          startedAt: started, invocationID: request.invocationID)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return finish(.spawnFailed("bin not executable: \(executable.path)"),
                          pluginID: pluginID, bin: bin,
                          startedAt: started, invocationID: request.invocationID)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = pluginFolder
        process.environment = Self.scrubbedEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Serialise the envelope once before launch — if encoding fails
        // (it shouldn't for the fixed schema) we abort without spawning.
        let envelopeData: Data
        do {
            envelopeData = try JSONEncoder().encode(request)
        } catch {
            return finish(.spawnFailed("envelope encode: \(error)"),
                          pluginID: pluginID, bin: bin,
                          startedAt: started, invocationID: request.invocationID)
        }

        do {
            try process.run()
        } catch {
            return finish(.spawnFailed("\(error)"),
                          pluginID: pluginID, bin: bin,
                          startedAt: started, invocationID: request.invocationID)
        }

        // Write stdin off-thread. Plugins are expected to consume the
        // whole envelope, so a blocking write would deadlock if the
        // plugin doesn't drain. We close on completion to signal EOF.
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: envelopeData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Drain stdout off-thread with a cap. Once the cap is hit we
        // close the handle, which yields a SIGPIPE to the child on its
        // next write; the wait loop below will see the process die.
        let stdoutBuffer = LockedBuffer()
        let stderrBuffer = LockedBuffer()
        let stdoutOverflow = LockedFlag()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stdoutDone.signal() }
            while true {
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty { return }
                let overflowed = stdoutBuffer.append(chunk, cap: Self.stdoutCapBytes)
                if overflowed {
                    stdoutOverflow.set()
                    try? stdoutHandle.close()
                    return
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stderrDone.signal() }
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { return }
                _ = stderrBuffer.append(chunk, cap: Self.stderrTailBytes * 8)
            }
        }

        // Wait with timeout. We poll `process.isRunning` instead of
        // `process.waitUntilExit()` because the latter has no built-in
        // timeout and blocks forever on a stuck child.
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var didTimeOut = false
        while process.isRunning {
            if Date() >= deadline {
                didTimeOut = true
                process.terminate()
                // Give it 200ms to handle SIGTERM cleanly, then SIGKILL.
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()

        // Make sure the reader threads drain whatever's left in the
        // pipes before we read the buffers. With the process exited
        // the handles will hit EOF and the threads will signal.
        _ = stdoutDone.wait(timeout: .now() + .milliseconds(500))
        _ = stderrDone.wait(timeout: .now() + .milliseconds(500))

        let outcome: CallResult.Outcome
        if didTimeOut {
            outcome = .timedOut
        } else if stdoutOverflow.isSet() {
            outcome = .stdoutOverflow
        } else if process.terminationStatus != 0 {
            let tail = stderrBuffer.tailString(maxBytes: Self.stderrTailBytes)
            outcome = .nonZeroExit(process.terminationStatus, stderrTail: tail)
        } else {
            do {
                let resp = try JSONDecoder().decode(
                    ResponseEnvelope.self, from: stdoutBuffer.data()
                )
                outcome = .ok(resp)
            } catch {
                outcome = .decodeFailed("\(error)")
            }
        }
        return finish(outcome,
                      pluginID: pluginID, bin: bin,
                      startedAt: started, invocationID: request.invocationID)
    }

    // MARK: - Env scrub

    /// v1 scrub: pass through `HOME` only. Everything else is
    /// dropped. This is intentionally stricter than the design's
    /// table (which also passes `PATH`, `LANG`, etc.) — v1 errs on
    /// the side of paranoia. We expand the allowlist when a real
    /// plugin proves it can't function without a specific var; we
    /// audit each addition.
    ///
    /// **Not** passed (representative): `PATH`, `USER`, `LOGNAME`,
    /// `SHELL`, `LANG`, `LC_*`, `SSH_AUTH_SOCK`, `SSH_CONNECTION`,
    /// `TMPDIR`, `XPC_*`, `AWS_*`, `OPENAI_API_KEY`, `*_TOKEN`,
    /// `*_SECRET`, `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`,
    /// `__CFBundleIdentifier`, anything else.
    static func scrubbedEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            env["HOME"] = home
        }
        return env
    }

    // MARK: - Audit log

    private func finish(
        _ outcome: CallResult.Outcome,
        pluginID: String,
        bin: String,
        startedAt: Date,
        invocationID: String
    ) -> CallResult {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        writeAudit(
            pluginID: pluginID, bin: bin, outcome: outcome,
            durationMs: durationMs, invocationID: invocationID
        )
        return CallResult(outcome: outcome, durationMs: durationMs,
                          invocationID: invocationID)
    }

    private func writeAudit(
        pluginID: String, bin: String, outcome: CallResult.Outcome,
        durationMs: Int, invocationID: String
    ) {
        let url = auditURLOverride ?? Self.auditLogURL()
        // S3.3/5.6 (2026-05-25): create the directory with owner-only
        // perms. The audit log contains plugin ids + stderr tails;
        // without 0o700 a co-resident user on a multi-user macOS
        // host can read those. Setting the perms on createDirectory
        // is the lightest fix; existing dirs (created pre-patch) are
        // chmod'd on the first write.
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Idempotent best-effort chmod: if the dir already existed
        // with looser perms (pre-patch install), tighten now.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )

        // ISO-8601 with milliseconds. Hand-rolled because
        // `ISO8601DateFormatter` doesn't do fractional seconds in any
        // option I can find that the rest of the codebase expects to
        // round-trip; here we just need a sortable timestamp.
        let ts = isoTimestamp(Date())
        var line: [String: Any] = [
            "ts": ts,
            "plugin": pluginID,
            "cap": "shell.exec",
            "bin": bin,
            "invocation": invocationID,
            "duration_ms": durationMs,
        ]
        switch outcome {
        case .ok:
            line["result"] = "ok"
        case .timedOut:
            line["result"] = "timeout"
        case .stdoutOverflow:
            line["result"] = "stdout_overflow"
        case .nonZeroExit(let code, _):
            line["result"] = "nonzero_exit"
            line["exit"] = Int(code)
        case .spawnFailed(let msg):
            line["result"] = "spawn_failed"
            line["error"] = msg
        case .decodeFailed(let msg):
            line["result"] = "decode_failed"
            line["error"] = msg
        }

        // Sorted keys so the JSONL is stable line-to-line — easier
        // to diff manually when debugging.
        guard let data = try? JSONSerialization.data(
            withJSONObject: line, options: [.sortedKeys]
        ) else { return }
        var blob = data
        blob.append(0x0A)  // '\n'

        // O_APPEND opens append-write; we write the whole line in one
        // syscall so concurrent writers from sibling Process()es don't
        // interleave bytes. Up to PIPE_BUF (4 KB on macOS) the kernel
        // guarantees atomicity for a single write to a file opened
        // with O_APPEND — our lines are <500 bytes, well inside that.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        blob.withUnsafeBytes { _ = write(fd, $0.baseAddress, blob.count) }
    }

    private func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - Tiny thread-safe helpers for pipe drain

/// `LockedBuffer` and `LockedFlag` are intentionally NOT generic
/// Sendable wrappers — they're confined to this file and used only
/// from the two reader queues `call(...)` spawns. A `DispatchQueue`-
/// targeted actor would be cleaner but adds a hop per chunk; a plain
/// NSLock around a `Data` is the smallest thing that works.
private final class LockedBuffer: @unchecked Sendable {
    private var buf = Data()
    private let lock = NSLock()
    /// Append `chunk` and return true iff appending would push the
    /// buffer past `cap` (in which case `buf` keeps only the first
    /// `cap` bytes, and the caller treats this as overflow).
    func append(_ chunk: Data, cap: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if buf.count + chunk.count <= cap {
            buf.append(chunk)
            return false
        }
        let take = max(0, cap - buf.count)
        if take > 0 { buf.append(chunk.prefix(take)) }
        return true
    }
    func data() -> Data {
        lock.lock(); defer { lock.unlock() }
        return buf
    }
    /// Returns the last `maxBytes` of buffer as a UTF-8 string,
    /// lossy-decoded. Used for the stderr tail in audit + error.
    func tailString(maxBytes: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        let slice = buf.count > maxBytes ? buf.suffix(maxBytes) : buf
        return String(data: slice, encoding: .utf8)
            ?? String(decoding: slice, as: UTF8.self)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func set() { lock.lock(); flag = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
