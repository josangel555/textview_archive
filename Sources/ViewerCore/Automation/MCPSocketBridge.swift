import Foundation

/// TSK-1544 — the client half of MCP-into-the-running-app.
///
/// `--mcp-connect` keeps Claude Code's server config a plain stdio command
/// while routing the session into the ALREADY-RUNNING app: this bridge dials
/// the app's `MCPSocketListener` socket and pumps bytes verbatim in both
/// directions (stdio ⇄ socket). It is protocol-blind on purpose — framing,
/// JSON-RPC, tool semantics all live server-side; a dumb pipe cannot drift.
///
/// When no app is listening (`connect` returns nil) the launcher falls back
/// to the in-process headless `--mcp-stdio` server, so the same client
/// config works whether or not the app is open.
public enum MCPSocketBridge {

    /// Dial a unix-domain socket. Returns a FileHandle owning the fd
    /// (`closeOnDealloc`), or nil when nothing is listening / the path is
    /// unusable — the caller's cue to fall back to the headless server.
    public static func connect(path: String) -> FileHandle? {
        guard path.utf8.count < 104 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            _ = path.utf8CString.withUnsafeBytes { src in
                memcpy(raw.baseAddress!, src.baseAddress!,
                       min(src.count, raw.count))
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); return nil }
        // A write to a dead socket must fail with EPIPE, not raise SIGPIPE
        // (the default would kill the bridge process mid-reconnect).
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }


    /// Pump bytes both ways until EITHER side reaches EOF or dies, then
    /// close both. Blocking; the one-round primitive (tests exercise it
    /// through the real listener). For the resilient client loop use
    /// `serve` below.
    public static func pump(
        localIn: FileHandle,
        localOut: FileHandle,
        remote: FileHandle
    ) {
        let group = DispatchGroup()

        // Raw POSIX read/write on the descriptors — deterministic blocking
        // semantics (FileHandle's read(upToCount:) buffering is not spec'd
        // for interleaved pipe/socket pumping). Descriptors are only
        // BORROWED here: closes go through the owning FileHandle objects,
        // which guard double-close — never `close(fd)` raw, or a recycled
        // descriptor number could be closed out from under another owner.
        func copyLoop(fromFD src: Int32, toFD dst: Int32,
                      thenClosing others: [FileHandle]) {
            group.enter()
            Thread.detachNewThread {
                defer {
                    others.forEach { try? $0.close() }
                    group.leave()
                }
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(src, &buf, buf.count)
                    if n == 0 { return }                        // EOF
                    if n < 0 { if errno == EINTR { continue }; return }
                    var off = 0
                    while off < n {
                        let w = buf.withUnsafeBytes { raw in
                            write(dst, raw.baseAddress! + off, n - off)
                        }
                        if w < 0 { if errno == EINTR { continue }; return }
                        off += w
                    }
                }
            }
        }

        // stdio → socket; on stdin EOF close the socket (server sees EOF).
        copyLoop(fromFD: localIn.fileDescriptor, toFD: remote.fileDescriptor,
                 thenClosing: [remote])
        // socket → stdout; on socket EOF close stdout (client sees EOF).
        copyLoop(fromFD: remote.fileDescriptor, toFD: localOut.fileDescriptor,
                 thenClosing: [localOut])
        group.wait()
    }

    /// TSK-1552 — the SELF-HEALING client loop: bridge stdio to the app's
    /// socket and, when the APP goes away (quit/relaunch), keep the client
    /// session alive by reconnecting with capped backoff — FOREVER, until
    /// the client closes stdin. Safe because the app-side MCP server is
    /// STATELESS (tools/list & tools/call are not gated on `initialize`),
    /// so a fresh socket serves the same session without a new handshake.
    ///
    /// While disconnected, stdin is deliberately NOT read: client requests
    /// queue in the OS pipe buffer and deliver after the reconnect — no
    /// message loss across an app restart. (A request already mid-write
    /// when the socket dies is re-sent to the next socket: the write
    /// position is tracked per message buffer.)
    ///
    /// Returns when the CLIENT closes stdin (the only terminal condition).
    public static func serve(
        localIn: FileHandle,
        localOut: FileHandle,
        socketPath: String,
        initialRemote: FileHandle,
        note: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        let state = ServeState(remote: initialRemote)

        // The single long-lived stdin reader: read a chunk, then write it
        // to WHICHEVER socket is current — waiting out reconnect gaps and
        // re-sending the unsent remainder after a socket swap.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(localIn.fileDescriptor, &buf, buf.count)
                if n == 0 { state.clientClosed(); return }
                if n < 0 { if errno == EINTR { continue }; state.clientClosed(); return }
                var off = 0
                while off < n {
                    // Hold the retained HANDLE across the write: the fd can
                    // never be closed+recycled out from under the syscall
                    // (fd-reuse hazard) — sockets close via ARC when the
                    // LAST holder releases (connect() sets closeOnDealloc).
                    guard let handle = state.waitForRemote() else { return } // client gone
                    let w = buf.withUnsafeBytes { raw in
                        write(handle.fileDescriptor, raw.baseAddress! + off, n - off)
                    }
                    if w < 0 {
                        if errno == EINTR { continue }
                        state.remoteDied(handle)      // re-send remainder to the next socket
                        continue
                    }
                    off += w
                }
            }
        }

        // The socket→stdout loop, one round per connection; reconnect between.
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let handle = state.currentRemote() else {
                if state.isClientGone() { return }
                // Reconnect with capped backoff until the app returns or the
                // client goes away. 250ms → 4s cap: fast for a relaunch,
                // cheap when the app stays closed for hours.
                var delay: UInt32 = 250_000
                while !state.isClientGone() {
                    if let fresh = connect(path: socketPath) {
                        state.adopt(fresh)
                        note("mcp: re-bridged to the running app")
                        break
                    }
                    usleep(delay)
                    delay = min(delay * 2, 4_000_000)
                }
                continue
            }
            let n = read(handle.fileDescriptor, &buf, buf.count)
            if n == 0 || (n < 0 && errno != EINTR) {
                state.remoteDied(handle)
                note("mcp: app side closed — holding the session for a reconnect")
                continue
            }
            if n < 0 { continue }   // EINTR
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { raw in
                    write(localOut.fileDescriptor, raw.baseAddress! + off, n - off)
                }
                if w < 0 { if errno == EINTR { continue }; state.clientClosed(); return }
                off += w
            }
        }
    }

    /// P0 zombie guard (the /Applications launch-wedge incident,
    /// 2026-07-07): a bridge whose spawning client died can survive when an
    /// orphaned grandchild still holds the stdin pipe's write end — stdin
    /// never EOFs, the bridge lives for days. Poll the parent: when the
    /// direct parent exits, PPID re-parents to 1 (launchd) — exit. Call
    /// ONLY from the bridge PROCESS entry (never from tests: it exits the
    /// process).
    public static func exitWhenOrphaned(pollSeconds: UInt32 = 5) {
        Thread.detachNewThread {
            while true {
                if getppid() == 1 {
                    FileHandle.standardError.write(
                        Data("mcp: client parent exited — bridge shutting down\n".utf8))
                    exit(0)
                }
                sleep(pollSeconds)
            }
        }
    }

    /// Shared connection state for `serve`: the current remote handle and
    /// the client-gone flag, guarded by one condition (the stdin thread
    /// waits on it during reconnect gaps).
    private final class ServeState: @unchecked Sendable {
        private let cond = NSCondition()
        private var remote: FileHandle?
        private var clientGone = false

        init(remote: FileHandle) { self.remote = remote }

        func currentRemote() -> FileHandle? {
            cond.lock(); defer { cond.unlock() }
            return remote
        }

        func isClientGone() -> Bool {
            cond.lock(); defer { cond.unlock() }
            return clientGone
        }

        /// Block until a live remote exists (nil = the client went away).
        func waitForRemote() -> FileHandle? {
            cond.lock(); defer { cond.unlock() }
            while remote == nil && !clientGone { cond.wait() }
            return clientGone ? nil : remote
        }

        /// The given socket died: DROP the reference (only when it is still
        /// the current one — a stale double-report must not kill a fresh
        /// replacement). No explicit close: ARC closes when the last
        /// holding thread releases, which is what makes the fd un-recyclable
        /// while any syscall is still in flight.
        func remoteDied(_ handle: FileHandle) {
            cond.lock(); defer { cond.unlock() }
            if remote === handle { remote = nil }
        }

        func adopt(_ fresh: FileHandle) {
            cond.lock(); defer { cond.unlock() }
            remote = fresh
            cond.broadcast()
        }

        func clientClosed() {
            cond.lock(); defer { cond.unlock() }
            clientGone = true
            // shutdown(2), not close(): it UNBLOCKS the main loop's
            // in-flight read with EOF (closing a unix-socket fd under a
            // blocked reader does not reliably wake it on macOS) and keeps
            // the fd number alive until ARC releases the last hold — no
            // recycle hazard.
            if let r = remote { shutdown(r.fileDescriptor, SHUT_RDWR) }
            remote = nil
            cond.broadcast()
        }
    }
}
