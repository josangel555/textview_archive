import Darwin
import Foundation

/// Runtime probes feeding the diagnostic window: the temp files WE own, this
/// process's open file descriptors (`proc_pidinfo PROC_PIDLISTFDS`), and our
/// own sockets enriched with port/state (`proc_pidfdinfo PROC_PIDFDSOCKETINFO`).
///
/// ## "Open ports": process-scoped, not a system port scan
/// A *system-wide* port enumeration stays **CUT** — it needs entitlements we
/// don't want and is none of a viewer's business. But introspecting **our
/// own** sockets needs no entitlement (the same `proc_pidfdinfo` call already
/// used for vnode paths), and answers the genuinely useful diagnostic: "is the
/// app holding a listening socket it shouldn't? what local port is it talking
/// to?" `openSockets` therefore enriches each socket fd with family/proto/
/// local+foreign PORT/state — **never the peer address** (that's the exfil
/// surface). A socket fd still also surfaces in `openFileDescriptors` as a
/// bare `socket` row; `openSockets` is the enriched view of the same fds.
///
/// Foundation/Darwin-only, no SwiftUI/AppKit (ViewerCore boundary). The probes
/// are `nonisolated`/static and return value types, so they can run off the
/// main thread.
public enum DiagnosticProbes {

    // MARK: - Temp files we own

    /// Substring marking a per-user-tmpdir artifact as ours. Every temp file
    /// the app writes carries `mdv-` (atomic-save temps `.<name>.mdv-<uuid>.tmp`,
    /// diagnostic dumps `mdv-diagnostic-*.json`, snapshots `mdv-snapshot-*.png`,
    /// `mdv-auto.{json,png}`, and the new `mdv-diagnostic-snapshot-*.json`).
    /// We sweep ONLY files carrying this marker so the probe never enumerates
    /// unrelated tenants of the shared `/var/folders/...` tmpdir.
    public static let ownedTempMarker = "mdv-"

    /// Enumerate the per-user temp directory for artifacts WE own. Returns
    /// path + size + mtime only — never reads any file body (content
    /// redaction by construction). Best-effort: an unreadable entry is
    /// skipped, not fatal.
    public static func ownedTempFiles(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> [DiagnosticTempFile] {
        let fm = FileManager.default
        // NOTE: do NOT pass `.skipsHiddenFiles`. The atomic-save temps we own
        // are dotfiles (`.<name>.mdv-<uuid>.tmp`, see EditorBuffer); skipping
        // hidden entries would silently miss exactly the artifacts most likely
        // to leak if left behind. We still scope strictly to the `mdv-` marker
        // below, so unrelated dotfiles are not enumerated.
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else { return [] }

        var out: [DiagnosticTempFile] = []
        for url in entries {
            // Match on the substring, not just a prefix: the atomic-save
            // temp is `.<name>.mdv-<uuid>.tmp` (marker mid-name), while the
            // diagnostic artifacts are `mdv-…` (marker at front).
            guard url.lastPathComponent.contains(ownedTempMarker) else { continue }
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
            ])
            // Skip directories — we only own files.
            if values?.isRegularFile == false { continue }
            let size = values?.fileSize ?? 0
            let mtimeNanos: UInt64
            if let d = values?.contentModificationDate, d.timeIntervalSince1970 > 0 {
                mtimeNanos = UInt64(d.timeIntervalSince1970 * 1_000_000_000)
            } else {
                mtimeNanos = 0
            }
            out.append(DiagnosticTempFile(
                path: url.standardizedFileURL.path,
                sizeBytes: size,
                modifiedUnixNanos: mtimeNanos))
        }
        // Stable order: newest first, then by path for determinism.
        out.sort {
            if $0.modifiedUnixNanos != $1.modifiedUnixNanos {
                return $0.modifiedUnixNanos > $1.modifiedUnixNanos
            }
            return $0.path < $1.path
        }
        return out
    }

    // MARK: - Open file descriptors

    /// Enumerate this process's open file descriptors via
    /// `proc_pidinfo(PROC_PIDLISTFDS)`, resolving vnode (file) paths via
    /// `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)`. Returns fd + a coarse kind
    /// label + a resolved path for file fds (nil for sockets/pipes/etc.,
    /// which have no filesystem path).
    ///
    /// This enumerates *every* file the app has open — explicitly the
    /// content/path-exposure surface flagged in triage. It only ever runs
    /// behind `DiagnosticGate`, never via the MCP host, and paths are
    /// redactable for export.
    public static func openFileDescriptors(pid: Int32 = getpid()) -> [DiagnosticOpenFD] {
        // First call sizes the buffer.
        let probeSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probeSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(probeSize) / stride
        guard capacity > 0 else { return [] }

        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let usedBytes = fds.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard usedBytes > 0 else { return [] }
        let n = min(Int(usedBytes) / stride, capacity)

        var out: [DiagnosticOpenFD] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let info = fds[i]
            let kind = fdTypeLabel(info.proc_fdtype)
            var path: String? = nil
            if info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                path = vnodePath(pid: pid, fd: info.proc_fd)
            }
            out.append(DiagnosticOpenFD(fd: info.proc_fd, kind: kind, path: path))
        }
        out.sort { $0.fd < $1.fd }
        return out
    }

    /// Resolve the filesystem path backing a vnode fd. Returns nil if the
    /// kernel call fails (e.g. the fd was closed between enumeration and
    /// resolution) or the path is empty.
    private static func vnodePath(pid: Int32, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let got = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size)
        guard got > 0 else { return nil }
        let path = withUnsafePointer(to: &info.pvip.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Coarse human label for a `proc_fdtype` value. Covers the kinds a
    /// desktop viewer realistically holds; unknown numeric types fall through
    /// to `fd(<n>)` rather than asserting.
    private static func fdTypeLabel(_ type: UInt32) -> String {
        switch Int32(type) {
        case PROX_FDTYPE_ATALK:    return "atalk"
        case PROX_FDTYPE_VNODE:    return "vnode"
        case PROX_FDTYPE_SOCKET:   return "socket"
        case PROX_FDTYPE_PSHM:     return "posix-shm"
        case PROX_FDTYPE_PSEM:     return "posix-sem"
        case PROX_FDTYPE_KQUEUE:   return "kqueue"
        case PROX_FDTYPE_PIPE:     return "pipe"
        case PROX_FDTYPE_FSEVENTS: return "fsevents"
        default:                   return "fd(\(type))"
        }
    }

    // MARK: - Sockets we own (process-scoped "open ports")

    /// Enrich THIS process's socket fds with family/proto/local+foreign
    /// port/state via `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Returns one
    /// `DiagnosticSocket` per socket fd we can decode. Never enumerates other
    /// processes; never reports peer addresses (only ports).
    ///
    /// Best-effort: an fd that closes between listing and the per-fd call, or
    /// a kind the kernel won't decode, is skipped — not fatal.
    public static func openSockets(pid: Int32 = getpid()) -> [DiagnosticSocket] {
        // Reuse the same PROC_PIDLISTFDS enumeration as the fd probe, then
        // filter to socket-typed fds and decode each.
        let probeSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probeSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(probeSize) / stride
        guard capacity > 0 else { return [] }

        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let usedBytes = fds.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard usedBytes > 0 else { return [] }
        let n = min(Int(usedBytes) / stride, capacity)

        var out: [DiagnosticSocket] = []
        for i in 0..<n {
            let info = fds[i]
            guard info.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            if let row = socketInfo(pid: pid, fd: info.proc_fd) {
                out.append(row)
            }
        }
        out.sort { $0.fd < $1.fd }
        return out
    }

    /// Decode one socket fd into a `DiagnosticSocket`. Returns nil if the
    /// kernel call fails.
    private static func socketInfo(pid: Int32, fd: Int32) -> DiagnosticSocket? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let got = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        guard got > 0 else { return nil }

        let si = info.psi
        let family = familyLabel(si.soi_family)
        let proto = protoLabel(kind: si.soi_kind, family: si.soi_family)

        // Only inet/inet6 sockets carry meaningful ports. The union member to
        // read depends on `soi_kind`: TCP nests its `in_sockinfo` under
        // `pri_tcp.tcpsi_ini`; raw IP / UDP use `pri_in` directly.
        var localPort: Int? = nil
        var foreignPort: Int? = nil
        var state = "—"
        var listening = false

        switch Int(si.soi_kind) {
        case SOCKINFO_TCP:
            let tcp = si.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            localPort = hostPort(ini.insi_lport)
            foreignPort = hostPort(ini.insi_fport)
            state = tcpStateLabel(tcp.tcpsi_state)
            listening = (tcp.tcpsi_state == Int32(TSI_S_LISTEN))
        case SOCKINFO_IN:
            let ini = si.soi_proto.pri_in
            localPort = hostPort(ini.insi_lport)
            foreignPort = hostPort(ini.insi_fport)
            // Non-TCP inet (UDP/raw): coarse connected/unconnected from the
            // generic socket state flags.
            state = (si.soi_state & Int16(SOI_S_ISCONNECTED)) != 0 ? "connected" : "unconnected"
        default:
            // unix / kctl / kevt / vsock: no inet port; coarse liveness only.
            state = (si.soi_state & Int16(SOI_S_ISCONNECTED)) != 0 ? "connected" : "unconnected"
        }

        return DiagnosticSocket(
            fd: fd,
            family: family,
            proto: proto,
            localPort: localPort,
            foreignPort: foreignPort,
            state: state,
            isListening: listening)
    }

    /// Convert a kernel-stored network-byte-order port (`int` holding a 16-bit
    /// big-endian value) to a host-order port, or nil for the unset port 0.
    private static func hostPort(_ stored: Int32) -> Int? {
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: stored))
        return port == 0 ? nil : Int(port)
    }

    private static func familyLabel(_ family: Int32) -> String {
        switch family {
        case AF_INET:  return "inet"
        case AF_INET6: return "inet6"
        case AF_UNIX:  return "unix"
        case AF_SYSTEM: return "system"
        default:       return "family(\(family))"
        }
    }

    private static func protoLabel(kind: Int32, family: Int32) -> String {
        switch Int(kind) {
        case SOCKINFO_TCP:        return "tcp"
        case SOCKINFO_IN:         return family == AF_INET6 || family == AF_INET ? "udp" : "ip"
        case SOCKINFO_UN:         return "unix"
        case SOCKINFO_KERN_CTL:   return "kctl"
        case SOCKINFO_KERN_EVENT: return "kevt"
        case SOCKINFO_NDRV:       return "ndrv"
        case SOCKINFO_VSOCK:      return "vsock"
        default:                  return "other"
        }
    }

    /// Map a `tcpsi_state` (the `TSI_S_*` macros) to a human label.
    private static func tcpStateLabel(_ state: Int32) -> String {
        switch state {
        case Int32(TSI_S_CLOSED):       return "closed"
        case Int32(TSI_S_LISTEN):       return "listen"
        case Int32(TSI_S_SYN_SENT):     return "syn_sent"
        case Int32(TSI_S_SYN_RECEIVED): return "syn_received"
        case Int32(TSI_S_ESTABLISHED):  return "established"
        case Int32(TSI_S__CLOSE_WAIT):  return "close_wait"
        case Int32(TSI_S_FIN_WAIT_1):   return "fin_wait_1"
        case Int32(TSI_S_CLOSING):      return "closing"
        case Int32(TSI_S_LAST_ACK):     return "last_ack"
        case Int32(TSI_S_FIN_WAIT_2):   return "fin_wait_2"
        case Int32(TSI_S_TIME_WAIT):    return "time_wait"
        default:                        return "state(\(state))"
        }
    }
}
