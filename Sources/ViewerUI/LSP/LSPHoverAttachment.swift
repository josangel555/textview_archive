import AppKit
import SwiftUI
import ViewerCore

/// Production LSP hover + go-to-definition glue for `NSTextView`.
///
/// PoC compromised on Option+mouse-move as the hover trigger to avoid
/// subclassing NSTextView; that bound the feature to a modifier key
/// and surprised users who expected a dwell. The production version
/// uses a **cursor-paused timer (300 ms dwell)**: any time the mouse
/// stops over the text view for 300 ms, we issue a hover request at
/// that point. The choice is documented in `docs/LSP_DESIGN.md` §5.1.
///
/// Lifecycle: caller retains the returned `LSPHoverToken`. The token's
/// `isolated deinit` (Swift 6 SE-0371) removes the tracking area, the
/// event monitors, and any pending dwell task. The token also owns
/// the cancellation token of the most-recent in-flight hover so a fast
/// mouse-move cancels stale work via `$/cancelRequest`.
///
/// Dismiss: NSPopover.behavior = .transient handles Esc + click-outside.
/// We also dismiss on scroll (which moves text under the popover anchor)
/// and on window resign-key.
@MainActor
public final class LSPHoverToken {

    // `nonisolated(unsafe)` so the nonisolated deinit below can
    // read these. The class is `@MainActor`-isolated, but deinit
    // runs nonisolated by default, and Swift 6.3 strict-concurrency
    // refuses to read `@MainActor` properties from nonisolated
    // contexts. SE-0371 `isolated deinit` would solve this cleanly
    // but Swift 6.1 (VM canary) rejects the experimental flag in
    // the production compiler. Marking the fields nonisolated(unsafe)
    // and hopping to MainActor inside the deinit is the portable
    // alternative.
    nonisolated(unsafe) fileprivate let chain: AnyObject
    nonisolated(unsafe) fileprivate let trackingArea: NSTrackingArea
    nonisolated(unsafe) fileprivate weak var textView: NSTextView?
    nonisolated(unsafe) fileprivate var notifTokens: [NSObjectProtocol]

    fileprivate init(
        chain: AnyObject,
        trackingArea: NSTrackingArea,
        textView: NSTextView,
        notifTokens: [NSObjectProtocol]
    ) {
        self.chain = chain
        self.trackingArea = trackingArea
        self.textView = textView
        self.notifTokens = notifTokens
    }

    /// Cleanup hops to MainActor because the AppKit refs require it.
    /// We capture-by-value into the Task so the deinit's own access
    /// to the stored properties is the only nonisolated-unsafe bit;
    /// the Task body runs cleanly on main.
    deinit {
        let tv = textView
        let tracking = trackingArea
        let tokens = notifTokens
        let chainKeepalive = chain
        Task { @MainActor in
            if let tv = tv {
                tv.removeTrackingArea(tracking)
            }
            let center = NotificationCenter.default
            for tok in tokens {
                center.removeObserver(tok)
            }
            _ = chainKeepalive // monitors removed in ChainedMonitor.deinit
        }
    }
}

@MainActor
public enum LSPHoverAttachment {

    /// Bind hover (cursor-paused 300 ms dwell) and Cmd-click → definition
    /// to `textView`. The caller is expected to have already called
    /// `LSPPool.ensureOpened(fileURL:text:)` for the document.
    public static func bind(
        textView: NSTextView,
        fileURL: URL,
        client: LSPClient,
        positionEncoding: LSPPositionEncoding,
        openLocation: @escaping @MainActor (URL, Int, Int) -> Void
    ) -> LSPHoverToken {

        let area = NSTrackingArea(
            rect: textView.bounds,
            options: [.mouseMoved, .mouseEnteredAndExited,
                      .activeInKeyWindow, .inVisibleRect],
            owner: textView,
            userInfo: nil)
        textView.addTrackingArea(area)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false

        let state = HoverState(popover: popover)

        let cmdClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            guard event.modifierFlags.contains(.command),
                  let window = textView.window,
                  event.window === window else { return event }
            let pointInTV = textView.convert(event.locationInWindow, from: nil)
            guard textView.bounds.contains(pointInTV) else { return event }
            guard let (line, col) = lspPosition(
                for: pointInTV, in: textView, encoding: positionEncoding
            ) else { return event }
            Task { @MainActor in
                let token = LSPCancellationToken()
                do {
                    let locs = try await client.definition(
                        url: fileURL, line: line, character: col, token: token)
                    guard let first = locs.first,
                          let target = URL(string: first.uri) else { return }
                    openLocation(target,
                                 first.range.start.line + 1,
                                 first.range.start.character)
                } catch {
                    // Silent — dev diagnostics panel surfaces these.
                }
            }
            return event
        }

        let mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved]
        ) { event in
            guard let window = textView.window,
                  event.window === window else { return event }
            let pointInTV = textView.convert(event.locationInWindow, from: nil)
            guard textView.bounds.contains(pointInTV) else {
                Task { @MainActor in state.cancelDwell() }
                return event
            }
            // Reset the dwell timer.
            Task { @MainActor in
                state.scheduleDwell(at: pointInTV) {
                    Task { @MainActor in
                        await requestHover(
                            point: pointInTV,
                            textView: textView,
                            fileURL: fileURL,
                            client: client,
                            encoding: positionEncoding,
                            state: state)
                    }
                }
            }
            return event
        }

        var notifTokens: [NSObjectProtocol] = []
        if let scrollView = textView.enclosingScrollView {
            let tok = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { _ in
                Task { @MainActor in state.dismiss() }
            }
            notifTokens.append(tok)
        }
        if let window = textView.window {
            let tok = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in state.dismiss() }
            }
            notifTokens.append(tok)
        }

        let chain = ChainedMonitor(monitors: [cmdClickMonitor as Any, mouseMoveMonitor as Any])
        return LSPHoverToken(
            chain: chain,
            trackingArea: area,
            textView: textView,
            notifTokens: notifTokens)
    }

    // MARK: - Internals

    private static func requestHover(
        point: NSPoint,
        textView: NSTextView,
        fileURL: URL,
        client: LSPClient,
        encoding: LSPPositionEncoding,
        state: HoverState
    ) async {
        guard let (line, col) = lspPosition(
            for: point, in: textView, encoding: encoding) else { return }
        state.cancelInflight()
        let token = LSPCancellationToken()
        state.inflight = token
        do {
            guard let hover = try await client.hover(
                url: fileURL, line: line, character: col, token: token
            ) else { return }
            guard state.inflight === token else { return }
            present(hover: hover, at: point, in: textView, state: state)
        } catch {
            // Silent.
        }
    }

    private static func present(
        hover: LSPHover, at point: NSPoint, in textView: NSTextView,
        state: HoverState
    ) {
        let attr = LSPMarkdownRenderer.attributedString(
            from: hover.contents, isMarkdown: hover.isMarkdown)
        let vc = NSViewController()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textStorage?.setAttributedString(attr)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize =
            NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = tv
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!) ?? .zero
        let h = min(max(used.height + 24, 60), 360)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: h))
        scroll.frame = container.bounds
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        vc.view = container

        state.popover.contentViewController = vc
        state.popover.contentSize = NSSize(width: 380, height: h)
        let anchor = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        state.popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
    }

    /// NSTextView point → LSP (line, char) in the negotiated encoding.
    /// Uses `LSPPositionConverter` for the character-count math so we
    /// honor utf-8/16/32 correctly.
    static func lspPosition(
        for point: NSPoint, in textView: NSTextView,
        encoding: LSPPositionEncoding
    ) -> (Int, Int)? {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textView.textContainerOrigin.x,
            y: point.y - textView.textContainerOrigin.y)
        let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        let text = textView.textStorage?.string ?? ""
        guard charIndex <= text.utf16.count else { return nil }
        // String.Index(utf16Offset:in:) is non-failable on macOS 15+;
        // clamp-by-construction is fine here.
        let stringIdx = String.Index(utf16Offset: charIndex, in: text)
        let converter = LSPPositionConverter(text: text, encoding: encoding)
        let pos = converter.lspPosition(for: stringIdx)
        return (pos.line, pos.character)
    }
}

@MainActor
private final class HoverState {
    let popover: NSPopover
    var dwellTask: Task<Void, Never>?
    var inflight: LSPCancellationToken?

    init(popover: NSPopover) { self.popover = popover }

    func scheduleDwell(at _: NSPoint, fire: @escaping @MainActor () -> Void) {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            fire()
        }
    }

    func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    func cancelInflight() {
        inflight?.cancel()
        inflight = nil
    }

    func dismiss() {
        cancelDwell()
        cancelInflight()
        if popover.isShown {
            popover.performClose(nil)
        }
    }
}

/// Holder that removes event monitors when the hover token deinits.
private final class ChainedMonitor {
    let monitors: [Any]
    init(monitors: [Any]) { self.monitors = monitors }
    deinit {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
    }
}
