import Foundation
import ViewerCore

/// TSK-1323/1324 — the Audio Extract/Convert panel's DocumentModel wiring. Opens the panel seeded
/// with the active media tab's URL (a video for extract, an audio file for convert); the output
/// opens in a new tab. The off-main transcode lives on `AudioConvertViewModel`.
extension DocumentModel {

    static let videoExtensions: Set<String> =
        ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "flv", "wmv"]
    static let audioFileExtensions: Set<String> =
        ["mp3", "wav", "aiff", "aif", "caf", "m4a", "aac", "flac", "ogg", "opus"]

    public static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
    public static func isAudioFile(_ url: URL) -> Bool {
        audioFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Open the panel to EXTRACT audio from the active video tab. No-op if it isn't a video.
    public func openExtractAudio() {
        guard let url = tabs.selected?.url, Self.isVideoFile(url) else { return }
        audioConvertVM = AudioConvertViewModel(sourceURL: url, dropVideo: true)
        showAudioConvert = true
    }

    /// Open the panel to CONVERT the active audio tab's format/quality. No-op if it isn't audio.
    public func openConvertAudio() {
        guard let url = tabs.selected?.url, Self.isAudioFile(url) else { return }
        audioConvertVM = AudioConvertViewModel(sourceURL: url, dropVideo: false)
        showAudioConvert = true
    }

    /// Open a transcoded audio file in a new tab (the panel's output handler).
    public func openConvertedAudio(_ url: URL) {
        openInNewTab(url)
    }
}
