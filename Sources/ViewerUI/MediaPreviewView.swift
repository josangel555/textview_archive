import AVKit
import AppKit
import PDFKit
import SwiftUI
import ViewerKit

/// Native previews for non-text file types. Routes by `FileCategory`
/// to the appropriate AppKit primitive (NSImageView / AVPlayerView /
/// PDFView). No WKWebView involved — we want crisp native rendering,
/// system shortcuts (space-to-play, arrow-to-navigate-pages), and
/// none of the web-platform footprint.
///
/// All three use `NSViewRepresentable` directly. None of them attach
/// `NSRulerView` so they're not at risk of the compositor pathology
/// LESSONS.md describes — the bug was specifically about
/// `NSRulerView` reentrant `tile()` calls.
public struct MediaPreviewView: View {
    public let url: URL
    public let category: FileCategory

    public init(url: URL, category: FileCategory) {
        self.url = url
        self.category = category
    }

    public var body: some View {
        switch category {
        case .image: ImagePreview(url: url)
        case .audio: AudioPreview(url: url)
        case .video: VideoPreview(url: url)
        case .pdf:   PDFPreview(url: url)
        case .sqlite:
            SQLiteBrowserView(url: url)
        default:
            UnsupportedPreview(url: url, category: category)
        }
    }
}

private struct ImagePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        // ScrollView so big images can pan / zoom via gestures.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.allowsMagnification = true
        scroll.maxMagnification = 16
        scroll.minMagnification = 0.05
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = NSImage(contentsOf: url)
        if let img = imageView.image {
            imageView.frame = NSRect(origin: .zero, size: img.size)
        }
        scroll.documentView = imageView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let iv = scroll.documentView as? NSImageView else { return }
        // Reload only when URL changed.
        let current = (iv.image?.name() == url.path)
        if !current {
            let fresh = NSImage(contentsOf: url)
            iv.image = fresh
            fresh?.setName(url.path)
            if let img = fresh {
                iv.frame = NSRect(origin: .zero, size: img.size)
            }
        }
    }
}

private struct AudioPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = AVPlayer(url: url)
        v.controlsStyle = .default
        v.showsFullScreenToggleButton = false  // not meaningful for audio
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Replace the player only when URL actually changes — avoids
        // re-creating a fresh AVPlayer on every SwiftUI update which
        // would yank playback.
        if let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url,
           current == url {
            return
        }
        nsView.player = AVPlayer(url: url)
    }
}

private struct VideoPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = AVPlayer(url: url)
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url,
           current == url {
            return
        }
        nsView.player = AVPlayer(url: url)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        v.backgroundColor = .windowBackgroundColor
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL == url { return }
        nsView.document = PDFDocument(url: url)
    }
}

private struct UnsupportedPreview: View {
    let url: URL
    let category: FileCategory
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .resizable().scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
            Text("Preview not available for \(category.rawValue)")
            Text(url.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
