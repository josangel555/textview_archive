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
/// Lifecycle: caller retains the returned `LSPHoverToken` and SHOULD call
/// `invalidate()` (on the main actor) when the editor it's attached to goes
/// away — that synchronously removes the tracking area, the event monitors,
/// the NotificationCenter observers, and any pending dwell task. The token
/// also owns the cancellation token of the most-recent in-flight hover so a
/// fast mouse-move cancels stale work via `$/cancelRequest`.
///
/// The `deinit` is a LAST-RESORT BACKSTOP only: it defers cleanup onto an
/// unstructured `Task { @MainActor }` (the AppKit refs require the main
/// actor, and `deinit` runs nonisolated), which may never run — the process
/// can exit, or the task can be starved — so observers/monitors can leak if
/// the caller relies on it. RC fix (TSK-963): callers invoke `invalidate()`
/// explicitly; `deinit` only mops up a token the caller forgot to release.
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
    nonisolated(unsafe) fileprivate let chain: ChainedMonitor
    nonisolated(unsafe) fileprivate let trackingArea: NSTrackingArea
    nonisolated(unsafe) fileprivate weak var textView: NSTextView?
    nonisolated(unsafe) fileprivate var notifTokens: [NSObjectProtocol]
    /// Latch so `invalidate()` is idempotent and `deinit`'s backstop never
    /// double-removes after an explicit teardown. `nonisolated(unsafe)` for
    /// the same reason as the fields above — the deinit reads it to decide
    /// whether the backstop work is still needed.
    nonisolated(unsafe) fileprivate var isInvalidated = false

    fileprivate init(
        chain: ChainedMonitor,
        trackingArea: NSTrackingArea,
        textView: NSTextView,
        notifTokens: [NSObjectProtocol]
    ) {
        self.chain = chain
        self.trackingArea = trackingArea
        self.textView = textView
        self.notifTokens = notifTokens
    }

    #if DEBUG
    /// Test-only factory (TSK-963): build a token over an injected
    /// `NSTextView` + tracking area + real NotificationCenter observer
    /// tokens + an empty `ChainedMonitor`, so the host gate can pin
    /// `invalidate()`'s idempotence + cleanup without spawning an LSP server
    /// or opening a window. The NSTextView/tracking-area are real AppKit
    /// objects (headless-safe: `removeTrackingArea` needs no window/screen).
    static func _makeForTesting(
        textView: NSTextView,
        trackingArea: NSTrackingArea,
        notifTokens: [NSObjectProtocol]
    ) -> LSPHoverToken {
        LSPHoverToken(
            chain: ChainedMonitor(monitors: []),
            trackingArea: trackingArea,
            textView: textView,
            notifTokens: notifTokens)
    }

    /// Test-only observability: has `invalidate()` run?
    var _isInvalidatedForTesting: Bool { isInvalidated }
    /// Test-only observability: count of NotificationCenter observer tokens
    /// the token still holds (0 after `invalidate()`).
    var _notifTokenCountForTesting: Int { notifTokens.count }
    /// Test-only observability: does the token still reference its textView?
    var _hasTextViewForTesting: Bool { textView != nil }
    #endif

    /// Synchronously tear down everything this token owns: the tracking
    /// area, the NotificationCenter block observers, and the event
    /// monitors (via the chain). Idempotent — a second call is a no-op.
    /// Callers wire this into the editor-teardown path so cleanup happens
    /// deterministically on the main actor rather than waiting on the
    /// deferred-`Task` backstop in `deinit` (which may never run). (TSK-963.)
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if let tv = textView {
            tv.removeTrackingArea(trackingArea)
        }
        textView = nil
        let center = NotificationCenter.default
        for tok in notifTokens {
            center.removeObserver(tok)
        }
        notifTokens = []
        chain.removeAll()
    }

    /// LAST-RESORT BACKSTOP. If the caller never called `invalidate()`,
    /// defer the teardown onto the main actor (the AppKit refs require it,
    /// and `deinit` is nonisolated). This Task may never run — process
    /// exit / starvation — which is exactly why callers must prefer
    /// `invalidate()`. We capture-by-value so the deinit's own access to
    /// the stored properties is the only nonisolated-unsafe bit.
    deinit {
        if isInvalidated { return }
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
            chainKeepalive.removeAll()
        }
    }
}

@MainActor
public enum LSPHoverAttachment {

    /// Bind hover (cursor-paused 300 ms dwell) and Cmd-click → definition
    /// to `textView`. The caller is expected to have already called
    /// `LSPPool.ensureOpened(fileURL:text:)` for the document.
    ///
    /// `pool` is optional but required for the right-click "Go to …"
    /// submenu — references, declaration, typeDefinition, implementation
    /// route through the pool so per-server telemetry is recorded.
    /// Skip if you only need hover + Cmd-click.
    public static func bind(
        textView: NSTextView,
        fileURL: URL,
        client: LSPClient,
        positionEncoding: LSPPositionEncoding,
        openLocation: @escaping @MainActor (URL, Int, Int) -> Void,
        pool: LSPPool? = nil,
        navigationStore: LSPNavigationStore? = nil
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

        // Right-click monitor — pops a "Go to …" / "Find References"
        // submenu at the cursor position. Falls back gracefully when
        // `pool` isn't supplied (legacy callers).
        let rightClickMonitor: Any? = (pool != nil) ? NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown]
        ) { event in
            guard let window = textView.window,
                  event.window === window else { return event }
            let pointInTV = textView.convert(event.locationInWindow, from: nil)
            guard textView.bounds.contains(pointInTV) else { return event }
            guard let (line, col) = lspPosition(
                for: pointInTV, in: textView, encoding: positionEncoding
            ) else { return event }
            // Build + post a menu synchronously. The selectors hop to
            // an async Task internally for the LSP request.
            let menu = makeNavigationMenu(
                fileURL: fileURL, line: line, character: col,
                pool: pool!, store: navigationStore,
                openLocation: openLocation)
            NSMenu.popUpContextMenu(menu, with: event, for: textView)
            // Returning nil suppresses the default text-view context
            // menu — we've shown our own, which is the better UX for
            // an LSP-aware view.
            return nil
        } : nil

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
            // RC fix (TSK-963): capture `state` weakly. A strong capture
            // kept the HoverState (and its NSPopover) alive for as long as
            // the observer registration lived — and the observer was only
            // removed via the deferred-Task deinit, which may never run.
            let tok = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in state?.dismiss() }
            }
            notifTokens.append(tok)
        }
        if let window = textView.window {
            let tok = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in state?.dismiss() }
            }
            notifTokens.append(tok)
        }

        var monitors: [Any] = [cmdClickMonitor as Any, mouseMoveMonitor as Any]
        if let rc = rightClickMonitor { monitors.append(rc) }
        let chain = ChainedMonitor(monitors: monitors)
        return LSPHoverToken(
            chain: chain,
            trackingArea: area,
            textView: textView,
            notifTokens: notifTokens)
    }

    // MARK: - Navigation context menu

    /// Build the right-click "Go to …" submenu. Each item issues an
    /// LSP request through the pool, then either jumps to the single
    /// result or hands the multi-result list to the navigation panel.
    private static func makeNavigationMenu(
        fileURL: URL, line: Int, character: Int,
        pool: LSPPool, store: LSPNavigationStore?,
        openLocation: @escaping @MainActor (URL, Int, Int) -> Void
    ) -> NSMenu {
        let menu = NSMenu(title: "LSP")
        menu.addItem(
            navItem(title: "Go to Definition",
                    action: { token in
                try await pool.definition(
                    fileURL: fileURL, line: line, character: character,
                    token: token)
            }, store: store, originLabel: "Definition", openLocation: openLocation))
        menu.addItem(
            navItem(title: "Go to Declaration",
                    action: { token in
                try await pool.declaration(
                    fileURL: fileURL, line: line, character: character,
                    token: token)
            }, store: store, originLabel: "Declaration", openLocation: openLocation))
        menu.addItem(
            navItem(title: "Go to Type Definition",
                    action: { token in
                try await pool.typeDefinition(
                    fileURL: fileURL, line: line, character: character,
                    token: token)
            }, store: store, originLabel: "Type Definition", openLocation: openLocation))
        menu.addItem(
            navItem(title: "Go to Implementation",
                    action: { token in
                try await pool.implementation(
                    fileURL: fileURL, line: line, character: character,
                    token: token)
            }, store: store, originLabel: "Implementation", openLocation: openLocation))
        menu.addItem(.separator())
        menu.addItem(
            navItem(title: "Find References",
                    action: { token in
                try await pool.references(
                    fileURL: fileURL, line: line, character: character,
                    includeDeclaration: true, token: token)
            }, store: store, originLabel: "References at \(fileURL.lastPathComponent):\(line + 1)",
                    openLocation: openLocation,
                    forceListView: true))
        return menu
    }

    /// One menu item that runs `action` and either jumps (single
    /// result) or populates the navigation panel (multi-result).
    private static func navItem(
        title: String,
        action: @escaping @Sendable (LSPCancellationToken) async throws -> [LSPLocation],
        store: LSPNavigationStore?,
        originLabel: String,
        openLocation: @escaping @MainActor (URL, Int, Int) -> Void,
        forceListView: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let handler = NavMenuHandler(
            run: action, store: store, originLabel: originLabel,
            openLocation: openLocation, forceListView: forceListView)
        item.target = handler
        item.action = #selector(NavMenuHandler.invoke(_:))
        item.representedObject = handler  // retain
        return item
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

/// Holder for the hover token's local event monitors. Teardown is
/// `@MainActor`-isolated (TSK-963): `NSEvent.removeMonitor(_:)` must run on
/// the main thread, but `deinit` is nonisolated by default — the old version
/// removed monitors directly from the nonisolated deinit, off the main actor.
/// `removeAll()` is the explicit, idempotent teardown the token's
/// `invalidate()` calls synchronously; the deferred-Task `deinit` is the
/// last-resort backstop for a token whose `invalidate()` was never called.
@MainActor
fileprivate final class ChainedMonitor {
    nonisolated(unsafe) private var monitors: [Any]
    init(monitors: [Any]) { self.monitors = monitors }

    /// Remove every retained event monitor. Idempotent: clears the array so
    /// a second call (e.g. backstop deinit after an explicit `invalidate()`)
    /// is a no-op.
    func removeAll() {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
        monitors = []
    }

    /// Backstop only — `LSPHoverToken.invalidate()` should have already
    /// called `removeAll()` on the main actor. If it didn't, defer the
    /// removal onto the main actor (it may never run; that's the leak the
    /// explicit teardown closes).
    deinit {
        let pending = monitors
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            for m in pending {
                NSEvent.removeMonitor(m)
            }
        }
    }
}

/// Bridge object for the right-click navigation menu items. NSMenuItem
/// needs an `@objc` target/action; we can't use a closure directly, so
/// we wrap one. The item retains the handler via `representedObject`.
@MainActor
private final class NavMenuHandler: NSObject {
    typealias Action = @Sendable (LSPCancellationToken) async throws -> [LSPLocation]
    let run: Action
    weak var store: LSPNavigationStore?
    let originLabel: String
    let openLocation: @MainActor (URL, Int, Int) -> Void
    let forceListView: Bool

    init(
        run: @escaping Action,
        store: LSPNavigationStore?,
        originLabel: String,
        openLocation: @escaping @MainActor (URL, Int, Int) -> Void,
        forceListView: Bool
    ) {
        self.run = run
        self.store = store
        self.originLabel = originLabel
        self.openLocation = openLocation
        self.forceListView = forceListView
    }

    @MainActor @objc func invoke(_ sender: Any?) {
        let run = self.run
        let originLabel = self.originLabel
        let openLocation = self.openLocation
        let forceListView = self.forceListView
        let store = self.store
        Task { @MainActor in
            let token = LSPCancellationToken()
            do {
                let locs = try await run(token)
                if locs.isEmpty { return }
                if forceListView || locs.count > 1 {
                    store?.setReferences(originLabel: originLabel, locations: locs)
                } else if let first = locs.first,
                          let url = URL(string: first.uri) {
                    openLocation(
                        url,
                        first.range.start.line + 1,
                        first.range.start.character)
                }
            } catch {
                // Silent — surfaces via the diagnostics panel.
            }
        }
    }
}
