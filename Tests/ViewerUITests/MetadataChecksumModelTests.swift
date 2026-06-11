import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-505 part B — host coverage for the MetadataPanel checksum machine
/// (`MetadataChecksumModel`), its script verb, and its dump projection.
/// The panel's render branches switch on `model.state`, so pinning the
/// machine here pins the behavior tier; the live-app mount + cross-process
/// path is the VM T4 UAT (`MetadataChecksumUATTests`).
@MainActor
final class MetadataChecksumModelTests: XCTestCase {

    /// NIST FIPS 180-2 vector: SHA-256("abc").
    private static let abcSHA =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private var tmp: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataChecksumModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
        try await super.tearDown()
    }

    private func file(_ name: String, _ bytes: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try bytes.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitUntil(
        _ timeout: TimeInterval = 5.0, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func test_compute_producesTheNISTVectorHash() async throws {
        let model = MetadataChecksumModel()
        model.configure(url: try file("abc.bin", "abc"))
        model.compute()
        XCTAssertEqual(model.state, .computing, "compute() must enter .computing synchronously")
        await waitUntil { model.state != .computing }
        XCTAssertEqual(model.state, .done(Self.abcSHA),
                       "the panel's hash must be the file's real SHA-256 (NIST vector)")
    }

    func test_compute_unreadableFile_fails() async throws {
        let model = MetadataChecksumModel()
        model.configure(url: tmp.appendingPathComponent("missing.bin"))
        model.compute()
        await waitUntil { model.state != .computing }
        XCTAssertEqual(model.state, .failed)
    }

    func test_compute_withoutConfigure_staysIdle() {
        let model = MetadataChecksumModel()
        model.compute()
        XCTAssertEqual(model.state, .idle, "no URL ⇒ nothing to hash, stay idle")
    }

    func test_configure_newFileResetsHash_sameFileKeepsIt() async throws {
        let model = MetadataChecksumModel()
        let a = try file("a.bin", "abc")
        model.configure(url: a)
        model.compute()
        await waitUntil { model.state != .computing }
        XCTAssertEqual(model.state, .done(Self.abcSHA))

        model.configure(url: a)   // re-render with the SAME file
        XCTAssertEqual(model.state, .done(Self.abcSHA),
                       "an idempotent re-configure must not clear the hash")

        model.configure(url: try file("b.bin", "other"))
        XCTAssertEqual(model.state, .idle, "a NEW file must drop the prior hash")
    }

    /// The latent race the model split fixed: an in-flight hash finishing
    /// AFTER a file switch must be dropped, not land the OLD file's hash on
    /// the new file's idle section.
    func test_staleCompletion_afterFileSwitch_isDropped() async throws {
        let model = MetadataChecksumModel()
        model.configure(url: try file("old.bin", "abc"))
        model.compute()
        // Switch files immediately — before the off-main hash can land.
        model.configure(url: try file("new.bin", "other"))
        XCTAssertEqual(model.state, .idle)
        // Give the stale completion ample time to arrive (and be dropped).
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.state, .idle,
                       "a stale completion must NOT clobber the new file's state")
    }

    // MARK: - verb + dump projection (the script-harness surface the T4 UAT reads)

    func test_verbAndDumpProjection_endToEnd() async throws {
        let harness = HeadlessHarness(label: "MetadataChecksumModelTests")
        defer { harness.cleanup() }

        // A constructed model registers itself as `.live` (the panel does the
        // same via @StateObject) — the verb + projection consult that seam.
        let model = MetadataChecksumModel()
        model.configure(url: try file("abc.bin", "abc"))

        ScriptVerb.apply(verb: "metadata-compute-checksum",
                         to: harness.model, sessions: harness.sessions)
        await waitUntil { model.state != .computing }

        let dump = harness.snapshot()["model"] as? [String: Any]
        let proj = dump?["metadataChecksum"] as? [String: Any]
        XCTAssertEqual(proj?["state"] as? String, "done",
                       "the verb must drive the live model to done; got \(proj ?? [:])")
        XCTAssertEqual(proj?["hash"] as? String, Self.abcSHA,
                       "the dump must project the real hash (what the T4 UAT asserts)")
    }
}
