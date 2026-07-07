import Foundation

/// TSK-1474 — whether AVFoundation can NATIVELY play a video file, decided
/// up front so the preview shows a real fallback state ("can't preview —
/// open externally") instead of a black AVPlayerView. `FileCategory.video`
/// is deliberately broad (it routes the file to the media surface); this is
/// the second gate: the surface picks the PLAYER for `.native` and the
/// fallback card for `.unsupported`.
///
/// Static-by-extension on purpose: `AVURLAsset.isPlayable` needs async media
/// loading of the real file, and a wrong `.unsupported` here is a GRACEFUL
/// state (the card still offers open-externally) while a wrong `.native` is
/// a black screen — so ambiguous containers (avi: AVFoundation plays only
/// some MJPEG-era files) classify `.unsupported`.
public enum VideoPlayability: Equatable, Sendable {
    /// AVFoundation plays this container natively — show AVPlayerView.
    case native
    /// Not an AVFoundation container (or too unreliable) — show the
    /// fallback card with an open-externally affordance.
    case unsupported

    /// Containers AVFoundation reliably plays (QuickTime/MPEG-4 family).
    private static let nativeExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mpg", "mpeg", "3gp",
    ]

    /// Classify by (lowercased) path extension. Unknown extensions are
    /// `.unsupported` — the graceful default.
    public static func classify(extension ext: String) -> VideoPlayability {
        nativeExtensions.contains(ext.lowercased()) ? .native : .unsupported
    }

    /// Convenience over a URL.
    public static func classify(url: URL) -> VideoPlayability {
        classify(extension: url.pathExtension)
    }
}
