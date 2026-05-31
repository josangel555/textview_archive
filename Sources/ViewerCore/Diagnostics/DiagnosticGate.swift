import Foundation

/// Build/flag gate for the diagnostic window + dump (PRIORITIZED_PLAN item
/// 17). Mirrors the existing SIGUSR1 trap gate in
/// `Sources/MarkdownViewer/Diagnostics.swift` (`AppDelegate.diagnosticsTrapEnabled`)
/// but lives in ViewerCore so the window/view code, the dump writer, and the
/// host can all consult ONE predicate.
///
/// Enabled iff this is a DEBUG build, OR the operator opts in with
/// `MDV_ENABLE_DIAGNOSTICS=1`. A stock release binary with the env var unset
/// exposes nothing.
public enum DiagnosticGate {

    /// Environment variable that opts a release build into diagnostics.
    public static let optInEnvVar = "MDV_ENABLE_DIAGNOSTICS"

    /// Is the diagnostic surface available for this build/run?
    public static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment[optInEnvVar] == "1"
        #endif
    }

    /// True for DEBUG builds. Surfaced into the snapshot so an exported
    /// artifact records whether it came from a debug or opted-in release run.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Whether absolute paths should be redacted by default in an *exported*
    /// artifact. We redact in release-opt-in dumps (an artifact that survives
    /// the process reveals username + project layout) but keep real paths in
    /// DEBUG for forensic value — mirroring `AppDelegate.redactDiagnosticContent`.
    public static var redactPathsInExport: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

/// Best-effort absolute-path redactor for any diagnostic artifact that can
/// leave the process. `/Users/<name>/work/proj/foo.swift` reveals the
/// username and the project layout; we collapse the home prefix to `~` and,
/// when redacting, replace the user's home directory with a stable token.
///
/// This is a privacy reducer, not a security boundary — a determined reader
/// of a *non-redacted* DEBUG dump still sees everything. Its job is to keep
/// an exported release-opt-in artifact from casually embedding PII.
public enum PathRedactor {

    /// Collapse the current user's home directory to `<HOME>` and the
    /// per-user tmpdir to `<TMP>`, keeping the trailing relative portion so
    /// the artifact is still useful for diagnosis ("which temp file", "which
    /// project subdir") without the absolute prefix.
    public static func redact(_ path: String) -> String {
        var p = path
        let home = NSHomeDirectory()
        // Per-user tmpdir first (it can itself sit under a deep /var/folders
        // path that doesn't overlap home; redact it to a stable token).
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if !tmp.isEmpty, p.hasPrefix(tmp) {
            p = "<TMP>" + String(p.dropFirst(tmp.count))
        } else if !home.isEmpty, p.hasPrefix(home) {
            p = "<HOME>" + String(p.dropFirst(home.count))
        }
        return p
    }
}
