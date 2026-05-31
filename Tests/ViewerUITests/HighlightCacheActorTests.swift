import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// PERF #5 unit + invariant tests (2026-05-25).
///
/// The per-tab `HighlightCacheActor` replaces the previous global
/// `@Published highlightCache` on `DocumentModel`. These tests cover:
///
///   1. Cache hit / miss semantics.
///   2. In-flight coalescing (same key while a task is pending must
///      not kick off a second tokenize).
///   3. LRU eviction order.
///   4. `version` bumps on store — narrow channel for SwiftUI.
///   5. The critical invariant: writing to the actor must NOT cause
///      `DocumentModel.objectWillChange` to fire. This is the whole
///      point of the per-tab actor.
@MainActor
final class HighlightCacheActorTests: XCTestCase {

    // MARK: - Cache mechanics

    func test_runs_isNilOnEmpty() {
        let actor = HighlightCacheActor()
        let key = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/a.swift"),
            length: 0,
            language: .swift
        )
        XCTAssertNil(actor.runs(for: key))
    }

    func test_install_returnsRunsOnSubsequentLookup() {
        let actor = HighlightCacheActor()
        let key = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/a.swift"),
            length: 4,
            language: .swift
        )
        let fakeRuns = [HighlightRun(range: NSRange(location: 0, length: 3), kind: .keyword)]
        actor._testInstall(fakeRuns, for: key)
        XCTAssertEqual(actor.runs(for: key)?.count, 1)
    }

    func test_install_bumpsVersion() {
        let actor = HighlightCacheActor()
        let v0 = actor.version
        let key = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/a.swift"),
            length: 0,
            language: .swift
        )
        actor._testInstall([], for: key)
        XCTAssertNotEqual(actor.version, v0,
                          "store must bump version so observers re-eval")
    }

    func test_eviction_dropsOldestFirst() {
        let actor = HighlightCacheActor()
        // Cap is 8 (private static let); insert 10 to force eviction.
        for i in 0..<10 {
            let key = HighlightCacheKey(
                url: URL(fileURLWithPath: "/tmp/file-\(i).swift"),
                length: i,
                language: .swift
            )
            actor._testInstall([], for: key)
        }
        // Oldest keys should have been dropped; freshest survive.
        let oldKey = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/file-0.swift"),
            length: 0, language: .swift
        )
        let freshKey = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/file-9.swift"),
            length: 9, language: .swift
        )
        XCTAssertNil(actor.runs(for: oldKey),
                     "oldest entry should have been evicted")
        XCTAssertNotNil(actor.runs(for: freshKey),
                        "most-recent entry must survive (no S2-G regression)")
    }

    // MARK: - Coalescing

    func test_ensureTokenized_coalescesInFlight() async {
        let actor = HighlightCacheActor()
        let key = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/x.swift"),
            length: 10,
            language: .swift
        )
        // Kick off two concurrent ensureTokenized for the same key.
        // The second should be a no-op (coalesced into the first).
        actor.ensureTokenized(key: key, text: "let x = 1")
        actor.ensureTokenized(key: key, text: "let x = 1")
        // Both touches must collapse to a single in-flight entry.
        XCTAssertEqual(actor.`_testInFlightCount`, 1,
                       "second ensureTokenized for same key must coalesce")
        // Drain the detached task so we don't leak it into other tests.
        // Wait via polling; 100ms is plenty for a 9-byte tokenize.
        for _ in 0..<50 {
            if actor.`_testInFlightCount` == 0 { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

/// PERF #5 invariant pin: highlight-cache writes must not republish
/// `DocumentModel`. Lives in the DocumentModel tests namespace so the
/// test reads as a contract on the model's observation surface.
@MainActor
final class HighlightCacheDoesNotRepublishDocumentModelTests: XCTestCase {

    private var tmpDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HighlightCacheRepublish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "HighlightCacheRepublish-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    func test_tokenizeCompletion_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        let tabID = UUID()
        let actor = model.highlightCacheActor(forTabID: tabID)
        let key = HighlightCacheKey(
            url: URL(fileURLWithPath: "/tmp/y.swift"),
            length: 0,
            language: .swift
        )
        var docRepublishCount = 0
        let sub = model.objectWillChange.sink { _ in docRepublishCount += 1 }
        defer { sub.cancel() }

        // Simulate a tokenize completion.
        actor._testInstall([], for: key)
        await Task.yield()

        XCTAssertEqual(
            docRepublishCount, 0,
            "PERF #5: tokenize completion must not republish DocumentModel"
        )
        // Confirm the actor *did* publish (otherwise the test is
        // vacuously true — we'd be saying "no publish caused no publish").
        XCTAssertGreaterThan(actor.version, 0,
                             "actor must publish its own version bump")
    }

    func test_perTabActor_isolatedPerTab() {
        let model = makeModel()
        let a = model.highlightCacheActor(forTabID: UUID())
        let b = model.highlightCacheActor(forTabID: UUID())
        XCTAssertFalse(a === b,
                       "each tab id must get its own actor instance")
    }

    func test_perTabActor_sameTabIDReturnsSameInstance() {
        let model = makeModel()
        let id = UUID()
        let first = model.highlightCacheActor(forTabID: id)
        let second = model.highlightCacheActor(forTabID: id)
        XCTAssertTrue(first === second,
                      "repeat calls with same id must return the same actor")
    }
}

/// RWC-1 (2026-05-30): the highlight cache key now folds in
/// `modifiedTime`, so a same-byte-length reload (length + url + language
/// unchanged) is a MISS instead of returning stale syntax spans.
@MainActor
final class HighlightCacheKeyMtimeTests: XCTestCase {

    func test_sameLengthDifferentMtime_areDistinctKeys() {
        let url = URL(fileURLWithPath: "/tmp/k.swift")
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let k0 = HighlightCacheKey(url: url, length: 9, language: .swift, modifiedTime: t0)
        let k1 = HighlightCacheKey(url: url, length: 9, language: .swift, modifiedTime: t1)
        XCTAssertNotEqual(k0, k1,
            "same-byte reload (new mtime) must form a distinct cache key")
    }

    func test_sameMtime_collidesAsHit() {
        let url = URL(fileURLWithPath: "/tmp/k.swift")
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = HighlightCacheKey(url: url, length: 9, language: .swift, modifiedTime: t0)
        let b = HighlightCacheKey(url: url, length: 9, language: .swift, modifiedTime: t0)
        XCTAssertEqual(a, b, "identical key fields must hash/compare equal")
    }

    func test_actorMissesAcrossMtimeChange() {
        let actor = HighlightCacheActor()
        let url = URL(fileURLWithPath: "/tmp/k.swift")
        let oldKey = HighlightCacheKey(
            url: url, length: 9, language: .swift,
            modifiedTime: Date(timeIntervalSince1970: 1_000))
        actor._testInstall(
            [HighlightRun(range: NSRange(location: 0, length: 3), kind: .keyword)],
            for: oldKey)
        // Same length/url/language, file rewritten in place (new mtime).
        let newKey = HighlightCacheKey(
            url: url, length: 9, language: .swift,
            modifiedTime: Date(timeIntervalSince1970: 2_000))
        XCTAssertNil(actor.runs(for: newKey),
            "same-byte reload must miss so stale spans aren't served")
        XCTAssertNotNil(actor.runs(for: oldKey),
            "the original mtime keeps hitting")
    }
}

