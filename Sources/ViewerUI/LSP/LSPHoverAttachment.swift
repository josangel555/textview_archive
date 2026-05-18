import AppKit
import SwiftUI
import ViewerCore

/// PoC LSP hover + go-to-definition glue for `SourceTextController`.
///
/// Why a separate attachment rather than threading params through
/// `TextDisplayView`? `TextDisplayView` already has 11 constructor
/// arguments and a thicket of nonces. Bolting LSP on as a free
/// function that attaches handlers to the underlying `NSTextView`
/// keeps the PoC isolated — easy to delete if we abandon, easy to
/// inline if we ship.
///
/// Caller (e.g. `ContentView`) constructs the client once per file
/// URL via `LSPHoverAttachment.bind(controller:fileURL:client:)` and
/// retains the returned token to keep observers alive.
@MainActor
public final class LSPHoverToken {
    // Holds the event-monitor tokens + tracking area so they live as
    // long as the caller retains the token. Monitors are removed in
    // the inner `ChainedMonitor.deinit`; the tracking area is removed
    // here.
    private let chain: AnyObject
    private let trackingArea: NSTrackingArea
    private weak var textView: NSTextView?
    fileprivate init(chain: AnyObject, trackingArea: NSTrackingArea, textView: NSTextView) {
        self.chain = chain
        self.trackingArea = trackingArea
        self.textView = textView
    }
    // `isolated deinit` keeps cleanup on the MainActor (Swift 6.1+).
    // Required because `NSTrackingArea` is non-Sendable and a default
    // `nonisolated` deinit can't access main-actor state.
    isolated deinit {
        textView?.removeTrackingArea(trackingArea)
        _ = chain // retain until deinit; ChainedMonitor cleans up monitors
    }
}

@MainActor
public enum LSPHoverAttachment {

    /// Wire up:
    ///   - mouse-move → debounce → `textDocument/hover` → NSPopover
    ///   - Cmd+leftMouseDown → `textDocument/definition` → caller open
    ///
    /// `openLocation` is invoked on the main actor with the resolved
    /// (file URL, 1-based line, 0-based character) tuple. Caller is
    /// expected to surface it in their tab/window opener.
    public static func bind(
        textView: NSTextView,
        fileURL: URL,
        client: LSPClient,
        openLocation: @escaping @MainActor (URL, Int, Int) -> Void
    ) -> LSPHoverToken {

        // Tracking area so we get continuous mouseMoved events even
        // when our view isn't first responder. .activeInKeyWindow keeps
        // it lightweight; PoC scope doesn't need .activeAlways.
        let area = NSTrackingArea(
            rect: textView.bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: textView,
            userInfo: nil)
        textView.addTrackingArea(area)

        // Local event monitor for Cmd-click. Returning the event keeps
        // normal selection behavior intact.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard event.modifierFlags.contains(.command),
                  let window = textView.window,
                  event.window === window else { return event }
            let pointInTV = textView.convert(event.locationInWindow, from: nil)
            guard textView.bounds.contains(pointInTV) else { return event }
            if let (line, col) = positionForPoint(pointInTV, in: textView) {
                Task { @MainActor in
                    do {
                        let locs = try await client.definition(
                            url: fileURL, line: line, character: col)
                        guard let first = locs.first,
                              let target = URL(string: first.uri) else { return }
                        // LSP lines are 0-based; presenter uses 1-based.
                        openLocation(target, first.range.start.line + 1, first.range.start.character)
                    } catch {
                        // PoC: silently swallow. Real impl would HUD.
                    }
                }
            }
            return event
        }

        // Hover popover state — recreated per request to keep this
        // demo trivially correct. Wraps a 320-pt-wide markdown view.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false

        // Mouse-move handler. We can't easily subclass NSTextView from
        // here, so we observe via a notification posted by AppKit on
        // `.mouseMoved` events delivered to the tracking area. The
        // tracking area's owner is the textView itself; mouseMoved
        // lands on its `mouseMoved(_:)` override (which by default does
        // nothing). We approximate via a periodic poll on Cmd-key
        // state in a global event monitor instead — cheaper than
        // subclassing for a PoC. See FINDINGS for a follow-up note.
        //
        // PoC compromise: hover is triggered by holding Option (⌥) and
        // moving the mouse. This dodges the NSTextView subclass
        // requirement without intercepting normal text selection.
        var lastRequest: (line: Int, col: Int)?
        var debounceTask: Task<Void, Never>?

        let moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            guard event.modifierFlags.contains(.option),
                  let window = textView.window,
                  event.window === window else { return event }
            let pointInTV = textView.convert(event.locationInWindow, from: nil)
            guard textView.bounds.contains(pointInTV),
                  let (line, col) = positionForPoint(pointInTV, in: textView) else {
                return event
            }
            // Debounce same-position fire.
            if let last = lastRequest, last.line == line, last.col == col { return event }
            lastRequest = (line, col)

            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                do {
                    guard let hover = try await client.hover(
                        url: fileURL, line: line, character: col) else { return }
                    presentHover(
                        hover: hover, at: pointInTV, in: textView, popover: popover)
                } catch {
                    // PoC: ignore
                }
            }
            return event
        }

        // Bundle both monitors under one token by chaining the deinit.
        let chain = ChainedMonitor(monitors: [monitor as Any, moveMonitor as Any])
        return LSPHoverToken(chain: chain, trackingArea: area, textView: textView)
    }

    // MARK: - Geometry

    /// Translate an `NSTextView`-local point to a 0-based `(line, char)`
    /// LSP position. Character is in UTF-16 code units **within the
    /// line**, matching the spec default position-encoding.
    static func positionForPoint(_ point: NSPoint, in textView: NSTextView) -> (Int, Int)? {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer else { return nil }
        // Convert from textView coords to text-container coords.
        let containerPoint = NSPoint(
            x: point.x - textView.textContainerOrigin.x,
            y: point.y - textView.textContainerOrigin.y)
        let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        let storage = textView.textStorage?.string ?? ""
        let utf16 = storage.utf16
        // Walk the string to find (line, utf16-col).
        var line = 0
        var lastLineStartUTF16 = 0
        var utf16Pos = 0
        for (i, ch) in storage.enumerated() {
            if i == charIndex { break }
            utf16Pos += ch.utf16.count
            if ch == "\n" {
                line += 1
                lastLineStartUTF16 = utf16Pos
            }
        }
        // Convert charIndex (NSString/UTF-16 units) explicitly. The
        // loop above is grapheme-based; we re-compute on UTF-16 to
        // avoid drift on emoji / combining marks.
        let asUTF16Index = utf16.index(utf16.startIndex, offsetBy: charIndex)
        // Find newline before charIndex in UTF-16 space.
        var line2 = 0
        var lineStart16 = utf16.startIndex
        var idx = utf16.startIndex
        while idx < asUTF16Index {
            if utf16[idx] == 0x000A /* \n */ {
                line2 += 1
                lineStart16 = utf16.index(after: idx)
            }
            idx = utf16.index(after: idx)
        }
        let col16 = utf16.distance(from: lineStart16, to: asUTF16Index)
        _ = (line, lastLineStartUTF16) // silence unused-var warning
        return (line2, col16)
    }

    // MARK: - Hover presentation

    static func presentHover(
        hover: LSPHover, at point: NSPoint, in textView: NSTextView,
        popover: NSPopover
    ) {
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

        // Cheap markdown → attributed. Full fidelity is a polish item;
        // PoC just shows the raw text so the loop is verifiable.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        tv.textStorage?.setAttributedString(
            NSAttributedString(string: hover.contents, attributes: attrs))

        scroll.documentView = tv
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        scroll.frame = container.bounds
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        vc.view = container

        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 360, height: 200)

        let anchorRect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxY)
    }
}

/// Tiny holder so the token's deinit removes both Cmd-click and
/// mouse-move monitors. The token's `monitor` is held as `Any?`; we
/// stash a class that releases both.
private final class ChainedMonitor {
    let monitors: [Any]
    init(monitors: [Any]) { self.monitors = monitors }
    deinit {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
    }
}
