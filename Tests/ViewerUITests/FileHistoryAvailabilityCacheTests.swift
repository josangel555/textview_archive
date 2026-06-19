import XCTest
import Foundation
import ViewerCore
@testable import ViewerUI

/// Regression coverage for TSK-972: `canShowFileHistory` (the File-History
/// menu/context-menu enable gate) must NOT fork a git subprocess on the main
/// thread on every SwiftUI body render. The fix routes through
/// `FileHistoryAvailabilityCache`, which answers synchronously from an
/// in-memory map and runs the real git probe OFF the main thread.
///
/// These tests pin the cache's behaviour with an INJECTED fake probe so they
/// are deterministic and never fork git — plus one end-to-end test through
/// `DocumentModel.canShowFileHistory` against a real repo.
@MainActor
final class FileHistoryAvailabilityCacheTests: HeadlessUITestCase {

    private func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FHAvailTests-\(UUID().uuidString)-\(name)")
    }

    /// Thread-safe probe-invocation counter. The probe closure is `@Sendable`
    /// and runs on a detached task, so it can't capture a mutable `var`; this
    /// `Sendable` class wraps an `NSLock`-guarded count and is read from the
    /// async test body via `value`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: - synchronous behaviour (the main-thread hot path)

    /// First read for an unknown file returns `true` (enabled) SYNCHRONOUSLY
    /// and does NOT invoke the probe inline — the whole point is that the
    /// `.disabled` modifier never blocks the main thread on git.
    func test_unknownFile_returnsTrueSynchronously_withoutInlineProbe() {
        let probeRan = expectation(description: "probe runs off-main")
        probeRan.assertForOverFulfill = false
        let cache = FileHistoryAvailabilityCache { _ in
            probeRan.fulfill()
            return false
        }
        let url = tmpURL("file.txt")

        // The synchronous return value is `true` (unknown ⇒ enabled) and the
        // probe has NOT run yet at the point the call returns.
        let answer = cache.availability(for: url) { _, _ in }
        XCTAssertTrue(answer, "unknown file must default to enabled, not block")
        XCTAssertFalse(cache.hasCachedValue(for: url),
                       "the probe is off-main; no synchronous cache write")

        // The probe DOES run, just asynchronously.
        wait(for: [probeRan], timeout: 5)
    }

    /// After an off-main probe resolves, the cached value is returned
    /// synchronously on subsequent reads (no further probes).
    func test_probeResolves_thenSubsequentReadIsCachedSynchronously() async {
        let probeCount = Counter()
        let cache = FileHistoryAvailabilityCache { _ in
            probeCount.increment()
            return true
        }
        let url = tmpURL("tracked.txt")

        let resolved = expectation(description: "onResolved fires")
        var resolvedValue: Bool?
        _ = cache.availability(for: url) { _, value in
            resolvedValue = value
            resolved.fulfill()
        }
        await fulfillment(of: [resolved], timeout: 5)
        XCTAssertEqual(resolvedValue, true)

        // Now the value is cached; a fresh read returns it synchronously and
        // schedules NO new probe.
        let cached = cache.availability(for: url) { _, _ in
            XCTFail("a cached read must not re-resolve")
        }
        XCTAssertTrue(cached)
        XCTAssertTrue(cache.hasCachedValue(for: url))
        XCTAssertEqual(probeCount.value, 1, "exactly one probe for the cached file")
    }

    /// A FALSE probe result is cached and republished, so the menu item
    /// becomes disabled once the off-main check lands (the behaviour the
    /// `.disabled(!canShowFileHistory)` binding depends on).
    func test_falseProbe_landsAsDisabled() async {
        let cache = FileHistoryAvailabilityCache { _ in false }
        let url = tmpURL("untracked.txt")

        let resolved = expectation(description: "onResolved fires with false")
        var resolvedValue: Bool?
        _ = cache.availability(for: url) { _, value in
            resolvedValue = value
            resolved.fulfill()
        }
        await fulfillment(of: [resolved], timeout: 5)
        XCTAssertEqual(resolvedValue, false, "untracked file resolves to disabled")

        let cached = cache.availability(for: url) { _, _ in
            XCTFail("cached false must not re-resolve")
        }
        XCTAssertFalse(cached, "subsequent read returns the cached disabled state")
    }

    // MARK: - probe deduplication (the SwiftUI re-render burst)

    /// A burst of reads for the SAME file before the probe lands schedules
    /// exactly ONE git fork — this is the core fix for the "context-menu
    /// re-render forks git N times" symptom.
    func test_burstOfReads_dedupesToOneProbe() async {
        let started = expectation(description: "probe started")
        started.assertForOverFulfill = false
        let release = DispatchSemaphore(value: 0)
        let probeCount = Counter()
        let cache = FileHistoryAvailabilityCache { _ in
            probeCount.increment()
            started.fulfill()
            release.wait()   // hold the probe so the burst hits while in flight
            return true
        }
        let url = tmpURL("hot.txt")

        // First read kicks off the (blocked) probe.
        _ = cache.availability(for: url) { _, _ in }
        await fulfillment(of: [started], timeout: 5)

        // Many more reads while the probe is still in flight — all must be
        // deduped (no new fork).
        for _ in 0..<20 {
            _ = cache.availability(for: url) { _, _ in }
        }
        release.signal()

        // Give the in-flight task time to land, then assert one probe total.
        let landed = expectation(description: "value cached")
        Task { @MainActor in
            while !cache.hasCachedValue(for: url) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            landed.fulfill()
        }
        await fulfillment(of: [landed], timeout: 5)
        XCTAssertEqual(probeCount.value, 1, "a re-render burst must dedupe to one git fork")
    }

    // MARK: - invalidation

    /// `invalidate(for:)` drops one entry so the next read re-probes.
    func test_invalidate_dropsEntry_andReProbes() async {
        let probeCount = Counter()
        let cache = FileHistoryAvailabilityCache { _ in
            probeCount.increment()
            return true
        }
        let url = tmpURL("flip.txt")

        let first = expectation(description: "first probe")
        _ = cache.availability(for: url) { _, _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 5)
        XCTAssertTrue(cache.hasCachedValue(for: url))

        cache.invalidate(for: url)
        XCTAssertFalse(cache.hasCachedValue(for: url), "invalidate drops the entry")

        let second = expectation(description: "re-probe after invalidate")
        _ = cache.availability(for: url) { _, _ in second.fulfill() }
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(probeCount.value, 2, "a read after invalidate must re-probe")
    }

    /// `invalidateAll()` clears every entry.
    func test_invalidateAll_clearsCache() async {
        let cache = FileHistoryAvailabilityCache { _ in true }
        let a = tmpURL("a.txt")
        let b = tmpURL("b.txt")

        let bothCached = expectation(description: "two entries cached")
        bothCached.expectedFulfillmentCount = 2
        _ = cache.availability(for: a) { _, _ in bothCached.fulfill() }
        _ = cache.availability(for: b) { _, _ in bothCached.fulfill() }
        await fulfillment(of: [bothCached], timeout: 5)
        XCTAssertEqual(cache.cachedCount, 2)

        cache.invalidateAll()
        XCTAssertEqual(cache.cachedCount, 0)
        XCTAssertFalse(cache.hasCachedValue(for: a))
        XCTAssertFalse(cache.hasCachedValue(for: b))
    }

    // MARK: - end-to-end through DocumentModel against a real repo

    /// `DocumentModel.canShowFileHistory` returns `true` synchronously on the
    /// first call (before the probe lands), then — once the off-main probe
    /// resolves — reports the REAL tracked-ness of the file. Tracked file ⇒
    /// stays enabled; loose (non-repo) file ⇒ becomes disabled. This pins the
    /// real git path while proving the synchronous call never blocks.
    func test_documentModel_canShowFileHistory_realRepo_endToEnd() async throws {
        let harness = HeadlessHarness(label: "FHAvailE2E")
        defer { harness.cleanup() }
        let model = harness.model

        // A real repo with one committed file.
        let repo = tmpURL("repo")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: repo)
        try runGit(["config", "user.email", "t@example.com"], in: repo)
        try runGit(["config", "user.name", "Tester"], in: repo)
        try runGit(["config", "commit.gpgsign", "false"], in: repo)
        let tracked = repo.appendingPathComponent("tracked.txt")
        try "v1\n".write(to: tracked, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], in: repo)
        try runGit(["commit", "-q", "-m", "init"], in: repo)

        // Synchronous first call is non-blocking and defaults to enabled.
        XCTAssertTrue(model.canShowFileHistory(for: tracked),
                      "first (uncached) call returns enabled synchronously")

        // After the off-main probe lands, the cache holds the REAL answer:
        // tracked ⇒ true.
        try await waitUntil(timeout: 5) {
            model.fileHistoryAvailability.hasCachedValue(for: tracked)
        }
        XCTAssertTrue(model.canShowFileHistory(for: tracked),
                      "a tracked file resolves to enabled")

        // A loose file outside any repo resolves to disabled.
        let loose = tmpURL("loose.txt")
        defer { try? FileManager.default.removeItem(at: loose) }
        try "hi".write(to: loose, atomically: true, encoding: .utf8)
        _ = model.canShowFileHistory(for: loose)   // kicks the probe
        try await waitUntil(timeout: 5) {
            model.fileHistoryAvailability.hasCachedValue(for: loose)
        }
        XCTAssertFalse(model.canShowFileHistory(for: loose),
                       "a non-repo file resolves to disabled")
    }

    // MARK: - helpers

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    /// Poll `condition` on the main actor until true or timeout.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
