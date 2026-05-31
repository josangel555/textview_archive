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
    /// Called when the user navigates within a file family (prev/next
    /// image in the same directory). Nil disables navigation.
    public let onOpenSibling: ((URL) -> Void)?

    public init(url: URL, category: FileCategory,
                onOpenSibling: ((URL) -> Void)? = nil) {
        self.url = url
        self.category = category
        self.onOpenSibling = onOpenSibling
    }

    public var body: some View {
        switch category {
        case .image: ImagePreview(url: url, onOpenSibling: onOpenSibling)
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

/// Image viewer with centered render, overlay zoom controls, and
/// keyboard navigation:
///   - Left / Right arrow  → previous / next image in the same folder
///   - Up / Down arrow     → zoom in / out
///   - 0 / 1               → fit to window / actual size
///   - Cmd-+ / Cmd--       → zoom in / out (matches system convention)
///   - Cmd-0               → fit to window
struct ImagePreview: View {
    let url: URL
    let onOpenSibling: ((URL) -> Void)?

    @State private var magnification: CGFloat = 1.0
    @State private var pixelSize: NSSize = .zero
    @State private var didFit: Bool = false
    @State private var siblings: [URL] = []
    /// Memo for currentIndex — computed once per (siblings, url) pair
    /// rather than O(N) per body re-eval.
    @State private var currentIndex: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Palette.windowBackground
                .ignoresSafeArea()
            ImageScrollHost(url: url,
                            magnification: magnification,
                            onLoad: { size in
                                pixelSize = size
                                if !didFit { didFit = true; fitToWindow() }
                            },
                            onUserZoom: { newMag in
                                // Push wheel/pinch-driven zoom back
                                // into the SwiftUI state so the % HUD
                                // stays in sync and subsequent
                                // updateNSView calls don't snap back.
                                magnification = newMag
                            })
            VStack {
                Spacer()
                controlBar
                    .padding(.bottom, 12)
            }
        }
        .focusable()
        .focused($focused)
        .onAppear {
            focused = true
            loadSiblings(parent: url.deletingLastPathComponent(),
                         current: url)
        }
        .onChange(of: url) { _, new in
            didFit = false
            let newParent = new.deletingLastPathComponent()
            // Same parent dir? Just re-locate within the cached list.
            if !siblings.isEmpty,
               siblings.first?.deletingLastPathComponent() == newParent {
                currentIndex = siblings.firstIndex(of: new) ?? 0
            } else {
                loadSiblings(parent: newParent, current: new)
            }
        }
        .onKeyPress(.leftArrow)  { navigate(by: -1); return .handled }
        .onKeyPress(.rightArrow) { navigate(by: +1); return .handled }
        .onKeyPress(.upArrow)    { zoom(by: 1.25);  return .handled }
        .onKeyPress(.downArrow)  { zoom(by: 1/1.25); return .handled }
        .onKeyPress("0") { fitToWindow(); return .handled }
        .onKeyPress("1") { magnification = 1.0; return .handled }
        .accessibilityIdentifier("mdv.imagePreview")
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            if siblings.count > 1 {
                Button(action: { navigate(by: -1) }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Previous image (←)")
                .disabled(prevURL == nil)
                Text("\(currentIndex + 1) / \(siblings.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: { navigate(by: +1) }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Next image (→)")
                .disabled(nextURL == nil)
                Divider().frame(height: 14)
            }
            Button(action: { zoom(by: 1/1.25) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out (↓ or ⌘-)")
            Text(String(format: "%.0f%%", magnification * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48)
            Button(action: { zoom(by: 1.25) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in (↑ or ⌘+)")
            Divider().frame(height: 14)
            Button("Fit") { fitToWindow() }
                .buttonStyle(.borderless)
                .help("Fit to window (0 or ⌘0)")
            Button("1:1") { magnification = 1.0 }
                .buttonStyle(.borderless)
                .help("Actual size (1)")
            if pixelSize.width > 0 {
                Divider().frame(height: 14)
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
    }

    private var prevURL: URL? {
        currentIndex > 0 ? siblings[currentIndex - 1] : nil
    }
    private var nextURL: URL? {
        currentIndex + 1 < siblings.count
            ? siblings[currentIndex + 1] : nil
    }

    /// Run the sibling enumeration off-main and cache it. The previous
    /// code did `contentsOfDirectory` + N FileTypeDetector calls on
    /// `.onAppear` (main thread, synchronous) — for a Pictures folder
    /// with thousands of images that froze the UI on every open.
    private func loadSiblings(parent: URL, current: URL) {
        // Seed with at least the current URL so prev/next disable
        // correctly while enumeration is in flight.
        if siblings.isEmpty {
            siblings = [current]
            currentIndex = 0
        }
        Task.detached(priority: .userInitiated) {
            let list = ImagePreview.imageSiblings(of: current)
            await MainActor.run {
                // Bail if the user has navigated to a *different* folder
                // since this task started. We compare the task's source
                // folder (`parent`) against the view's currently displayed
                // URL — not against `current`, which is the task's own
                // input and would trivially match itself. Without this
                // the previous check was tautological and a stale folder
                // enumeration could overwrite siblings after a fast
                // arrow-key navigation across folders.
                guard url.deletingLastPathComponent() == parent else { return }
                siblings = list
                currentIndex = list.firstIndex(of: url) ?? 0
            }
        }
    }

    private func navigate(by delta: Int) {
        guard let onOpenSibling else { return }
        let target = delta < 0 ? prevURL : nextURL
        if let target { onOpenSibling(target) }
    }

    private func zoom(by factor: CGFloat) {
        // Clamp through ImageZoomState so the keyboard zoom range stays
        // identical to the wheel / pinch zoom range (0.1×–10×).
        magnification = ImageZoomState.nextMagnification(
            current: magnification, factor: factor)
    }

    private func fitToWindow() {
        // Setting magnification = 0 is interpreted by the scroll-host
        // as "compute fit-to-window magnification from current bounds."
        magnification = 0
    }

    /// Enumerate image siblings in `url`'s parent directory. Pure
    /// function: safe to call off main. Hidden files skipped.
    nonisolated static func imageSiblings(of url: URL) -> [URL] {
        let parent = url.deletingLastPathComponent()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [url] }
        let images = entries.filter {
            FileTypeDetector.category(for: $0) == .image
        }
        return images.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }
}

/// Internal AppKit hosting layer. Manages the NSScrollView+NSImageView
/// and applies a programmatic magnification from the SwiftUI side.
private struct ImageScrollHost: NSViewRepresentable {
    let url: URL
    let magnification: CGFloat
    let onLoad: (NSSize) -> Void
    /// Called when the user drives the zoom themselves (mousewheel +
    /// Cmd, or trackpad pinch) so the SwiftUI side can mirror the
    /// new magnification into `@State`. Without this, the next
    /// `updateNSView` would snap back to the stale SwiftUI value.
    let onUserZoom: (CGFloat) -> Void

    /// Coordinator tracks the loaded URL so we know whether
    /// `updateNSView` actually needs to swap the image. Was using
    /// `NSImage.setName(url.path)` as a cache key — but that name
    /// registers globally in `NSImage.imageNamed(_:)`, collides across
    /// tabs viewing different images, and never frees.
    final class Coordinator: NSObject {
        var lastURL: URL?
        /// Captured reference to the SwiftUI callback. Updated on each
        /// SwiftUI pass so it always sees current `@State` setters.
        var onUserZoom: (CGFloat) -> Void = { _ in }

        /// Fires on `NSScrollView.willStartLiveMagnifyNotification`'s
        /// counterpart end notification — pushes the post-gesture
        /// magnification back into SwiftUI state. Hooked from
        /// `makeNSView`.
        @objc func didEndLiveMagnify(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            onUserZoom(scroll.magnification)
        }

        /// Fires when our ZoomableImageScrollView completes a wheel
        /// zoom (Cmd+scroll). Posted manually by the subclass — see
        /// `wheelZoomDidChangeNotification`.
        @objc func didWheelZoom(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            onUserZoom(scroll.magnification)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ZoomableImageScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.allowsMagnification = true
        // Bounds match ImageZoomState.{min,max}Magnification so direct
        // setMagnification calls and the pure-value-type clamp agree.
        scroll.maxMagnification = ImageZoomState.maxMagnification
        scroll.minMagnification = ImageZoomState.minMagnification
        scroll.drawsBackground = false
        scroll.usesPredominantAxisScrolling = false

        let imageView = CenteredImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scroll.documentView = imageView
        loadIfNeeded(into: imageView, url: url, coord: context.coordinator)
        // Trackpad pinch-to-zoom is handled for free by NSScrollView's
        // own magnify-gesture path because `allowsMagnification = true`.
        // That path already anchors at the gesture's center point.
        // Mousewheel + Cmd is handled by ZoomableImageScrollView's
        // scrollWheel override below.

        // Sync user-driven magnification (pinch or Cmd+scroll) back to
        // SwiftUI state. Two notifications:
        //   - System pinch: NSScrollView posts
        //     `didEndLiveMagnifyNotification` when the gesture ends.
        //   - Cmd+scroll: our subclass posts `wheelZoomDidChange` on
        //     each wheel tick (no system notification for that path).
        context.coordinator.onUserZoom = onUserZoom
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didWheelZoom(_:)),
            name: ZoomableImageScrollView.wheelZoomDidChangeNotification,
            object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Refresh the captured callback so it always sees the latest
        // SwiftUI binding setters.
        context.coordinator.onUserZoom = onUserZoom
        guard let iv = scroll.documentView as? CenteredImageView else { return }
        loadIfNeeded(into: iv, url: url, coord: context.coordinator)
        // SwiftUI side wants magnification = 0 to mean "fit to window".
        if magnification == 0 {
            applyFit(scroll: scroll, imageView: iv)
        } else if abs(scroll.magnification - magnification) > 0.001 {
            // Center the magnification at the viewport midpoint so
            // zoom-in feels anchored.
            let mid = NSPoint(
                x: scroll.contentView.bounds.midX,
                y: scroll.contentView.bounds.midY
            )
            scroll.setMagnification(magnification, centeredAt: mid)
        }
    }

    private func loadIfNeeded(into iv: CenteredImageView, url: URL,
                              coord: Coordinator) {
        if coord.lastURL == url, iv.image != nil { return }
        let fresh = NSImage(contentsOf: url)
        iv.image = fresh
        coord.lastURL = url
        if let img = fresh {
            iv.frame = NSRect(origin: .zero, size: img.size)
            onLoad(img.size)
        }
    }

    private func applyFit(scroll: NSScrollView, imageView: CenteredImageView) {
        guard let img = imageView.image else { return }
        let viewportSize = scroll.contentView.bounds.size
        let imgSize = img.size
        guard imgSize.width > 0 && imgSize.height > 0 else { return }
        let fit = min(viewportSize.width / imgSize.width,
                      viewportSize.height / imgSize.height,
                      1.0)
        scroll.magnification = ImageZoomState.clamped(fit)
        // Center scroll position in the document.
        let docFrame = imageView.frame
        let scrollX = max(0, (docFrame.width - viewportSize.width / fit) / 2)
        let scrollY = max(0, (docFrame.height - viewportSize.height / fit) / 2)
        scroll.contentView.scroll(to: NSPoint(x: scrollX, y: scrollY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// NSScrollView subclass that adds Cmd+scroll-to-zoom on top of the
/// built-in trackpad pinch-magnify. Plain scroll (no modifier) is
/// passed through to the default pan behavior so a zoomed-in image
/// can still be panned with the wheel.
///
/// Zoom anchoring: we convert the wheel event's `locationInWindow`
/// into clip-view coordinates and feed that to
/// `setMagnification(_:centeredAt:)`, which keeps the document point
/// under the cursor stationary across the zoom.
///
/// Range is enforced by NSScrollView's own
/// `minMagnification`/`maxMagnification`, which we set to match
/// `ImageZoomState.{min,max}Magnification` (0.1×–10×).
final class ZoomableImageScrollView: NSScrollView {

    /// Posted on every successful Cmd+scroll-induced magnification
    /// change. There's no system equivalent for the wheel path (only
    /// pinch fires `didEndLiveMagnifyNotification`), so we synthesize
    /// one and the SwiftUI coordinator observes it.
    static let wheelZoomDidChangeNotification = Notification.Name(
        "ZoomableImageScrollView.wheelZoomDidChange")

    /// Tuning constant: how aggressive a single wheel tick is. Empirical
    /// — matches Preview.app's feel within a few percent. Pixel-precise
    /// trackpad scroll events come in many small deltas, so a low gain
    /// here is on purpose.
    private static let wheelZoomGain: CGFloat = 0.0025

    override func scrollWheel(with event: NSEvent) {
        // Only intercept when Cmd is held; otherwise leave default
        // pan-on-wheel behavior intact (matters when image is zoomed
        // in past the viewport).
        guard event.modifierFlags.contains(.command),
              allowsMagnification else {
            super.scrollWheel(with: event)
            return
        }
        // Combine both axes — many mice report on Y, trackpads can
        // produce X too. scrollingDeltaY is the larger-magnitude
        // primary axis on virtually every device.
        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        guard delta != 0 else { return }
        // Floor at a small positive to keep factor strictly > 0 even
        // for a runaway-large negative delta (single high-momentum
        // trackpad tick can easily exceed 400 logical units).
        let factor = max(0.1, 1 + delta * Self.wheelZoomGain)
        let newMag = ImageZoomState.nextMagnification(
            current: magnification, factor: factor)
        guard abs(newMag - magnification) > 0.0001 else { return }
        // Convert cursor position to clip-view (content view) coords.
        // `setMagnification(_:centeredAt:)` interprets its point in
        // content-view coordinates and keeps that point stationary
        // across the zoom — the "anchor under cursor" behavior we want.
        let cursorInClip = contentView.convert(
            event.locationInWindow, from: nil)
        setMagnification(newMag, centeredAt: cursorInClip)
        NotificationCenter.default.post(
            name: Self.wheelZoomDidChangeNotification, object: self)
    }
}

/// NSImageView that draws itself centered inside its enclosing clip
/// view when the magnified image is smaller than the viewport. Stock
/// `NSImageView` left small images stuck to the top-left.
private final class CenteredImageView: NSImageView {
    override var isFlipped: Bool { false }
    override func adjustScroll(_ newVisible: NSRect) -> NSRect {
        // Centering happens via documentView resizing in ImageScrollHost;
        // this override prevents scroll snap-back to (0,0).
        return newVisible
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
