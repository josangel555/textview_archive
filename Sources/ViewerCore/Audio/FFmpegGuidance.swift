import Foundation

/// TSK-1442 — ONE source of truth for the "ffmpeg isn't installed" guidance,
/// so every ffmpeg-dependent feature (audio convert/extract, MP3 export)
/// presents CONSISTENT install guidance rather than each hand-rolling its own
/// wording (or silently disabling). Pure + host-tested; the views read these.
public enum FFmpegGuidance {

    /// The install hint — the same phrasing everywhere. Platform-appropriate
    /// (Homebrew is the common macOS path; the hint stays generic enough to
    /// not mislead a MacPorts/manual user).
    public static let installHint = "install it (e.g. `brew install ffmpeg`)"

    /// A full one-line message for a blocked ACTION (a failed/blocked convert
    /// or export). `verb` names what the user was trying to do.
    public static func unavailableMessage(action verb: String) -> String {
        "ffmpeg isn't available — \(installHint) to \(verb)."
    }

    /// A short menu/control DECORATION for a disabled ffmpeg-only option
    /// (e.g. the MP3 format row): "MP3 (ffmpeg not found)".
    public static func disabledOptionTitle(_ optionName: String) -> String {
        "\(optionName) (ffmpeg not found)"
    }

    /// Whether ffmpeg-dependent features should present guidance (absent) vs
    /// run (present). A thin, injectable pass-through to `FFmpegLocator` so a
    /// view's "show the banner?" decision is testable without a real binary.
    public static func shouldGuide(
        override custom: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !FFmpegLocator.isAvailable(override: custom, environment: environment)
    }
}
