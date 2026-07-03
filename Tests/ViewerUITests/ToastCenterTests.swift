import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1436 — the shared toast + long-operation progress center. Host tests
/// drive a private instance with a FAKE clock (expiry is deterministic) and
/// pin: posting/dismissal, the visible cap, action wiring, sweep expiry,
/// operation begin/update/end (failure ALWAYS surfaces the reason as an error
/// toast), and the cancel hook. The overlay rendering is the VM tail.
@MainActor
final class ToastCenterTests: XCTestCase {

    /// Center on a controllable clock (nanoseconds).
    private func makeCenter(now: @escaping () -> UInt64) -> ToastCenter {
        ToastCenter(now: now)
    }

    // MARK: - Posting + expiry

    func test_post_appendsToastWithKindMessageDetail() {
        let center = makeCenter(now: { 0 })
        center.post(.error, "Convert failed", detail: "unsupported codec")
        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts[0].kind, .error)
        XCTAssertEqual(center.toasts[0].message, "Convert failed")
        XCTAssertEqual(center.toasts[0].detail, "unsupported codec")
    }

    func test_expiry_errorOutlivesInfo() {
        XCTAssertGreaterThan(
            ToastCenter.defaultTTL(for: .error),
            ToastCenter.defaultTTL(for: .info),
            "errors carry the reason — they must linger longer")
    }

    func test_sweep_prunesOnlyExpiredToasts() {
        var fakeNow: UInt64 = 0
        let center = makeCenter(now: { fakeNow })
        center.post(.info, "short", ttl: 1)     // expires at 1s
        center.post(.error, "long", ttl: 10)    // expires at 10s
        XCTAssertEqual(center.toasts.count, 2)

        fakeNow = 2_000_000_000  // 2s
        center.sweep()
        XCTAssertEqual(center.toasts.map(\.message), ["long"],
            "only the expired toast is pruned")

        fakeNow = 11_000_000_000  // 11s
        center.sweep()
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func test_cap_dropsOldestBeyondMaxVisible() {
        let center = makeCenter(now: { 0 })
        for i in 0..<(ToastCenter.maxVisibleToasts + 2) {
            center.post(.info, "t\(i)")
        }
        XCTAssertEqual(center.toasts.count, ToastCenter.maxVisibleToasts,
            "a failure burst must not wallpaper the screen")
        XCTAssertEqual(center.toasts.first?.message, "t2", "FIFO: oldest dropped")
    }

    // MARK: - Actions

    func test_runAction_invokesOnceAndDismisses() {
        let center = makeCenter(now: { 0 })
        var fired = 0
        let id = center.post(.success, "Pasted as Markdown",
                             actionLabel: "Undo", action: { fired += 1 })
        XCTAssertEqual(center.toasts[0].actionLabel, "Undo")
        center.runAction(for: id)
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(center.toasts.isEmpty, "acting dismisses the toast")
        center.runAction(for: id)
        XCTAssertEqual(fired, 1, "action can't be re-fired after dismissal")
    }

    func test_actionLabelWithoutHandler_isDropped() {
        let center = makeCenter(now: { 0 })
        center.post(.info, "no handler", actionLabel: "Undo", action: nil)
        XCTAssertNil(center.toasts[0].actionLabel,
            "a button with no handler would be a dead control")
    }

    func test_dismiss_removesToastAndAction() {
        let center = makeCenter(now: { 0 })
        var fired = 0
        let id = center.post(.info, "bye", actionLabel: "Do", action: { fired += 1 })
        center.dismiss(id)
        XCTAssertTrue(center.toasts.isEmpty)
        XCTAssertFalse(center._test_hasAction(for: id), "handler released on dismiss")
        XCTAssertEqual(fired, 0)
    }

    // MARK: - Long operations

    func test_operation_beginUpdateEnd_success() {
        let center = makeCenter(now: { 0 })
        let id = center.beginOperation("Converting image…", fraction: 0)
        XCTAssertEqual(center.operations.count, 1)
        XCTAssertEqual(center.operations[0].title, "Converting image…")
        XCTAssertFalse(center.operations[0].isCancellable)

        center.updateOperation(id, fraction: 0.5)
        XCTAssertEqual(center.operations[0].fraction, 0.5)
        center.updateOperation(id, fraction: 7)
        XCTAssertEqual(center.operations[0].fraction, 1, "fraction clamps to 0…1")

        center.endOperation(id, outcome: .success("Converted"))
        XCTAssertTrue(center.operations.isEmpty)
        XCTAssertEqual(center.toasts.map(\.kind), [.success],
            "explicit success message becomes a success toast")
    }

    func test_operation_failure_alwaysSurfacesReasonAsErrorToast() {
        let center = makeCenter(now: { 0 })
        let id = center.beginOperation("Cross-file search")
        center.endOperation(id, outcome: .failure("folder unreadable"))
        XCTAssertTrue(center.operations.isEmpty)
        XCTAssertEqual(center.toasts.count, 1)
        XCTAssertEqual(center.toasts[0].kind, .error)
        XCTAssertEqual(center.toasts[0].message, "Cross-file search failed")
        XCTAssertEqual(center.toasts[0].detail, "folder unreadable",
            "the failure REASON is the whole point — never a silent drop")
    }

    func test_operation_cancelled_endsQuietly() {
        let center = makeCenter(now: { 0 })
        let id = center.beginOperation("Big CSV load", onCancel: {})
        center.endOperation(id, outcome: .cancelled)
        XCTAssertTrue(center.operations.isEmpty)
        XCTAssertTrue(center.toasts.isEmpty, "the user cancelled; they already know")
    }

    func test_requestCancel_invokesHook_operationStaysUntilOwnerEnds() {
        let center = makeCenter(now: { 0 })
        var cancelled = false
        let id = center.beginOperation("Search", onCancel: { cancelled = true })
        XCTAssertTrue(center.operations[0].isCancellable)
        center.requestCancel(id)
        XCTAssertTrue(cancelled, "cancel hook fired")
        XCTAssertEqual(center.operations.count, 1,
            "cancellation is async — the engine confirms via endOperation")
        center.endOperation(id, outcome: .cancelled)
        XCTAssertFalse(center._test_hasCancelHandler(for: id))
    }

    // MARK: - Integration: feed refresh failures surface (TSK-1436 wiring)

    private struct FailingFetcher: FeedFetching {
        /// Returns feeds only for the URLs it has — the rest "fail".
        let feeds: [URL: Feed]
        func refreshAll(_ urls: [URL]) async -> [URL: Feed] {
            feeds.filter { urls.contains($0.key) }
        }
    }

    func test_feedRefresh_failuresPostErrorToast_withFeedNames() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-toast-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = FeedSubscriptionStore(
            subscriptionsURL: tmp.appendingPathComponent("feeds.json"),
            readStateURL: tmp.appendingPathComponent("read.json"))
        let ok = URL(string: "https://good.example/feed")!
        let bad = URL(string: "https://down.example/feed")!
        _ = store.subscribe(url: ok, title: "Good")
        _ = store.subscribe(url: bad, title: "Down")

        let center = makeCenter(now: { 0 })
        let feed = Feed(title: "Good", siteURL: nil, items: [])
        let vm = FeedReaderViewModel(
            store: store, fetcher: FailingFetcher(feeds: [ok: feed]), toasts: center)

        await vm.refresh(now: Date())
        XCTAssertEqual(center.toasts.count, 1, "the failed feed must surface")
        XCTAssertEqual(center.toasts[0].kind, .error)
        XCTAssertEqual(center.toasts[0].message, "Couldn't refresh feed")
        XCTAssertEqual(center.toasts[0].detail, "down.example",
            "the reason names WHICH feed is stale")
    }

    func test_feedRefresh_allSucceed_postsNothing() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-toast-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = FeedSubscriptionStore(
            subscriptionsURL: tmp.appendingPathComponent("feeds.json"),
            readStateURL: tmp.appendingPathComponent("read.json"))
        let ok = URL(string: "https://good.example/feed")!
        _ = store.subscribe(url: ok, title: "Good")

        let center = makeCenter(now: { 0 })
        let vm = FeedReaderViewModel(
            store: store,
            fetcher: FailingFetcher(feeds: [ok: Feed(title: "Good", siteURL: nil, items: [])]),
            toasts: center)
        await vm.refresh(now: Date())
        XCTAssertTrue(center.toasts.isEmpty, "success is quiet — no toast spam")
    }
}
