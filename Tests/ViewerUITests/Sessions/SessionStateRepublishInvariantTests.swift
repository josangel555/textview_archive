import XCTest
import Combine
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// REPUB-1 invariant pin (2026-05-30).
///
/// `SessionState` used to forward `model.objectWillChange` into its own
/// `objectWillChange` (`wireForwarding()`). That is the exact
/// child→parent republish anti-pattern LESSONS.md ("SwiftUI republish
/// forwarding amplifies every tick") was written to kill: every
/// DocumentModel tick — keystroke, FS event, git poll, highlight-ready —
/// would republish the whole SessionState graph. It was also dead
/// weight: the session strip (`SessionTabBar`) observes the value-level
/// `SessionsCoordinator.sessions` snapshots, and `ContentView` observes
/// the `DocumentModel` directly. Nothing binds `@ObservedObject` to a
/// `SessionState`.
///
/// These tests follow the same shape as `TabRepublishInvariantTests` /
/// `FindRepublishInvariantTests` / `SidebarRepublishInvariantTests`:
///   - mutate the wrapped DocumentModel (and its children);
///   - assert `SessionState.objectWillChange` fires ZERO times;
///   - end with a negative-control test confirming SessionState DOES
///     republish on its own `@Published` mutation (guards against a
///     silently-disabled publisher making the above vacuously true).
///
/// Lives under `ViewerUITests` because `SessionState` ships in
/// `ViewerUI`, but touches no NSApplication / NSWindow — safe on host.
/// Filter: `swift test --filter ViewerUITests.SessionStateRepublishInvariant`
@MainActor
final class SessionStateRepublishInvariantTests: XCTestCase {

    private lazy var tmpDir: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStateRepublishInvariantTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private lazy var model: DocumentModel = DocumentModel()
    private lazy var state: SessionState = SessionState(
        rootURL: tmpDir, displayName: "TestSession", model: model
    )

    override func setUp() async throws {
        _ = tmpDir
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func countStateRepublishes(
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = state.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    // MARK: DocumentModel ticks must NOT republish SessionState --------

    func test_documentModelPublishedMutation_doesNotRepublishSessionState() async {
        let count = await countStateRepublishes {
            self.model.sourceWordWrap.toggle()
        }
        XCTAssertEqual(count, 0,
            "a @Published mutation on the wrapped DocumentModel must not republish SessionState (REPUB-1)")
    }

    func test_documentModelZoom_doesNotRepublishSessionState() async {
        let count = await countStateRepublishes {
            self.model.zoom = 1.4
        }
        XCTAssertEqual(count, 0,
            "DocumentModel.zoom changes must not republish SessionState")
    }

    func test_openingTab_doesNotRepublishSessionState() async throws {
        let url = tmpDir.appendingPathComponent("a.md")
        try "# a\n".write(to: url, atomically: true, encoding: .utf8)
        let count = await countStateRepublishes {
            self.model.open(url: url)
        }
        XCTAssertEqual(count, 0,
            "opening a file in the wrapped model must not republish SessionState")
    }

    // MARK: Negative control — SessionState DOES republish on its own --

    func test_sessionStateOwnMutation_doesRepublish() async {
        // displayName is a @Published on SessionState itself; mutating
        // it must fire objectWillChange. Without this, every test above
        // would pass vacuously if the publisher were silently disabled.
        let count = await countStateRepublishes {
            self.state.displayName = "Renamed"
        }
        XCTAssertGreaterThan(count, 0,
            "SessionState.displayName is @Published — mutating it must republish")
    }

    func test_mount_republishesSessionState() async {
        // mount() flips the @Published isMounted + lastActiveAt — a real
        // SessionState transition that observers should see.
        let count = await countStateRepublishes {
            self.state.mount()
        }
        XCTAssertGreaterThan(count, 0,
            "mount() flips @Published isMounted/lastActiveAt — must republish")
    }
}
