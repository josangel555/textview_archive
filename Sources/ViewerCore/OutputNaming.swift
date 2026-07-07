import Foundation

/// TSK-1473 / TSK-1469 / TSK-1447 — the "NEVER overwrite; write a sibling"
/// rule as a reusable, host-tested primitive. Every save/extract/convert flow
/// that writes to a user-picked location must avoid clobbering an existing
/// file; today each would hand-roll it. `nonColliding` picks the desired URL
/// or the first free `<base>-N.<ext>` sibling (Finder "copy N" convention),
/// with the existence check INJECTED so it's pure and host-tested — the
/// caller passes `FileManager.default.fileExists(atPath:)` at the call site.
public enum OutputNaming {

    /// A non-colliding output URL for `desired`: `desired` itself if free,
    /// else `<base>-2.<ext>`, `<base>-3.<ext>`, … in the same directory until
    /// one doesn't exist. Multi-dot names keep only the LAST extension as the
    /// suffix boundary (`foo.tar.gz` → `foo.tar-2.gz`), matching how the
    /// system treats extensions. Extension-less names get a bare `-N`
    /// (`README` → `README-2`).
    ///
    /// - Parameter exists: injected existence probe (pass
    ///   `FileManager.default.fileExists(atPath:$0.path)` live).
    /// - Parameter maxAttempts: a runaway guard; if every candidate up to it
    ///   collides, returns the last candidate (the caller's write then fails
    ///   loudly rather than looping forever).
    public static func nonColliding(
        desired: URL,
        exists: (URL) -> Bool,
        maxAttempts: Int = 10_000
    ) -> URL {
        guard exists(desired) else { return desired }

        let dir = desired.deletingLastPathComponent()
        let ext = desired.pathExtension                    // "" when none
        let base = desired.deletingPathExtension().lastPathComponent

        var candidate = desired
        var n = 2
        while n <= maxAttempts {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
        return candidate  // exhausted — return the last; the write will error
    }
}
