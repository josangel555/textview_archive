import AVFoundation
import Foundation

/// TSK-1308 — app-level audio playback that SURVIVES view / session-switch teardown.
///
/// The audio `AVPlayer` used to be created and owned by the `AudioPlayerHost`
/// NSViewRepresentable (`makeNSView`), so switching sessions — which tears down the
/// media tab's view — deallocated the player and stopped the music. This holds the
/// player at app scope: the media view *binds to* (and re-binds to) the persistent
/// player rather than owning it, so playback continues while the user is in another
/// session/tab, and resumes seamlessly when they return.
///
/// One stream at a time: requesting a different URL stops the prior stream and starts
/// a fresh one (the common "play this audio" case). Requesting the SAME URL reuses the
/// live player so a SwiftUI re-mount / re-render never yanks playback.
///
/// The model (reuse-vs-replace + the surviving reference) is host-tested; the
/// AVPlayerView binding is the render tail (the on-screen "audio survives the switch"
/// is owner/VM-verified).
@MainActor
public final class AudioPlaybackController: ObservableObject {
    public static let shared = AudioPlaybackController()
    public init() {}

    /// The URL of the currently-held stream (nil when nothing has played yet).
    public private(set) var currentURL: URL?
    /// The persistent player — outlives any requesting view.
    public private(set) var activePlayer: AVPlayer?

    /// The persistent `AVPlayer` for `url`. Reuses the live player when `url` is
    /// unchanged (no playback yank on re-mount); otherwise pauses the prior stream and
    /// starts a fresh one. The returned player is retained by this controller, so it
    /// keeps playing after the requesting view is torn down.
    @discardableResult
    public func player(for url: URL) -> AVPlayer {
        if currentURL == url, let p = activePlayer { return p }
        activePlayer?.pause()
        let p = AVPlayer(url: url)
        activePlayer = p
        currentURL = url
        return p
    }
}
