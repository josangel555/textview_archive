import XCTest
import Combine
import ViewerKit
import ViewerCore
import TestSupport
@testable import ViewerUI

/// Observation-chain invariant pin for the multi-repo git registry.
///
/// The whole perf story rests on `TrackedReposChannel.version` being
/// observed DIRECTLY by leaf views (SidebarView / GitPanelView) and
/// NEVER leaking into `DocumentModel.objectWillChange`. A future edit
/// that forwarded `channel.objectWillChange` into the model "to make
/// badges update" would re-introduce the republish storm — now
/// amplified because FSEvents fires it on every external write across
/// MULTIPLE repos. This file is the acceptance criterion, not a
/// nice-to-have. Same shape as `TabRepublishInvariantTests`.
@MainActor
final class TrackedReposRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackedReposRepublish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "TrackedReposRepublish-\(UUID().uuidString)"
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

    private func countDocumentRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () async -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        await mutate()
        await Task.yield()
        return count
    }

    private func snap(_ root: URL) -> TrackedReposStore.RepoSnapshot {
        .init(root: TrackedReposReducer.normalize(root),
              statuses: [:], head: nil, isNestedRoot: false,
              timedOut: false, refreshedAt: Date(), generation: 1)
    }

    // MARK: - recompute does not republish DocumentModel

    func test_recompute_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.repoFocus.recompute()
            await Task.yield()
        }
        XCTAssertEqual(count, 0,
            "repoFocus.recompute() must not republish DocumentModel; views observe trackedRepos")
    }

    // MARK: - channel mirror / version bump does not republish DocumentModel

    func test_channelBump_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let r = TrackedReposReducer.normalize(tmpDir)
        let count = await countDocumentRepublishes(of: model) {
            model.trackedRepos._testBump(installing: [r: self.snap(r)])
            await Task.yield()
        }
        XCTAssertEqual(count, 0,
            "channel.version bump must not route through DocumentModel.objectWillChange")
    }

    func test_channelReads_doNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let r = TrackedReposReducer.normalize(tmpDir)
        model.trackedRepos._testBump(installing: [r: snap(r)])
        let count = await countDocumentRepublishes(of: model) {
            _ = model.trackedRepos.status(for: self.tmpDir.appendingPathComponent("a.txt"))
            _ = model.trackedRepos.isRepoRoot(self.tmpDir)
            _ = model.trackedRepos.repoRootKind(self.tmpDir)
            _ = model.trackedRepos.isTrackedRoot(r)
            _ = model.trackedRepos.repoRoot(enclosing: self.tmpDir.appendingPathComponent("a.txt"))
        }
        XCTAssertEqual(count, 0, "pure reads on the channel never touch DocumentModel")
    }

    // MARK: - equality guard: identical mirror does NOT bump version

    func test_applyMirror_identicalMirror_noVersionBump() async {
        let model = makeModel()
        let channel = model.trackedRepos
        let r = TrackedReposReducer.normalize(tmpDir)
        channel._testBump(installing: [r: snap(r)])
        let v1 = channel.version
        // Apply a structurally identical mirror (same statuses + head).
        channel.applyMirror([r: snap(r)], roots: [r])
        XCTAssertEqual(channel.version, v1,
            "identical mirror must not bump version (idle-poll / identical-FSEvents guard)")
    }

    func test_applyMirror_changedPayload_bumpsVersion() async {
        let model = makeModel()
        let channel = model.trackedRepos
        let r = TrackedReposReducer.normalize(tmpDir)
        channel.applyMirror([r: snap(r)], roots: [r])
        let v1 = channel.version
        // Now a real status change.
        let changed = TrackedReposStore.RepoSnapshot(
            root: r, statuses: [r.appendingPathComponent("a.txt"): .modified],
            head: nil, isNestedRoot: false, timedOut: false,
            refreshedAt: Date(), generation: 2
        )
        channel.applyMirror([r: changed], roots: [r])
        XCTAssertGreaterThan(channel.version, v1, "a real payload change bumps version")
    }

    // MARK: - tab-switch within one repo: no store work, no version bump

    func test_recompute_unchangedDemand_isNoOp() async throws {
        // Two files in the SAME repo. Opening both, then re-running
        // recompute with the same demand set must be a no-op: no new
        // store retain, no version bump.
        let repo = tmpDir.appendingPathComponent("repo")
        try makeRepo(at: repo)
        let a = repo.appendingPathComponent("a.txt")
        let b = repo.appendingPathComponent("b.txt")
        try "1".write(to: a, atomically: true, encoding: .utf8)
        try "2".write(to: b, atomically: true, encoding: .utf8)

        let model = makeModel()
        model.open(url: a)
        model.open(url: b)
        // Let the async recompute settle.
        try? await Task.sleep(nanoseconds: 400_000_000)
        await Task.yield()

        let prevDesired = model.repoFocus._testPreviousDesired()
        let vBefore = model.trackedRepos.version
        // Re-run with the identical demand set.
        model.repoFocus.recompute()
        await Task.yield()
        let nowDesired = model.repoFocus._testPreviousDesired()
        XCTAssertEqual(prevDesired, nowDesired, "demand set unchanged across recompute")
        XCTAssertEqual(model.trackedRepos.version, vBefore,
            "unchanged demand → no version bump (tab-switch-within-repo is free)")
    }

    // MARK: - Negative control

    /// Confirm the counter actually fires when DocumentModel itself
    /// mutates — otherwise every test above passes vacuously.
    func test_documentModelOwnMutation_doesRepublish() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("a.md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.open(url: url)
        }
        XCTAssertGreaterThan(count, 0,
            "DocumentModel.open must still republish — proves the harness works")
    }

    /// Confirm the channel DOES tick its own version (so the perf tests
    /// above aren't vacuous on a silently-disabled @Published).
    func test_channel_doesBumpOnRealChange() async {
        let model = makeModel()
        let channel = model.trackedRepos
        var count = 0
        let sub = channel.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        let r = TrackedReposReducer.normalize(tmpDir)
        channel._testBump(installing: [r: snap(r)])
        await Task.yield()
        XCTAssertGreaterThan(count, 0, "channel.objectWillChange must fire on a version bump")
    }

    // MARK: - helpers

    private func makeRepo(at dir: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        // Shared fixture (TSK-1174): init + identity config in one shell call.
        _ = try GitTestRepo.makeRepo(prefix: dir.lastPathComponent, at: dir)
    }
}
