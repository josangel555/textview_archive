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
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Pump bytes both ways until EITHER side reaches EOF or dies, then
    /// close both. Blocking; run it on the launch thread of a bridge-only
    /// process (no AppKit needed) and `exit` afterwards.
    ///
    /// Two plain threads, 64 KiB reads. `read(2)`/`write(2)` via FileHandle;
    /// a zero-length read is EOF. Closing the opposite handle unblocks the
    /// sibling thread's read, so one EOF winds down the whole bridge.
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
}
