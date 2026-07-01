import AVKit
import AppKit
import PDFKit
import SwiftUI
import ViewerCore
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
    /// Unified zoom multiplier (`DocumentModel.zoom`). Only the SQLite
    /// browser consumes it today — the image/audio/video/pdf previews
    /// have their own zoom UX — so it defaults to 1.0 for call sites
    /// (e.g. SplitPaneView) that never reach the `.sqlite` arm.
    public let uiScale: CGFloat
    /// Called when the user enters/exits the in-place image editor (TSK-1302), so the host can
    /// suppress the side file-property pane while editing — the full editor needs the width.
    public var onEditingChanged: ((Bool) -> Void)?
    /// TSK-1303: the persisted image edit state to SEED the in-place editor with on
    /// session restore, and a sink to persist edits back so they survive a session
    /// switch. Supplied by the host (`ContentView`, which has the `DocumentModel`);
    /// `nil` disables persistence (e.g. the `SplitPaneView` call site).
    public var initialImageEditState: ImageEditState?
    public var onImageEditStateChanged: ((ImageEditState) -> Void)?

    public init(url: URL, category: FileCategory,
                onOpenSibling: ((URL) -> Void)? = nil,
                uiScale: CGFloat = 1.0,
                onEditingChanged: ((Bool) -> Void)? = nil,
                initialImageEditState: ImageEditState? = nil,
                onImageEditStateChanged: ((ImageEditState) -> Void)? = nil) {
        self.url = url
        self.category = category
        self.onOpenSibling = onOpenSibling
        self.uiScale = uiScale
        self.onEditingChanged = onEditingChanged
        self.initialImageEditState = initialImageEditState
        self.onImageEditStateChanged = onImageEditStateChanged
    }

    /// Point size for preview info chrome (image dimensions, sibling counter,
    /// zoom %, unsupported-file metadata) at a given unified UI zoom. Base 11pt
    /// scales linearly so the metadata tracks the rest of the app chrome —
    /// previously these were hard-wired at 11pt and ignored zoom (TSK-271).
    public static func infoFontSize(uiScale: CGFloat) -> CGFloat { 11 * uiScale }

    public var body: some View {
        // All non-text previews want centered (both axes) content
        // inside the content pane. Each child is an `NSViewRepresentable`
        // wrapping an AppKit view that fills `maxWidth/maxHeight: .infinity`
        // and handles internal centering of small content (image:
        // CenteringClipView in ImageScrollHost; PDF: PDFView's autoScales;
        // AV: AVPlayerView centers natively). The outer `.frame(...)` here
        // guarantees the SwiftUI host gives them the full content rect —
        // without it, AppKit-representables can collapse to their
        // intrinsic size and end up bottom-left in the parent HStack.
        Group {
            switch category {
            case .image: ImagePreview(url: url, onOpenSibling: onOpenSibling, uiScale: uiScale,
                                      onEditingChanged: onEditingChanged,
                                      initialImageEditState: initialImageEditState,
                                      onImageEditStateChanged: onImageEditStateChanged)
            case .audio: AudioPreview(url: url)
            case .video: VideoPreview(url: url)
            case .pdf:   PDFPreview(url: url)
            case .sqlite:
                SQLiteBrowserView(url: url, uiScale: uiScale)
            case .archive:
                // TSK-311: entry listing; opening an entry extracts it to a
                // temp file and routes through the same open hook the image
                // sibling-browser uses.
                ArchiveBrowserView(url: url, uiScale: uiScale, onOpenEntry: onOpenSibling)
            default:
                UnsupportedPreview(url: url, category: category, uiScale: uiScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// Unified UI zoom (`DocumentModel.zoom`); scales the overlay info chrome
    /// (counter / zoom % / dimensions) so it tracks the rest of the app (TSK-271).
    var uiScale: CGFloat = 1.0
    /// Fired when the in-place editor opens/closes (TSK-1302) so the host suppresses the side
    /// file-property pane while editing (the full-width editor needs the room).
    var onEditingChanged: ((Bool) -> Void)?
    /// TSK-1303: persisted image edit state to SEED the in-place editor with (session
    /// restore) + a sink to persist edits back, threaded from the host `DocumentModel`.
    var initialImageEditState: ImageEditState?
    var onImageEditStateChanged: ((ImageEditState) -> Void)?

    @State private var magnification: CGFloat = 1.0
    @State private var pixelSize: NSSize = .zero
    @State private var didFit: Bool = false
    @State private var siblings: [URL] = []
    /// Memo for currentIndex — computed once per (siblings, url) pair
    /// rather than O(N) per body re-eval.
    @State private var currentIndex: Int = 0
    /// Image-editor PoC (TSK-342): toggled from the control bar; overlays the
    /// non-destructive editor on top of the viewer. `MDV_START_IMAGE_EDIT=1`
    /// opens straight into edit mode so a T5 pixel test can validate the editor
    /// without synthesizing a button tap (the toggle is local @State, not
    /// script-reachable).
    @State private var editing =
        ProcessInfo.processInfo.environment["MDV_START_IMAGE_EDIT"] == "1"
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Palette.windowBackground
                .ignoresSafeArea()
            // Drop the opaque NSViewRepresentable from the tree entirely
            // while editing — its CALayer would otherwise composite OVER the
            // SwiftUI editor overlay (the recurring sibling-blank pathology;
            // see LESSONS.md / CLAUDE.md). With it gone, the editor overlay
            // has nothing to be occluded by.
            if !editing {
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
                            },
                            onFit: { fitMag in
                                // Mirror the computed fit-to-window
                                // magnification back into SwiftUI state.
                                // `fitToWindow()` sets magnification = 0
                                // (the "compute fit" sentinel); without
                                // writing the real fit value back, the
                                // state stays at the sentinel and the
                                // next updateNSView pass would snap the
                                // scroll view back, leaving the image at
                                // 100% / overflowing. This also keeps the
                                // % HUD (binds to `magnification`) honest.
                                magnification = fitMag
                            })
            }
            VStack {
                Spacer()
                controlBar
                    .padding(.bottom, 12)
            }
        }
        .overlay {
            if editing {
                ImageEditorView(url: url,
                                initialEditState: initialImageEditState,
                                onEditStateChanged: onImageEditStateChanged) { editing = false }
                    .transition(.opacity)
            }
        }
        .onChange(of: editing) { _, newValue in onEditingChanged?(newValue) }
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
                .helpInfo(title: "Previous image", description: "Show the previous image (←)")
                .disabled(prevURL == nil)
                Text("\(currentIndex + 1) / \(siblings.count)")
                    .font(.system(size: MediaPreviewView.infoFontSize(uiScale: uiScale), design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: { navigate(by: +1) }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .helpInfo(title: "Next image", description: "Show the next image (→)")
                .disabled(nextURL == nil)
                Divider().frame(height: 14)
            }
            Button(action: { zoom(by: 1/1.25) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .helpInfo(title: "Zoom out", description: "Zoom out (↓ or ⌘-)")
            Text(String(format: "%.0f%%", magnification * 100))
                .font(.system(size: MediaPreviewView.infoFontSize(uiScale: uiScale), design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48)
            Button(action: { zoom(by: 1.25) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .helpInfo(title: "Zoom in", description: "Zoom in (↑ or ⌘+)")
            Divider().frame(height: 14)
            Button("Fit") { fitToWindow() }
                .buttonStyle(.borderless)
                .helpInfo(title: "Fit", description: "Fit the image to the window (0 or ⌘0)")
            Button("1:1") { magnification = 1.0 }
                .buttonStyle(.borderless)
                .helpInfo(title: "Actual size", description: "Show the image at 100% (1)")
            if pixelSize.width > 0 {
                Divider().frame(height: 14)
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(.system(size: MediaPreviewView.infoFontSize(uiScale: uiScale), design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Divider().frame(height: 14)
            Button(action: { editing = true }) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .helpInfo(title: "Edit image", description: "Adjust tone, rotate, and export a copy")
            .accessibilityIdentifier("mdv.imagePreview.editButton")
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
    /// Called after a fit-to-window pass computes and applies the fit
    /// magnification, so the SwiftUI side can replace the `0` "compute
    /// fit" sentinel with the real value. Without this the state stays
    /// at the sentinel and the next pass snaps the scroll view back.
    let onFit: (CGFloat) -> Void

    /// Coordinator tracks the loaded URL so we know whether
    /// `updateNSView` actually needs to swap the image. Was using
    /// `NSImage.setName(url.path)` as a cache key — but that name
    /// registers globally in `NSImage.imageNamed(_:)`, collides across
    /// tabs viewing different images, and never frees.
    // @MainActor: the @objc handlers below touch main-actor AppKit state
    // (`NSScrollView.magnification`) and only ever fire from main-thread
    // AppKit notifications. Explicit here so the file compiles on Swift 6.1.x
    // (where the enclosing context is nonisolated by default) as well as on
    // newer toolchains that default this context to the main actor.
    @MainActor
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
        // Replace the stock NSClipView with one that centers the
        // documentView when it's smaller than the viewport (either axis).
        // Without this the image sticks to the bottom-left corner of
        // the clip view — NSScrollView's default clip behavior assumes
        // documents that are at least as large as the viewport, which
        // an image scaled to fit isn't.
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip

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
            if let fit = applyFit(scroll: scroll, imageView: iv) {
                // Mirror the computed fit back into SwiftUI state so the
                // 0 sentinel is replaced and the next pass doesn't snap
                // the scroll view back. Defer to avoid mutating state
                // during the view-update pass.
                DispatchQueue.main.async { onFit(fit) }
            }
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

    /// Computes and applies the fit-to-window magnification, returning
    /// the value applied so the caller can mirror it into SwiftUI state.
    /// Returns `nil` when there's nothing to fit (no image / degenerate
    /// size) so the caller leaves the `0` sentinel untouched and retries
    /// on a later pass once the image/bounds are available.
    @discardableResult
    private func applyFit(scroll: NSScrollView,
                          imageView: CenteredImageView) -> CGFloat? {
        guard let img = imageView.image else { return nil }
        let viewportSize = scroll.contentView.bounds.size
        let imgSize = img.size
        guard imgSize.width > 0 && imgSize.height > 0,
              viewportSize.width > 0 && viewportSize.height > 0 else { return nil }
        // Scale-to-fit (never upscale a small image past 1:1), via the
        // pure helper so view + tests agree on the math.
        let fit = ImageZoomState.fitScale(image: imgSize,
                                           viewport: viewportSize,
                                           allowUpscale: false)
        scroll.magnification = fit
        // Center scroll position in the document. CenteringClipView
        // handles the axes where the doc is smaller than the viewport;
        // this seeds the origin so the larger axis also starts centered.
        let docFrame = imageView.frame.size
        let centered = ImageZoomState.clampPan(
            proposedOrigin: CGPoint(x: (docFrame.width - viewportSize.width / fit) / 2,
                                    y: (docFrame.height - viewportSize.height / fit) / 2),
            viewport: viewportSize,
            docFrame: docFrame,
            magnification: fit)
        scroll.contentView.scroll(to: centered)
        scroll.reflectScrolledClipView(scroll.contentView)
        return fit
    }
}

/// NSScrollView subclass that adds Cmd+scroll-to-zoom on top of the
/// built-in trackpad pinch-magnify, plus click-and-drag-to-pan when the
/// magnified image overflows the viewport. Plain scroll (no modifier)
/// is passed through to the default pan behavior so a zoomed-in image
/// can still be panned with the wheel.
///
/// Zoom anchoring: we convert the wheel event's `locationInWindow`
/// into clip-view coordinates and feed that to
/// `setMagnification(_:centeredAt:)`, which keeps the document point
/// under the cursor stationary across the zoom.
///
/// Pan: a left-button drag scrolls the clip view by the drag delta
/// (converted from screen points to document units via the current
/// magnification), with the resulting origin clamped through
/// `ImageZoomState.clampPan` so the image can't be dragged off-screen.
/// When the document fits entirely within the viewport there's nothing
/// to pan, so the drag is ignored and the event falls through.
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

    /// Clip-view origin captured at `mouseDown`, in document units. Each
    /// `mouseDragged` pans relative to this anchor so accumulated
    /// rounding can't drift.
    private var panAnchorOrigin: CGPoint?

    // MARK: - Drag-to-pan

    /// True only when the scaled document overflows the viewport on at
    /// least one axis — i.e. there is somewhere to pan to.
    private var canPan: Bool {
        guard magnification > 0, let doc = documentView else { return false }
        let visible = contentView.bounds.size  // already in document units
        return doc.frame.width > visible.width + 0.5
            || doc.frame.height > visible.height + 0.5
    }

    override func mouseDown(with event: NSEvent) {
        guard canPan else { super.mouseDown(with: event); return }
        panAnchorOrigin = contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = panAnchorOrigin, magnification > 0,
              let doc = documentView else {
            super.mouseDragged(with: event)
            return
        }
        // Grab-hand semantics (closed-hand cursor): the document point
        // under the cursor stays under the cursor, so the viewport
        // origin moves OPPOSITE to the cursor. Mouse deltas are in
        // screen points; the clip view's bounds are in document units,
        // so divide by magnification to convert. AppKit's
        // `NSEvent.deltaX/deltaY` use the screen-delta convention:
        // `deltaX` positive-rightward, `deltaY` positive-DOWNWARD. The
        // clip view is non-flipped (origin bottom-left, Y up).
        //   - Drag right (dx > 0) → content follows hand right → reveal
        //     content to the LEFT → origin.x shrinks → anchor.x - dx.
        //   - Drag down (dy > 0) → content follows hand down → reveal
        //     content ABOVE → origin.y grows → anchor.y + dy.
        let dx = event.deltaX / magnification
        let dy = event.deltaY / magnification
        let proposed = CGPoint(x: anchor.x - dx, y: anchor.y + dy)
        let clamped = ImageZoomState.clampPan(
            proposedOrigin: proposed,
            viewport: contentView.bounds.size,
            docFrame: doc.frame.size,
            magnification: magnification)
        contentView.scroll(to: clamped)
        reflectScrolledClipView(contentView)
        panAnchorOrigin = clamped
    }

    override func mouseUp(with event: NSEvent) {
        if panAnchorOrigin != nil {
            panAnchorOrigin = nil
            NSCursor.arrow.set()
        } else {
            super.mouseUp(with: event)
        }
    }

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
        // Centering happens via CenteringClipView's bounds override
        // (below); this hook prevents scroll snap-back to (0,0).
        return newVisible
    }
}

/// NSClipView that centers its documentView when the document is
/// smaller than the visible rect on either axis. The default
/// `constrainBoundsRect` clamps the bounds origin to the document's
/// rect, so a small document ends up wedged in the lower-left of the
/// clip (origin.x == origin.y == 0). Shifting the bounds origin
/// negative pulls the doc visually to the center of the clip.
///
/// This is the canonical "centered image viewer" pattern in AppKit
/// and the only correct fix — neither resizing the documentView nor
/// overriding `adjustScroll` on the documentView achieves the same
/// effect across both fit-to-window and pinch-to-zoom-out.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        let docFrame = docView.frame
        if rect.size.width > docFrame.size.width {
            rect.origin.x = (docFrame.size.width - rect.size.width) / 2.0
        }
        if rect.size.height > docFrame.size.height {
            rect.origin.y = (docFrame.size.height - rect.size.height) / 2.0
        }
        return rect
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Audio preview: the system transport (AVPlayerView) plus a control bar with a
/// "waveform" affordance that opens the `AudioEditorView` visualization (TSK-529).
/// While editing we DROP the opaque `AudioPlayerHost` representable entirely —
/// the editor draws its own SwiftUI `Canvas` waveform and runs its own
/// `AVAudioPlayer` transport — so the representable's CALayer can't composite
/// OVER the editor (the recurring sibling-blank pathology; see LESSONS.md). Same
/// guard ImagePreview uses for its image editor.
private struct AudioPreview: View {
    let url: URL
    /// `MDV_START_AUDIO_EDIT=1` opens straight into the visualization so a T5
    /// pixel test can validate the editor without synthesizing a button tap
    /// (the toggle is local @State, not script-reachable). Mirrors
    /// `MDV_START_IMAGE_EDIT`.
    @State private var editing =
        ProcessInfo.processInfo.environment["MDV_START_AUDIO_EDIT"] == "1"

    var body: some View {
        ZStack {
            Palette.windowBackground.ignoresSafeArea()
            if !editing {
                AudioPlayerHost(url: url)
                VStack {
                    Spacer()
                    controlBar.padding(.bottom, 12)
                }
            }
        }
        .overlay {
            if editing {
                // ffmpeg path (for MP3 export) comes from Settings; nil ⇒
                // FFmpegLocator auto-discovery. Read directly from the prefs
                // store — the only audio-export consumer — to keep this
                // self-contained without threading DocumentModel through the
                // public MediaPreviewView API (TSK-535).
                AudioEditorView(url: url,
                                ffmpegPath: PreferencesStore().audioFFmpegPath) {
                    editing = false
                }
                .transition(.opacity)
            }
        }
        .accessibilityIdentifier("mdv.audioPreview")
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button(action: { editing = true }) {
                Image(systemName: "waveform")
            }
            .buttonStyle(.borderless)
            .helpInfo(title: "Waveform & editing",
                      description: "Show the waveform with zoom, scale, and transport")
            .accessibilityIdentifier("mdv.audioPreview.editButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
    }
}

/// AppKit hosting layer for the system audio transport. Opaque representable —
/// kept out of the SwiftUI tree while the editor overlay is up (see AudioPreview).
/// Internal (not private) so the TSK-1308 integration test can host it and assert it
/// binds to the app-level persistent controller (music survives session/tab switch).
struct AudioPlayerHost: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        // TSK-1308: bind to the app-level persistent player so audio survives a
        // session/tab switch (view teardown) instead of being deallocated here.
        v.player = AudioPlaybackController.shared.player(for: url)
        v.controlsStyle = .default
        v.showsFullScreenToggleButton = false  // not meaningful for audio
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Re-bind to the persistent player; `player(for:)` reuses the live player for
        // an unchanged URL (no playback yank) and replaces it for a new one.
        let p = AudioPlaybackController.shared.player(for: url)
        if nsView.player !== p { nsView.player = p }
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
    /// Unified UI zoom (`DocumentModel.zoom`) — scales the metadata card so the
    /// file info tracks the rest of the app chrome (TSK-271).
    var uiScale: CGFloat = 1.0
    var body: some View {
        VStack(spacing: 10 * uiScale) {
            Image(systemName: "doc.questionmark")
                .resizable().scaledToFit()
                .frame(width: 48 * uiScale, height: 48 * uiScale)
                .foregroundStyle(.secondary)
            Text("Preview not available for \(category.rawValue)")
                .font(.system(size: MediaPreviewView.infoFontSize(uiScale: uiScale)))
            Text(url.lastPathComponent)
                .font(.system(size: MediaPreviewView.infoFontSize(uiScale: uiScale), design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
