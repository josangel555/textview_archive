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
        if let custom, !custom.isEmpty, isExecutable(custom, fileManager) {
            return URL(fileURLWithPath: custom)
        }
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = "\(dir)/ffmpeg"
                if isExecutable(candidate, fileManager) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        for candidate in commonPaths where isExecutable(candidate, fileManager) {
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

    private static func isExecutable(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }
}
