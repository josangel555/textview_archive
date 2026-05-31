import XCTest
import Foundation
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 in-process tests for drag-and-drop. We don't simulate OS-level
/// drag events (that requires a UI test); instead we exercise the
/// model-side handler with NSItemProvider for file URLs and assert the
/// model's openPath was invoked.
@MainActor
final class DragDropTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragDrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DragDrop-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// Wait for an async predicate with a hard deadline. Used in
    /// place of fixed sleeps so the test reflects "drop has
    /// actually been processed" rather than "200 ms have passed".
    private func waitFor(timeout: TimeInterval, until predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    func test_drop_singleFile_opensIt() async throws {
        // Exercises the production `DropRouter.handle` — same code
        // path the View's `.onDrop` calls. Earlier this test inlined
        // a copy of the handler body; any divergence between the two
        // would silently shrink coverage.
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("dropped.md")
        try "# dropped\n".write(to: url, atomically: true, encoding: .utf8)

        let provider = NSItemProvider(object: url as NSURL)
        let resolved = ResolvedURLsSink()
        let accepted = DropRouter.handle([provider]) { urls in
            // Mirror ContentView: call openMultiple. We also peek
            // at the resolved URL list via a sink so the test can
            // distinguish "router fired" from "model opened".
            resolved.set(urls)
            model.openMultiple(urls)
        }
        XCTAssertTrue(accepted,
            "DropRouter should accept a file-URL NSItemProvider")
        let routerFired = await waitFor(timeout: 2.0) { model.tabs.tabs.count == 1 }
        XCTAssertTrue(routerFired,
            "Drop should have opened exactly one tab within 2s. Got \(model.tabs.tabs.count)")
        let snapshot = await resolved.snapshot()
        XCTAssertEqual(snapshot, [url],
            "DropRouter must pass the resolved URL through verbatim")
        guard case .loaded(let f) = model.currentState else {
            return XCTFail("Expected .loaded after drop. Got \(model.currentState)")
        }
        XCTAssertTrue(f.contents.contains("dropped"),
            "Loaded content should match the dropped file")
    }

    func test_drop_missingFile_doesNotOpen() async throws {
        // The router itself filters non-existent paths now (UDC-1):
        // existence checking is no longer inlined in the test or left
        // to the model. A missing file is resolved by the provider but
        // dropped by `DropRouter.handle` before `onResolved` fires, so
        // the completion receives an empty list and no tab opens.
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("not-there.md")
        let provider = NSItemProvider(object: url as NSURL)
        let resolved = ResolvedURLsSink()
        DropRouter.handle([provider]) { urls in
            resolved.set(urls)
            model.openMultiple(urls)
        }
        // Wait for the router's completion to fire. We can't read the
        // actor snapshot synchronously, so poll it via a settled flag.
        let fired = await waitFor(timeout: 2.0) { resolved.firedFlag }
        XCTAssertTrue(fired, "Router completion should fire even for a missing file")
        let snapshot = await resolved.snapshot()
        XCTAssertEqual(snapshot, [],
            "DropRouter must filter out a non-existent path before resolving")
        XCTAssertEqual(model.tabs.tabs.count, 0,
            "Dropping a non-existent file path should not open a tab")
    }

    func test_drop_mixed_filtersMissingKeepsExisting() async throws {
        // UDC-1: existence filtering is the router's job. A drop mixing
        // a real file and a dead path forwards only the live one — the
        // same filter the production `.onDrop` path runs.
        let model = makeModel()
        let real = tmpDir.appendingPathComponent("real.md")
        try "# real\n".write(to: real, atomically: true, encoding: .utf8)
        let dead = tmpDir.appendingPathComponent("ghost.md")

        let providers = [NSItemProvider(object: real as NSURL),
                         NSItemProvider(object: dead as NSURL)]
        let resolved = ResolvedURLsSink()
        DropRouter.handle(providers) { urls in
            resolved.set(urls)
            model.openMultiple(urls)
        }
        let fired = await waitFor(timeout: 2.0) { resolved.firedFlag }
        XCTAssertTrue(fired)
        let snapshot = await resolved.snapshot()
        XCTAssertEqual(snapshot, [real],
            "Only the existing path should survive the router's filter, in drag order")
    }

    func test_drop_stuckProvider_flushesPartialAtDeadline() async throws {
        // UDC-9: if a provider's load completion never fires, the drop
        // must not silently no-op. With a short deadline the router
        // flushes whatever resolved so far instead of waiting forever.
        // We pair a normal file-URL provider with one that registers a
        // URL-class loader whose completion is never invoked.
        let model = makeModel()
        let real = tmpDir.appendingPathComponent("resolves.md")
        try "# resolves\n".write(to: real, atomically: true, encoding: .utf8)

        let stuck = NSItemProvider()
        // Register a loader for URL that captures the completion and
        // drops it on the floor — simulating a provider whose source
        // process died mid-drag.
        stuck.registerObject(ofClass: URL.self, visibility: .all) { _ in
            return Progress(totalUnitCount: 1)  // never calls completion
        }
        let providers = [NSItemProvider(object: real as NSURL), stuck]
        let resolved = ResolvedURLsSink()
        DropRouter.handle(providers, deadline: 0.3) { urls in
            resolved.set(urls)
            model.openMultiple(urls)
        }
        let fired = await waitFor(timeout: 2.0) { resolved.firedFlag }
        XCTAssertTrue(fired,
            "Router must flush at the deadline even though one provider never resolved")
        let snapshot = await resolved.snapshot()
        XCTAssertEqual(snapshot, [real],
            "The resolved file should still open; the stuck provider is dropped")
    }
}

/// Actor-backed sink so the @MainActor / @Sendable router callback
/// can hand the resolved URL list to the test thread without a
/// shared mutable reference. Hops via detached Task; tests read
/// `snapshot()`.
///
/// `firedFlag` is a lock-guarded, synchronously-readable mirror of
/// "did the router completion fire at least once". The actor's own
/// state can't be read from a non-async `waitFor` predicate, so the
/// flag lets a polling loop detect completion without awaiting.
final class ResolvedURLsSink: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var fired = false

    func set(_ value: [URL]) {
        lock.lock()
        urls = value
        fired = true
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    var firedFlag: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
