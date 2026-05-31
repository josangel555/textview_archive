import Darwin
import Foundation

/// Runtime probes feeding the diagnostic window: the temp files WE own, and
/// this process's open file descriptors (`proc_pidinfo PROC_PIDLISTFDS`).
///
/// "Open ports" is deliberately **CUT** (PRIORITIZED_PLAN §6 / open
/// questions): a viewer has no business holding listening sockets, and
/// system-wide port enumeration would need entitlements we don't want.
/// Socket fds still surface in the fd list (as `socket`), without remote
/// addresses — that's the honest, low-stakes amount.
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
}
