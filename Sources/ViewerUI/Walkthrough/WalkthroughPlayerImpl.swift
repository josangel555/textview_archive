import Foundation
import SwiftUI
import ViewerKit
import ViewerCore

/// `WalkthroughEngineDelegate` that translates engine actions into
/// existing `DocumentModel` mutations + new nonce channels on
/// `WalkthroughBridge`. The engine is pure logic; this is the only
/// place AppKit/SwiftUI is allowed in the walkthrough path.
///
/// Path resolution: action payloads carry path strings that are either
/// absolute or relative to the script's `rootHint`. The loader has
/// already rejected escapes, but the delegate still has to RESOLVE
/// the relative path against `rootHint` to produce a URL. We keep
/// that math local to one helper to avoid scattering `URL(fileURLWithPath:
/// relativeTo:)` calls.
@MainActor
public final class WalkthroughPlayerImpl: WalkthroughEngineDelegate {

    private weak var model: DocumentModel?
    private weak var engine: WalkthroughEngine?

    /// Cached rootHint URL — recomputed on `load`. Holding the URL
    /// (not the string) sidesteps re-standardizing on every action.
    private var rootHint: URL?

    /// Pending awaitUser flag. The engine has no `awaitingUser` state
    /// of its own (intentionally narrow surface); the delegate marks
    /// the engine as paused and the player strip reads this property
    /// to render the await-user prompt + replies.
    public private(set) var pendingAwaitUser: AwaitUserPayload?

    public init(model: DocumentModel, engine: WalkthroughEngine) {
        self.model = model
        self.engine = engine
    }

    /// Cache the script's rootHint at load time. Called by the host
    /// (`WalkthroughPlayerView` / the CLI loader) right before
    /// `engine.load(...)`.
    public func prepare(for script: WalkthroughScript) {
        if let hint = script.rootHint {
            rootHint = URL(fileURLWithPath: hint, isDirectory: true)
                .standardizedFileURL
        } else {
            rootHint = nil
        }
        pendingAwaitUser = nil
    }

    // MARK: - WalkthroughEngineDelegate

    public func walkthroughEngine(
        _ engine: WalkthroughEngine, willApplyStep step: Step
    ) {
        // Clear transient overlays from the prior step. The new step's
        // actions may re-establish them; clearing first means a step
        // that doesn't re-issue a highlight/popover leaves a clean
        // canvas.
        model?.walkthroughBridge.clearPopover()
        model?.walkthroughBridge.clearHighlight()
        model?.walkthroughBridge.clearFlash()
        pendingAwaitUser = nil
    }

    public func walkthroughEngine(
        _ engine: WalkthroughEngine, apply action: Action, in step: Step
    ) {
        guard let model else { return }
        switch action {

        case .openFile(let p):
            // If the URL is already open in a tab, fold "switch tab"
            // into openFile per user decision §4: just select it,
            // don't re-read. Otherwise do a normal open.
            guard let url = resolve(p.path) else { return }
            if !model.selectTab(forURL: url) {
                model.openPath(url)
            }

        case .revealLine(let p):
            // No path = current tab.
            if let pathStr = p.path, let url = resolve(pathStr) {
                if !model.selectTab(forURL: url) { model.openPath(url) }
            }
            model.scrollSource(toLine: p.line)

        case .highlightRange(let p):
            // Resolve the URL: payload-provided or current tab.
            let url: URL?
            if let pathStr = p.path { url = resolve(pathStr) }
            else { url = model.currentURL }
            guard let url else { return }
            if !model.selectTab(forURL: url) { model.openPath(url) }
            // Scroll the start line into view so the highlight isn't
            // off-screen the moment it appears.
            model.scrollSource(toLine: p.startLine)
            model.walkthroughBridge.requestHighlight(
                WalkthroughBridge.HighlightRange(
                    url: url,
                    startLine: p.startLine,
                    endLine: p.endLine,
                    style: p.style ?? .focus
                )
            )

        case .flash(let p):
            // Transient pulse. Resolve URL like highlightRange does:
            // payload path or current tab. Scroll the start line into
            // view so the pulse isn't off-screen when it fires.
            let url: URL?
            if let pathStr = p.path { url = resolve(pathStr) }
            else { url = model.currentURL }
            guard let url else { return }
            if !model.selectTab(forURL: url) { model.openPath(url) }
            model.scrollSource(toLine: p.startLine)
            model.walkthroughBridge.requestFlash(
                WalkthroughBridge.FlashRange(
                    url: url,
                    startLine: p.startLine,
                    endLine: p.endLine,
                    style: p.style ?? .focus,
                    durationMs: p.durationMs
                        ?? WalkthroughBridge.defaultFlashDurationMs
                )
            )

        case .showPopover(let p):
            // Resolve line-anchor URL eagerly so the view doesn't
            // re-do the rootHint math on every observation.
            let anchor = resolvedAnchor(p.anchor)
            model.walkthroughBridge.requestPopover(
                WalkthroughBridge.PopoverRequest(
                    body: p.body, anchor: anchor,
                    style: p.style ?? .floating
                )
            )

        case .setView(let p):
            if let pathStr = p.path, let url = resolve(pathStr) {
                if !model.selectTab(forURL: url) { model.openPath(url) }
            }
            model.setCurrentViewMode(p.mode)

        case .splitFile(let p):
            guard let url = resolve(p.path) else { return }
            // If `alongside` is provided, make sure that file is the
            // primary pane's selected tab before opening the split.
            // Lets a script say "show A on the left, B on the right"
            // without first orchestrating a separate openFile step.
            if let alongsidePath = p.alongside,
               let alongsideURL = resolve(alongsidePath) {
                if !model.selectTab(forURL: alongsideURL) {
                    model.openPath(alongsideURL)
                }
            }
            model.openInSplit(url)

        case .runDiff(let p):
            // v1: surface the repo log for the file (closest existing
            // verb). A real per-commit diff verb is a follow-up — the
            // diff view exists but the per-SHA hook isn't wired.
            if let pathStr = p.path, let url = resolve(pathStr) {
                model.showGitLog(forPath: url, scope: .file)
            } else if let url = model.currentURL {
                model.showGitLog(forPath: url, scope: .file)
            }
            _ = p.sha

        case .awaitUser(let p):
            // The engine knows .playing / .paused / .done; "awaiting
            // user" is modelled here as a paused engine with a
            // payload the player view reads. The view renders the
            // prompt and on user reply calls engine.next() (or
            // resume()).
            pendingAwaitUser = p
            engine.pause()

        case .addBookmark(let p):
            guard let url = resolve(p.path) else { return }
            // `BookmarksStore.add(url:line:)` is already idempotent
            // (returns existing entry if present), so we can skip
            // the open-tab-then-toggle dance the earlier version
            // needed. Open the file anyway for visual continuity —
            // the user expects to see the file they just bookmarked.
            if !model.selectTab(forURL: url) { model.openPath(url) }
            if let line = p.line {
                model.scrollSource(toLine: line)
                model.bookmarksStore.add(url: url, line: line)
                model.publishBookmarksChange()
            } else {
                model.bookmarksStore.add(url: url)
                model.publishBookmarksChange()
            }

        case .revealInSidebar(let p):
            guard let url = resolve(p.path) else { return }
            model.sidebar.isVisible = true
            model.revealInSidebar(url)

        case .openGitPanel(let p):
            // Map the script's GitTab enum to the model's GitPanelTab.
            // Identical names — closed enum on both sides, so the
            // switch is exhaustive at compile time.
            let target: DocumentModel.GitPanelTab
            switch p.tab {
            case .status:  target = .status
            case .log:     target = .log
            case .stash:   target = .stash
            case .trees:   target = .trees
            case .remotes: target = .remotes
            }
            model.sidebar.isVisible = true
            model.showGitPanel(tab: target)

        case .narrateOnly:
            // No side effect. The player view picks up the step's
            // narration via the engine's stepIndex.
            break
        }
    }

    public func walkthroughEngine(
        _ engine: WalkthroughEngine, didApplyStep step: Step
    ) {
        // Player view drives auto-advance based on observed stepIndex
        // change — nothing to do here in v1.
    }

    // MARK: - Path resolution

    /// Resolve a script-supplied path string into a `URL`. Absolute
    /// paths pass through; relative paths are resolved against the
    /// cached `rootHint`. Returns nil only when the path is relative
    /// and no rootHint is set — the loader's path-escape pass already
    /// rejected `..` traversals, so we trust the input here.
    private func resolve(_ path: String) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        guard let root = rootHint else { return nil }
        return root.appendingPathComponent(path)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Resolve any `path` strings inside a `PopoverAnchor` so the view
    /// layer receives absolute URLs. Anchors without a path (editor,
    /// sidebar, gitTab, window) pass through unchanged.
    private func resolvedAnchor(_ anchor: PopoverAnchor) -> PopoverAnchor {
        switch anchor {
        case .line(let path?, let line):
            if let url = resolve(path) {
                return .line(path: url.path, line: line)
            }
            return anchor
        default:
            return anchor
        }
    }
}
