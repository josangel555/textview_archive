import XCTest
@testable import ViewerCore

/// Concurrency contract for `RepoStatsCache` (TSK-970): the blocking git
/// probe + history walk must run OFF the actor's serial executor (so a
/// multi-second walk doesn't head-of-line-block every other `stats()` /
/// `invalidate*()` call), and concurrent `stats()` for the SAME key must
/// coalesce onto ONE underlying walk.
///
/// All tests inject a fake `RepoStatsProviding` — NO real git is spawned.
/// The fake's `repoStats` blocks on a signal so we can hold a walk
/// "in flight" and observe the actor's behaviour during that window.
final class RepoStatsCacheConcurrencyTests: XCTestCase {

    /// A controllable provider. `repoStats` parks until `release()` is
    /// called (or a deadline), letting a test pin a walk "in flight".
    /// Call counts are atomic so they're safe to read across the
    /// `Task.detached` hop the cache performs.
    private final class GatedProvider: RepoStatsProviding, @unchecked Sendable {
        private let lock = NSLock()
        /// `repoStats` parks here when `blockStats`; `release()` admits one
        /// parked walk. The walk runs synchronously inside the cache's
        /// `Task.detached`, so a *blocking* DispatchSemaphore wait there is
        /// correct (it parks an OS thread, off the actor's executor).
        private let gate = DispatchSemaphore(value: 0)

        private var _headCalls = 0
        private var _statsCalls = 0
        private let headSHAValue: String
        /// When true, `repoStats` parks on `gate` before returning.
        private let blockStats: Bool

        init(headSHA: String = "deadbee", blockStats: Bool) {
            self.headSHAValue = headSHA
            self.blockStats = blockStats
        }

        var headCalls: Int { lock.lock(); defer { lock.unlock() }; return _headCalls }
        /// How many `repoStats` walks have ENTERED (so far) — incremented
        /// before parking. Tests poll this (async-friendly) to know a walk
        /// is genuinely in flight, and assert it at the end (coalescing).
        var statsCalls: Int { lock.lock(); defer { lock.unlock() }; return _statsCalls }

        /// Unblock one parked `repoStats`.
        func release() { gate.signal() }

        func headSHA(repoRoot: URL, statusTimeout: TimeInterval?) -> String {
            lock.lock(); _headCalls += 1; lock.unlock()
            return headSHAValue
        }

        func repoStats(
            repoRoot: URL,
            scope: GitClient.RepoStatsScope,
            statusTimeout: TimeInterval?
        ) -> GitClient.RepoStats {
            lock.lock(); _statsCalls += 1; lock.unlock()
            if blockStats {
                // Park off the actor's executor (we're inside Task.detached).
                // Deadline guards against a hang if the fix regresses.
                _ = gate.wait(timeout: .now() + 5)
            }
            return GitClient.RepoStats(
                scope: scope,
                totalCommits: 42,
                firstCommitDate: nil,
                lastCommitDate: nil,
                authors: [],
                extensions: [],
                trackedFileCount: 7
            )
        }
    }

    /// Async-poll until `provider.statsCalls >= count` (a walk has entered
    /// `repoStats`) or the deadline. `DispatchSemaphore.wait` is banned in
    /// async contexts, so child tasks coordinate via this poll instead.
    private static func awaitEntered(
        _ provider: GatedProvider, atLeast count: Int, timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while provider.statsCalls < count {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        return true
    }

    // `static` (not instance) so the `Task { ... }` closures below don't
    // capture `self` (a non-Sendable XCTestCase) under strict concurrency.
    private static let rootA = URL(fileURLWithPath: "/tmp/repo-A")
    private static let rootB = URL(fileURLWithPath: "/tmp/repo-B")

    // MARK: - off-actor: a slow walk does not block other actor methods

    /// While one `stats(rootA)` walk is parked in flight, an `invalidate`
    /// call and a `stats(rootB)` for a DIFFERENT root must still progress.
    /// On the pre-fix code (blocking walk ON the actor executor) the actor
    /// is held exclusively by the parked walk, so these would deadlock /
    /// serialize behind it and the test would time out.
    func test_slowWalk_doesNotBlock_otherActorMethods() async throws {
        let provider = GatedProvider(blockStats: true)
        let cache = RepoStatsCache(provider: provider)

        // `withTaskGroup` (not bare `Task {}`) is the strict-concurrency-
        // clean way to spawn child tasks that capture the local actor.
        let didProgress: Bool = await withTaskGroup(of: GitClient.RepoStats?.self) { group in
            // Child 1: a walk that parks in flight (returns its stats).
            group.addTask {
                await cache.stats(repoRoot: Self.rootA, scope: .repo)
            }
            // Child 2: a *different* actor method, invoked only AFTER the
            // walk is confirmed parked. If the blocking walk pinned the
            // actor's executor, this never completes.
            group.addTask {
                // Wait (off the actor) until the walk has genuinely entered.
                _ = await Self.awaitEntered(provider, atLeast: 1)
                await cache.invalidate(repoRoot: Self.rootB)
                return nil
            }
            // Watchdog: if the invalidate is head-of-line-blocked, this
            // wins the race and the test fails (instead of hanging).
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                provider.release()  // unstick the parked walk on timeout
                return GitClient.RepoStats(scope: .repo, totalCommits: -1,
                                           firstCommitDate: nil, lastCommitDate: nil,
                                           authors: [], extensions: [], trackedFileCount: 0)
            }

            // The invalidate child (returns nil) finishing first proves it
            // progressed while the walk was parked. The watchdog finishing
            // first (returns totalCommits == -1) proves it was blocked.
            var progressed = false
            while let result = await group.next() {
                if result == nil {            // invalidate completed
                    progressed = true
                    provider.release()        // let the parked walk finish
                    break
                }
                if result?.totalCommits == -1 { // watchdog fired first
                    break
                }
            }
            group.cancelAll()
            // Drain remaining children so none dangle.
            provider.release()
            for await _ in group {}
            return progressed
        }

        XCTAssertTrue(didProgress,
                      "invalidate(rootB) was head-of-line-blocked by the parked walk — work is on the actor's executor, not off it")
    }

    // MARK: - coalescing: concurrent same-root loads share ONE walk

    /// Two concurrent `stats(sameRoot, sameScope)` must invoke the
    /// underlying provider's expensive `repoStats` walk exactly ONCE — the
    /// second caller coalesces onto the first's in-flight load. Without
    /// coalescing each call would launch its own walk (statsCalls == 2).
    func test_concurrentSameRoot_coalesceToOneWalk() async throws {
        let provider = GatedProvider(blockStats: true)
        let cache = RepoStatsCache(provider: provider)

        let results: [GitClient.RepoStats] = await withTaskGroup(of: GitClient.RepoStats.self) { group in
            // Two concurrent callers for the SAME key.
            group.addTask { await cache.stats(repoRoot: Self.rootA, scope: .repo) }
            group.addTask {
                // Order the second behind the first so the first registers
                // the in-flight load before the second arrives. Wait for
                // the first walk to enter, then a beat for the cache to set
                // its `inFlight` slot.
                _ = await Self.awaitEntered(provider, atLeast: 1)
                try? await Task.sleep(nanoseconds: 50_000_000)
                return await cache.stats(repoRoot: Self.rootA, scope: .repo)
            }
            // Release the single parked walk once both callers are in
            // flight (give the coalescer time to NOT spawn a duplicate).
            group.addTask {
                _ = await Self.awaitEntered(provider, atLeast: 1)
                try? await Task.sleep(nanoseconds: 200_000_000)
                provider.release()
                return GitClient.RepoStats(scope: .repo, totalCommits: 42,
                                           firstCommitDate: nil, lastCommitDate: nil,
                                           authors: [], extensions: [], trackedFileCount: 7)
            }
            var out: [GitClient.RepoStats] = []
            for await r in group { out.append(r) }
            return out
        }

        XCTAssertEqual(results.count, 3)
        for r in results { XCTAssertEqual(r.totalCommits, 42) }
        // The crux: the expensive walk ran exactly ONCE despite two
        // concurrent same-key callers. Without coalescing it would be 2.
        XCTAssertEqual(provider.statsCalls, 1,
                       "the concurrent same-root call launched a duplicate walk — coalescing is not happening")
        // TEETH that distinguish coalescing from accidental cache-reuse:
        // a coalesced second caller short-circuits on the in-flight slot
        // BEFORE doing its own HEAD probe, so headSHA is invoked exactly
        // once. A naive serial implementation (first completes + caches,
        // second then re-probes HEAD against the cache) would hit
        // headCalls == 2 — passing the statsCalls check by accident.
        XCTAssertEqual(provider.headCalls, 1,
                       "the second caller re-probed HEAD instead of coalescing onto the in-flight load")
    }

    /// Different scopes of the same repo must NOT coalesce (they cache
    /// independently), proving the coalescing key includes the scope.
    func test_concurrentDifferentScope_doNotCoalesce() async throws {
        let provider = GatedProvider(blockStats: true)
        let cache = RepoStatsCache(provider: provider)

        await withTaskGroup(of: GitClient.RepoStats.self) { group in
            // Two DISTINCT keys (same root, different scope) — must NOT
            // coalesce, so both walks enter `repoStats`.
            group.addTask { await cache.stats(repoRoot: Self.rootA, scope: .repo) }
            group.addTask {
                await cache.stats(repoRoot: Self.rootA, scope: .folder(relativePath: "sub"))
            }
            // Releaser: wait for BOTH walks to enter, then release both.
            group.addTask {
                _ = await Self.awaitEntered(provider, atLeast: 2)
                provider.release()
                provider.release()
                return GitClient.RepoStats(scope: .repo, totalCommits: 42,
                                           firstCommitDate: nil, lastCommitDate: nil,
                                           authors: [], extensions: [], trackedFileCount: 7)
            }
            for await _ in group {}
        }

        XCTAssertEqual(provider.statsCalls, 2,
                       "the different-scope walk should NOT coalesce onto the repo-scope walk")
    }

    // MARK: - caching still works (HEAD-match short-circuits the walk)

    /// A second `stats()` for the same key after the first completed must
    /// serve from cache (HEAD matches the fake's constant sha) without a
    /// second walk — `repoStats` invoked once total, `headSHA` invoked per
    /// call.
    func test_secondCall_servesFromCache_noSecondWalk() async throws {
        let provider = GatedProvider(blockStats: false)
        let cache = RepoStatsCache(provider: provider)

        let first = await cache.stats(repoRoot: Self.rootA, scope: .repo)
        XCTAssertEqual(first.totalCommits, 42)
        XCTAssertEqual(provider.statsCalls, 1)

        let second = await cache.stats(repoRoot: Self.rootA, scope: .repo)
        XCTAssertEqual(second.totalCommits, 42)
        XCTAssertEqual(provider.statsCalls, 1, "HEAD matched — the cached value should serve without a re-walk")
        XCTAssertEqual(provider.headCalls, 2, "each call re-probes HEAD")
    }

    /// Empty HEAD (e.g. a not-a-repo / commitless dir) must NOT be cached,
    /// so each call re-walks. Pins the existing don't-cache-empty-HEAD
    /// contract through the new code path.
    func test_emptyHead_doesNotCache() async throws {
        let provider = GatedProvider(headSHA: "", blockStats: false)
        let cache = RepoStatsCache(provider: provider)

        _ = await cache.stats(repoRoot: Self.rootA, scope: .repo)
        _ = await cache.stats(repoRoot: Self.rootA, scope: .repo)
        XCTAssertEqual(provider.statsCalls, 2, "empty HEAD must not be cached — every call re-walks")
    }
}
