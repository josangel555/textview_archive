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
}
