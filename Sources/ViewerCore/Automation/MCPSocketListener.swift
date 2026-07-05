import Foundation

/// TSK-1544 — MCP into the RUNNING app.
///
/// A per-user unix-domain socket listener that serves the SAME MCP surface as
/// the `--mcp-stdio` server: each accepted connection gets its own `MCPServer`
/// instance speaking the identical Content-Length JSON-RPC framing, dispatching
/// through the same `MCPToolCatalog` against the live `AutomationHost` (the
/// GUI app's real `DocumentModel`). This is what lets a `--mcp-connect` bridge
/// (Claude Code's stdio config) drive the OPEN app — live documents, live
/// canvas co-editing — instead of spawning a second headless instance.
///
/// Security model: same-user only. The socket node lives under the app's
/// Application Support directory and is `chmod 0600`; there is no TCP, no
/// remote surface, no auth token in v1. The tool surface itself is unchanged
/// (the TSK-954 `open_path` containment fence applies exactly as on stdio).
///
/// Lifecycle: `start()` binds + listens and parks an accept loop on a
/// background thread. Each connection is served concurrently by its own
/// `MCPServer` (whose per-request main-actor bridge serialises actual model
/// access, so N connections cannot race the model). `stop()` closes the
/// listening socket (unblocking `accept`), unlinks the node, and stops every
/// live connection server.
public final class MCPSocketListener: @unchecked Sendable {

    public enum ListenerError: Error, Equatable {
        case pathTooLong(String)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    private let host: AutomationHost
    private let path: String
    private let logger: ((String) -> Void)?

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var servers: [MCPServer] = []
    private var stopped = false

    /// The canonical per-user socket path:
    /// `~/Library/Application Support/MarkdownViewer/mcp.sock` — the same
    /// no-bundle-id app-support subdir the session/bookmark stores use,
    /// resolved through `TestStateRedirect` so HOST tests bind under the
    /// per-process tmp, never the dev's real state (the TSK-1288 seam;
    /// `TestStateRedirectTests.test_noNewStoreBypassesTheRedirect` enforces).
    /// `sun_path` is capped at 104 bytes on macOS; the caller gets a loud
    /// `pathTooLong` at `start()` if a nonstandard HOME blows the budget.
    public static func defaultSocketPath() -> String {
        TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("mcp.sock").path
    }

    public init(
        host: AutomationHost,
        path: String? = nil,
        logger: ((String) -> Void)? = nil
    ) {
        self.host = host
        self.path = path ?? Self.defaultSocketPath()
        self.logger = logger
    }

    /// Bind + listen + spawn the accept loop. Any stale socket node at the
    /// path is unlinked first: the app is single-instance, so a node there is
    /// always a leftover from a crashed/killed predecessor, never a live peer.
    public func start() throws {
        guard path.utf8.count < 104 else { throw ListenerError.pathTooLong(path) }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            _ = path.utf8CString.withUnsafeBytes { src in
                memcpy(raw.baseAddress!, src.baseAddress!,
                       min(src.count, raw.count))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd); throw ListenerError.bindFailed(e)
        }
        // Same-user only: owner read/write, nothing for group/other.
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else {
            let e = errno; close(fd); unlink(path)
            throw ListenerError.listenFailed(e)
        }

        lock.lock(); listenFD = fd; stopped = false; lock.unlock()

        let t = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        t.name = "MCPSocketListener.accept"
        t.qualityOfService = .userInitiated
        lock.lock(); thread = t; lock.unlock()
        t.start()
        log("listening on \(path)")
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let live = servers
        servers = []
        lock.unlock()
        if fd >= 0 { close(fd) }   // unblocks accept(2) with EBADF/ECONNABORTED
        unlink(path)
        live.forEach { $0.stop() }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            lock.lock(); let done = stopped; lock.unlock()
            if done { if conn >= 0 { close(conn) }; return }
            guard conn >= 0 else {
                // EINTR is retryable; anything else means the listen socket
                // is gone (stop() or a fatal error) — end the loop.
                if errno == EINTR { continue }
                log("accept failed (errno \(errno)); listener exiting")
                return
            }
            serve(connection: conn)
        }
    }

    /// One `MCPServer` per connection over the connection's own FileHandle.
    /// The SAME handle serves both directions (one fd); `closeOnDealloc`
    /// guarantees the fd dies with the server even on abnormal teardown.
    /// Immutable-capture cell for the connection server so the @Sendable
    /// `onExit` can identify it without capturing a mutable local (Swift 6
    /// SendableClosureCaptures). Single write before `start()`, single read
    /// after the connection ends — ordered by the server's own lifecycle.
    private final class ServerBox: @unchecked Sendable { var server: MCPServer? }

    private func serve(connection fd: Int32) {
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let box = ServerBox()
        let server = MCPServer(
            host: host,
            input: fh,
            output: fh,
            logger: logger.map { l in { l("conn: \($0)") } },
            onExit: { [weak self] in
                // Connection ended (peer EOF / dead transport) — drop our
                // retain so the server + handle deallocate.
                guard let self, let s = box.server else { return }
                self.lock.lock()
                self.servers.removeAll { $0 === s }
                self.lock.unlock()
            }
        )
        box.server = server
        lock.lock(); servers.append(server); lock.unlock()
        server.start()
        log("connection accepted (fd \(fd))")
    }

    private func log(_ s: String) {
        Obs.shared.emit(.info, "mcp", "socket-listener: \(s)")
        logger?(s)
    }
}
