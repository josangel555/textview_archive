import Darwin
import Foundation

/// Honest process-memory introspection for the memory readout UI.
///
/// ## Why this is deliberately *not* a per-tab number
/// A `WKWebView` app's resident memory is split across XPC helper
/// processes that Activity Monitor sums under the parent
/// (`com.apple.WebKit.Networking`, `.GPU`, `.WebContent` — one
/// `WebContent` per rendering web view, 30–80 MB each per
/// `LESSONS.md`). A tab is not a process and `WKWebView` hands back no
/// pid, so there is **no honest per-tab RSS** in the common case — a
/// confident "this tab: 47 MB" would be fabricated. This type therefore
/// exposes only the three numbers that *are* honest:
///
///   1. `appFootprintBytes` — the main process's `phys_footprint`
///      (`task_info(TASK_VM_INFO)`). The number `LESSONS.md` calls "the
///      more useful number for our code"; it **excludes** the WebKit
///      helpers.
///   2. `webKitHelperBytes` — a *best-effort* sum of child
///      `com.apple.WebKit.*` helper footprints, reported separately and
///      explicitly labelled as shared. Best-effort because XPC helpers
///      can be reparented to `launchd`, in which case they are no longer
///      our direct children and this undercounts (`helpersComplete`
///      reflects whether enumeration looked plausible).
///
/// The per-tab *content-byte* proxy lives in the UI layer (it reads the
/// loaded document's `byteCount`), not here — this type is purely the
/// OS-level footprint source.
///
/// ## Boundary / portability
/// Foundation + `Darwin` only — no AppKit, no SwiftUI (ViewerCore
/// boundary rule). `Sendable` value type. The Mach/`libproc` calls are
/// macOS-specific; when the core eventually moves to Rust the same
/// `task_info` / `proc_pid_rusage` syscalls are reachable there, so the
/// *shape* of `ProcessMemorySample` survives the FFI boundary (flat,
/// `UInt64`s + `Bool`).
public struct ProcessMemorySample: Sendable, Equatable {
    /// `phys_footprint` of the main (this) process, in bytes. Excludes
    /// WebKit helper processes. `nil` if the `task_info` call failed
    /// (should not happen on a healthy process; surfaced as nil rather
    /// than a fabricated 0 so the UI can show "—").
    public let appFootprintBytes: UInt64?

    /// Best-effort sum of `com.apple.WebKit.*` helper-process
    /// footprints, in bytes. Shared across all tabs/web views — NOT
    /// attributable per tab. `0` is a legitimate value (no web view has
    /// been created yet).
    public let webKitHelperBytes: UInt64

    /// Number of WebKit helper processes that contributed to
    /// `webKitHelperBytes`. Shown in the UI tooltip so the number is
    /// auditable ("3 helpers").
    public let webKitHelperCount: Int

    /// Whether helper enumeration completed without hitting the pid-list
    /// buffer cap. `false` means the sum is a lower bound (some helpers
    /// may have been reparented to launchd or the buffer was undersized);
    /// the UI annotates the figure as approximate in that case.
    public let helpersComplete: Bool

    public init(
        appFootprintBytes: UInt64?,
        webKitHelperBytes: UInt64,
        webKitHelperCount: Int,
        helpersComplete: Bool
    ) {
        self.appFootprintBytes = appFootprintBytes
        self.webKitHelperBytes = webKitHelperBytes
        self.webKitHelperCount = webKitHelperCount
        self.helpersComplete = helpersComplete
    }
}

/// Samples OS-level memory for the current process and its WebKit XPC
/// helpers. A namespace `enum` (no instances) — the syscalls are
/// stateless. **Sample off the main thread on a slow timer (~1 Hz);**
/// the child-pid enumeration walks every process on the system and is
/// not free, so it must never run on a hot/render path
/// (triage-instrumentation.md: cap at ~1 Hz).
public enum ProcessMemory {

    /// Prefix every WebKit XPC helper executable path carries
    /// (`.../com.apple.WebKit.WebContent.xpc/...`,
    /// `com.apple.WebKit.GPU`, `com.apple.WebKit.Networking`). Matching
    /// on the path is the only handle we get — `WKWebView` exposes no
    /// pid API.
    private static let webKitMarker = "com.apple.WebKit"

    /// Take a full sample: app footprint + best-effort WebKit-helper sum.
    public static func sample() -> ProcessMemorySample {
        let app = appFootprintBytes()
        let helpers = webKitHelperFootprint()
        return ProcessMemorySample(
            appFootprintBytes: app,
            webKitHelperBytes: helpers.bytes,
            webKitHelperCount: helpers.count,
            helpersComplete: helpers.complete)
    }

    /// `phys_footprint` of the current process via
    /// `task_info(TASK_VM_INFO)`. Returns `nil` on a non-success kernel
    /// status rather than a fabricated 0.
    public static func appFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// `phys_footprint` of an arbitrary pid via `proc_pid_rusage`.
    /// Returns `nil` if the pid is gone or we lack permission (helpers
    /// we don't own). Used per WebKit helper.
    static func footprintBytes(of pid: pid_t) -> UInt64? {
        var ru = rusage_info_v2()
        let kr = withUnsafeMutablePointer(to: &ru) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rp)
            }
        }
        guard kr == 0 else { return nil }
        return ru.ri_phys_footprint
    }

    /// Parent pid of `pid`, via `proc_pidinfo(PROC_PIDTBSDINFO)`.
    /// `nil` on failure. Used to keep the helper sum honest — we only
    /// count helpers that are *our* direct children.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz)
        guard n == sz else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Executable path of `pid`, or `nil`. Used to match the
    /// `com.apple.WebKit` marker.
    static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN) is not surfaced in
        // the Swift Darwin overlay; use the documented constant value.
        // `proc_pidpath` truncates into the buffer and never writes past
        // it, so a fixed 4096 is a safe upper bound for any path we'd
        // match against `com.apple.WebKit`.
        let maxPath = 4096
        var buf = [CChar](repeating: 0, count: maxPath)
        let n = proc_pidpath(pid, &buf, UInt32(maxPath))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Best-effort sum of `com.apple.WebKit.*` helper footprints whose
    /// parent is the current process.
    ///
    /// We enumerate all pids (cheap relative to a 1 Hz cadence), match
    /// the executable-path marker, and confirm the parent is us so an
    /// unrelated app's WebKit helpers are never attributed to us.
    /// `complete == false` if the pid-list buffer was at capacity (rare;
    /// flags the figure as a lower bound).
    static func webKitHelperFootprint() -> (bytes: UInt64, count: Int, complete: Bool) {
        let me = getpid()

        // Size the pid buffer. `proc_listallpids(nil, 0)` returns the
        // count of pids; pad generously so a process spawned between the
        // sizing call and the fill call doesn't get truncated.
        let probe = proc_listallpids(nil, 0)
        guard probe > 0 else { return (0, 0, false) }
        let capacity = Int(probe) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filledBytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard filledBytes > 0 else { return (0, 0, false) }
        let filledCount = Int(filledBytes) / MemoryLayout<pid_t>.size
        // If the kernel filled the whole buffer the list may be
        // truncated — flag the sum as a lower bound.
        let complete = filledCount < capacity

        var total: UInt64 = 0
        var helperCount = 0
        for i in 0..<min(filledCount, pids.count) {
            let pid = pids[i]
            guard pid > 0, pid != me else { continue }
            guard let path = executablePath(of: pid),
                  path.contains(webKitMarker) else { continue }
            // Only attribute helpers that are *our* children — never
            // another app's WebKit processes.
            guard parentPID(of: pid) == me else { continue }
            if let bytes = footprintBytes(of: pid) {
                total += bytes
                helperCount += 1
            }
        }
        return (total, helperCount, complete)
    }
}
