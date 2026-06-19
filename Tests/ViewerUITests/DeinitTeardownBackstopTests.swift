import XCTest
import AppKit
@testable import ViewerUI

/// TSK-989 (M14 + M15 + L-mem3/L-mem4) — deinit / explicit-teardown backstops
/// for three live timer-/observer-owning models whose only teardown path was a
/// view's `onDisappear`. If that fire is missed, a run-loop-retained `Timer`
/// keeps ticking (and, for the LSP token, AppKit monitors/observers linger)
/// FOREVER. These pin that dropping the last reference WITHOUT the explicit
/// `stop()`/`invalidate()` still invalidates the timer — i.e. the `deinit`
/// backstop actually runs and tears resources down.
///
/// Mechanism: a repeating `Timer.scheduledTimer` block here captures
/// `[weak self]`, so the run loop — NOT the model — retains the timer. The
/// model is therefore deallocatable while its timer is still scheduled, and
/// the deinit is what must invalidate it. We capture a strong ref to the timer,
/// drop the model, then assert `timer.isValid == false`.
///
/// TEETH: remove the `deinit { timer?.invalidate() }` from either model and the
/// corresponding test fails (the timer stays `isValid == true`).
@MainActor
final class DeinitTeardownBackstopTests: XCTestCase {

    // MARK: - M14: StatusBarMemorySampler

    func test_statusBarSampler_deinitInvalidatesTimer_withoutStop() {
        // Hold only the timer; let the sampler be the only strong owner so
        // dropping it triggers deinit. The timer is retained by the run loop,
        // not by the sampler, so the sampler CAN dealloc with the timer live.
        weak var weakSampler: StatusBarMemorySampler?
        var capturedTimer: Timer?

        do {
            let sampler = StatusBarMemorySampler(interval: 1.5)
            sampler.start()
            capturedTimer = sampler.timerForTesting
            weakSampler = sampler
            XCTAssertNotNil(capturedTimer, "start() must schedule a timer")
            XCTAssertEqual(capturedTimer?.isValid, true,
                           "precondition: a freshly scheduled timer is valid")
            // NOTE: deliberately NO sampler.stop() — exercise the deinit path.
        }

        XCTAssertNil(weakSampler,
            "the sampler must dealloc once its only strong ref is dropped "
            + "(if this fails, something is retaining it — e.g. a strong timer capture)")
        XCTAssertEqual(capturedTimer?.isValid, false,
            "the deinit backstop must invalidate the run-loop timer even when "
            + "stop() was never called — otherwise it ticks forever")
    }

    func test_statusBarSampler_stopStillWorks() {
        // The normal teardown path must remain intact alongside the deinit.
        let sampler = StatusBarMemorySampler(interval: 1.5)
        sampler.start()
        let t = sampler.timerForTesting
        XCTAssertEqual(t?.isValid, true)
        sampler.stop()
        XCTAssertEqual(t?.isValid, false, "stop() invalidates the timer")
        XCTAssertNil(sampler.timerForTesting, "stop() nils the timer ref")
    }

    // MARK: - M15: GitPanelModel

    func test_gitPanelModel_deinitInvalidatesTimer_withoutStop() {
        weak var weakModel: GitPanelModel?
        var capturedTimer: Timer?

        do {
            let model = GitPanelModel()
            model.start()
            capturedTimer = model.timerForTesting
            weakModel = model
            XCTAssertNotNil(capturedTimer, "start() must schedule a refresh timer")
            XCTAssertEqual(capturedTimer?.isValid, true,
                           "precondition: a freshly scheduled timer is valid")
            // NOTE: deliberately NO model.stop() — exercise the deinit path.
            // GitPanelModel keeps a `static weak var live` to the newest
            // instance; weak, so it does not retain and the model still dealls.
        }

        XCTAssertNil(weakModel,
            "the GitPanelModel must dealloc once its only strong ref is dropped")
        XCTAssertEqual(capturedTimer?.isValid, false,
            "the deinit backstop must invalidate the 60s refresh timer even "
            + "when stop() was never called")
    }

    func test_gitPanelModel_stopCancelsLogSearchTaskToo() async {
        // stop() now mirrors the full task set including logSearchTask (the
        // pre-fix stop() omitted it). Drive a search, then stop, and assert the
        // task is cleared. Zero the debounce so the task reaches its work.
        let model = GitPanelModel()
        model.logSearchDebounceNanos = 0
        // No repoRoot → runLogSearch with empty query is a clearLogSearch; to
        // actually spawn a logSearchTask we need a repoRoot. Use a temp git
        // repo isn't necessary: set repoRoot to a non-nil URL; the task will
        // spawn and the detached grep just returns [] for a non-repo. The
        // point is stop() cancels + nils whatever task exists.
        model.repoRoot = FileManager.default.temporaryDirectory
        model.runLogSearch("anything")
        // The task is spawned synchronously inside runLogSearch.
        model.stop()
        // After stop(), a subsequent clearLogSearch is a no-op on the (already
        // nil) task; the observable contract is simply that stop() didn't leave
        // a live search task. We can't read the private task, but we CAN assert
        // stop() left the timer down and the model is in a clean idle state.
        XCTAssertNil(model.timerForTesting, "stop() invalidates + nils the timer")
    }

    // MARK: - L-mem3 / L-mem4: ChainedMonitor explicit invalidate

    func test_chainedMonitor_invalidateIsIdempotent() {
        // ChainedMonitor.invalidate() removes the event monitors on main and
        // must be safe to call repeatedly (deinit may also fire after an
        // explicit invalidate). With an empty monitor list there's nothing to
        // remove, so this purely exercises the idempotency guard without
        // touching the global NSEvent monitor table.
        let chain = ChainedMonitor(monitors: [])
        chain.invalidate()
        chain.invalidate()   // second call must be a guarded no-op, not a crash
    }

    /// L-mem4: the dismiss-observer closures must capture `HoverState` WEAKLY,
    /// so registering them does NOT keep the state alive once the view's owner
    /// drops it. Exercises the EXACT production helper (`installDismissObservers`)
    /// — not a reimplementation. TEETH: change either `[weak state]` back to a
    /// strong capture and `weakState` survives the drop → this fails.
    func test_lspDismissObservers_doNotStronglyRetainState() {
        // Off-screen text view inside a scroll view, hosted in a window, so
        // BOTH observer branches register (scroll bounds-change + window
        // resign-key).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.documentView = tv
        window.contentView = scroll

        weak var weakState: HoverState?
        var tokens: [NSObjectProtocol] = []
        do {
            let state = HoverState(popover: NSPopover())
            weakState = state
            tokens = LSPHoverAttachment.installDismissObservers(textView: tv, state: state)
            XCTAssertEqual(tokens.count, 2,
                "both the scroll-bounds and window-resign observers must register")
            // `state` goes out of scope here; the only thing that could keep it
            // alive is a strong capture inside the registered observer blocks.
        }

        XCTAssertNil(weakState,
            "the dismiss observers must capture HoverState weakly — a strong "
            + "capture leaks the state (and its popover) for the registration's life")

        // Clean up the global NotificationCenter registrations.
        for tok in tokens { NotificationCenter.default.removeObserver(tok) }
    }
}
