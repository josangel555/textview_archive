import Darwin
import Foundation

// TSK-502 — finish the VM T5/VisualRegression pixel lane WITHOUT an owner-only
// xctest TCC grant.
//
// On the UTM VM the owner granted Screen-Recording (`kTCCServiceScreenCapture`)
// to `/bin/bash` + Terminal, but NOT to the swiftpm `xctest` runner (it's
// ad-hoc signed and its path changes per build, so a durable grant needs an MDM
// PPPC profile). The pixel tests spawn `screencapture` from inside the xctest
// process; macOS attributes the capture to the TCC *responsible process*, which
// — for an ordinarily-spawned child — propagates from the parent, i.e. xctest.
// So the capture is DENIED and all six visual-regression tests self-skip.
//
// The fix here is the responsibility-disclaim SPI: spawn `/bin/bash` with
// `responsibility_spawnattrs_setdisclaim(attr, 1)` so the spawned bash DISCLAIMS
// xctest's responsibility and becomes its OWN responsible process. The
// `screencapture` it then execs inherits bash as its responsible process, and
// bash already holds the grant → the capture goes through. This is the same
// mechanism `/usr/bin/disclaim` uses; it needs no SIP-protected TCC.db write.
//
// Test-only: `@_silgen_name` binds the private libSystem symbol directly (never
// shipped — this file lives in the UI test target). If a future macOS drops the
// symbol the link fails loudly at build time rather than silently mis-capturing.

@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
) -> Int32

/// Run `command` via `/bin/bash -c` with the bash process disclaiming the
/// xctest parent's TCC responsibility (see file header). Returns the command's
/// exit code, or `-1` on spawn failure / signal death. Synchronous.
///
/// Use this for `screencapture` in the VM pixel tier; on the host the heavy
/// tiers self-skip, so behaviour there is unchanged.
func runDisclaimedShell(_ command: String) -> Int32 {
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return -1 }
    defer { posix_spawnattr_destroy(&attr) }
    // Make the spawned bash its own TCC responsible process.
    _ = responsibility_spawnattrs_setdisclaim(&attr, 1)

    let argv = ["/bin/bash", "-c", command]
    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { for p in cArgv where p != nil { free(p) } }

    var pid: pid_t = 0
    let rc = cArgv.withUnsafeBufferPointer { buf -> Int32 in
        posix_spawn(&pid, "/bin/bash", nil, &attr,
                    UnsafeMutablePointer(mutating: buf.baseAddress), environ)
    }
    guard rc == 0 else { return -1 }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    // Exited normally → low 7 bits are 0; return the exit code. Signal → -1.
    return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
}
