import Foundation

/// Best-effort discovery of an `ffmpeg` executable on the host (TSK-528, owner
/// decision 2026-06-09: ffmpeg is an EXTERNAL host tool — neither bundled nor a
/// build dependency — used to encode MP3, which AVFoundation can't. If ffmpeg
/// isn't found the MP3 export feature is simply disabled; everything else
/// (WAV/AIFF/CAF/AAC) is unaffected.
///
/// Resolution order: an explicit user-provided path (the Settings override) →
/// the first `ffmpeg` on `PATH` → a short list of common install locations.
/// Pure + injectable (environment / candidate list / FileManager) so the order
/// is host-testable without a real ffmpeg.
public enum FFmpegLocator {

    /// Where Homebrew / MacPorts / system packages typically put `ffmpeg`.
    public static let defaultCommonPaths = [
        "/opt/homebrew/bin/ffmpeg",   // Apple-silicon Homebrew
        "/usr/local/bin/ffmpeg",      // Intel Homebrew
        "/opt/local/bin/ffmpeg",      // MacPorts
        "/usr/bin/ffmpeg",            // system
    ]

    /// Resolve the `ffmpeg` executable, or `nil` if none is found (⇒ MP3 export
    /// disabled). `override` is the user-supplied Settings path; when it points
    /// at an executable file it always wins.
    public static func resolve(
        override custom: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commonPaths: [String] = defaultCommonPaths,
        fileManager: FileManager = .default
    ) -> URL? {
        if let custom, !custom.isEmpty, isUsable(custom, fileManager) {
            return URL(fileURLWithPath: custom)
        }
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = "\(dir)/ffmpeg"
                if isUsable(candidate, fileManager) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        for candidate in commonPaths where isUsable(candidate, fileManager) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Whether MP3 export is available on this host (an `ffmpeg` was found).
    public static func isAvailable(
        override custom: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolve(override: custom, environment: environment) != nil
    }

    /// A candidate is usable iff it's an executable file AND its containing
    /// directory is not group- or world-writable (mirrors
    /// `LSPDiscovery.isBinarySafeToSpawn`, S3.1). We spawn `ffmpeg` with our
    /// inherited stdio + an env allowlist on MP3 export; a `ffmpeg` sitting in a
    /// group/world-writable dir early on `$PATH` could be swapped for a hostile
    /// binary by a non-owner, so we refuse it and fall through to the next
    /// candidate (⇒ MP3 export disabled if none is safe).
    static func isUsable(_ path: String, _ fm: FileManager = .default) -> Bool {
        isExecutable(path, fm) && isContainingDirSafe(path, fm)
    }

    private static func isExecutable(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    /// Refuse a binary whose containing directory is group- (020) or world-
    /// writable (002): a non-owner could drop in or replace the executable.
    /// A directory we can't stat is treated as safe (don't lock out a setup we
    /// don't understand — same posture as the LSP check); the narrow case we
    /// block is the obviously-bad `0o777` shared-machine scenario.
    private static func isContainingDirSafe(_ path: String, _ fm: FileManager) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        guard let attrs = try? fm.attributesOfItem(atPath: dir),
              let perms = attrs[.posixPermissions] as? NSNumber else {
            return true
        }
        return (perms.uint16Value & 0o022) == 0
    }
}
