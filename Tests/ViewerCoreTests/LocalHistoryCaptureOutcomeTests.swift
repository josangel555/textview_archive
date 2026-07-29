import Foundation
import XCTest
@testable import ViewerCore

/// `capture` exists so conflict resolution can PROVE a discarded version is
/// recoverable before destroying it. A caller that treated a refusal as success
/// would delete exactly the bytes the user was told were kept, so each refusal
/// reason is pinned here.
final class LocalHistoryCaptureOutcomeTests: XCTestCase {

    private var dir: URL!
    private var store: LocalHistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LHCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalHistoryStore(directory: dir, isEnabled: { true })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String = "doc.md") -> String {
        dir.appendingPathComponent(name).path
    }

    func test_storedContent_isPreserved() {
        let outcome = store.capture(path: path(), content: "hello", at: Date())
        XCTAssertTrue(outcome.isPreserved)
        XCTAssertNotNil(outcome.version)
        XCTAssertNil(outcome.refusal)
    }

    /// Dedup is NOT a failure — the content is already recoverable, which is all
    /// the caller needs to know before discarding it.
    func test_duplicateContent_reportsAlreadyPresent_andCountsAsPreserved() {
        let p = path()
        _ = store.capture(path: p, content: "same", at: Date())
        let again = store.capture(path: p, content: "same", at: Date())
        XCTAssertEqual(again, .alreadyPresent)
        XCTAssertTrue(again.isPreserved, "the bytes ARE in history — safe to discard")
        XCTAssertNil(again.version)
    }

    func test_historyDisabled_refuses_andIsNotPreserved() {
        let off = LocalHistoryStore(directory: dir, isEnabled: { false })
        let outcome = off.capture(path: path(), content: "hello", at: Date())
        XCTAssertEqual(outcome.refusal, .historyDisabled)
        XCTAssertFalse(outcome.isPreserved)
    }

    func test_emptyContent_refuses() {
        XCTAssertEqual(store.capture(path: path(), content: "", at: Date()).refusal, .empty)
    }

    /// A secret-looking file is deliberately excluded from history — so its
    /// discarded version is NOT recoverable, and the caller must be told.
    func test_secretLikePath_refuses_soCallersCannotAssumeRecovery() {
        let outcome = store.capture(path: path(".env"), content: "TOKEN=abc", at: Date())
        XCTAssertEqual(outcome.refusal, .secretLikePath)
        XCTAssertFalse(outcome.isPreserved)
    }

    func test_everyRefusalHasUserFacingCopy() {
        for refusal in [LocalHistoryStore.CaptureRefusal.historyDisabled, .empty, .tooLarge,
                        .looksBinary, .looksLikeSecret, .secretLikePath,
                        .storageCollision, .writeFailed] {
            XCTAssertFalse(refusal.explanation.isEmpty,
                           "\(refusal) needs copy — it is shown in a data-loss prompt")
        }
    }

    /// `snapshot` is the pre-existing API; it must keep returning a Version and
    /// keep treating dedup as "nothing written" (nil).
    func test_snapshotStillDelegates_andPreservesItsOldContract() {
        let p = path()
        XCTAssertNotNil(store.snapshot(path: p, content: "v1", at: Date()))
        XCTAssertNil(store.snapshot(path: p, content: "v1", at: Date()), "dedup → nil")
        XCTAssertNotNil(store.snapshot(path: p, content: "v2", at: Date()))
        XCTAssertEqual(store.versions(for: p).count, 2)
    }

    /// The end-to-end promise: a captured version can actually be read back.
    func test_capturedVersionIsRecoverable() throws {
        let p = path()
        _ = store.capture(path: p, content: "mine\nedits\n", at: Date())
        let versions = store.versions(for: p)
        XCTAssertEqual(versions.count, 1)
        let restored = store.contentString(of: try XCTUnwrap(versions.first), for: p)
        XCTAssertEqual(restored, "mine\nedits\n")
    }
}
