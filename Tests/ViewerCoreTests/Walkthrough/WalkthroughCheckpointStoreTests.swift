import XCTest
@testable import ViewerCore

/// Pure-logic tests for the file-based bidirectional checkpoint channel
/// (`WalkthroughCheckpointStore`). This is the outbound half of the
/// walkthrough transport (TSK-378): when a step is an `awaitUser`
/// checkpoint the engine writes the prompt, and the user's reply is
/// always persisted so a polling agent (Claude) sees it — the MCP
/// server being strict request/response can't carry the notification.
///
/// All of it is `FileManager` + Codable, so it runs on the host with no
/// UI. Each test uses a fresh temp dir and cleans up.
final class WalkthroughCheckpointStoreTests: XCTestCase {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-ckpt-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Checkpoint write + round-trip

    func test_writeCheckpoint_writesReadableFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        let payload = AwaitUserPayload(
            prompt: "Which theme?",
            placeholder: "type a theme…",
            pills: ["Dark", "Light"]
        )
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try store.writeCheckpoint(
            walkthroughId: "tour1", stepId: "s5", payload: payload, at: when
        )

        // Filename follows the documented `<id>.<step>.checkpoint.json`.
        XCTAssertEqual(url.lastPathComponent, "tour1.s5.checkpoint.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Round-trip via the public reader.
        let read = try XCTUnwrap(
            store.readCheckpoint(walkthroughId: "tour1", stepId: "s5")
        )
        XCTAssertEqual(read.walkthroughId, "tour1")
        XCTAssertEqual(read.stepId, "s5")
        XCTAssertEqual(read.prompt, "Which theme?")
        XCTAssertEqual(read.placeholder, "type a theme…")
        XCTAssertEqual(read.pills, ["Dark", "Light"])
        XCTAssertEqual(read.writtenAt, when)
    }

    func test_writeCheckpoint_jsonShapeIsAgentReadable() throws {
        // An external agent reads the raw JSON, not our Swift types, so
        // pin the on-disk keys + ISO8601 date so a wire-shape change is
        // a conscious break.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        let url = try store.writeCheckpoint(
            walkthroughId: "t", stepId: "s",
            payload: AwaitUserPayload(prompt: "P?", placeholder: nil, pills: nil),
            at: Date(timeIntervalSince1970: 0)
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        XCTAssertEqual(json["walkthroughId"] as? String, "t")
        XCTAssertEqual(json["stepId"] as? String, "s")
        XCTAssertEqual(json["prompt"] as? String, "P?")
        // Omitted optionals must not appear (encodeIfPresent semantics).
        XCTAssertNil(json["placeholder"])
        XCTAssertNil(json["pills"])
        XCTAssertEqual(json["writtenAt"] as? String, "1970-01-01T00:00:00Z")
    }

    // MARK: - Reply write + round-trip (the bidirectional channel)

    func test_writeReply_option_roundTrips() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        let url = try store.writeReply(
            walkthroughId: "tour1", stepId: "s5",
            answer: .option("Dark"),
            at: Date(timeIntervalSince1970: 42)
        )
        XCTAssertEqual(url.lastPathComponent, "tour1.s5.reply.json")
        let read = try XCTUnwrap(
            store.readReply(walkthroughId: "tour1", stepId: "s5")
        )
        XCTAssertEqual(read.answer, .option("Dark"))
        XCTAssertEqual(read.answer.text, "Dark")
        XCTAssertEqual(read.writtenAt, Date(timeIntervalSince1970: 42))
    }

    func test_writeReply_freeForm_roundTrips() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        try store.writeReply(
            walkthroughId: "t", stepId: "s",
            answer: .freeForm("I prefer high-contrast"),
            at: Date()
        )
        let read = try XCTUnwrap(
            store.readReply(walkthroughId: "t", stepId: "s")
        )
        XCTAssertEqual(read.answer, .freeForm("I prefer high-contrast"))
        XCTAssertEqual(read.answer.text, "I prefer high-contrast")
    }

    func test_writeReply_alwaysWrites_evenWithNoListener() throws {
        // Design §4.1: the reply is ALWAYS persisted regardless of
        // whether anyone is listening, so a polling agent sees it. There
        // is no "listener" concept in the store — proving the file lands
        // unconditionally is the contract.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        let url = try store.writeReply(
            walkthroughId: "t", stepId: "s", answer: .option("X"), at: Date()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_reply_overwrites_priorReply() throws {
        // Re-answering the same checkpoint (e.g. user changed their
        // mind before advancing) overwrites atomically.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        try store.writeReply(
            walkthroughId: "t", stepId: "s", answer: .option("first"), at: Date()
        )
        try store.writeReply(
            walkthroughId: "t", stepId: "s", answer: .option("second"), at: Date()
        )
        let read = try XCTUnwrap(
            store.readReply(walkthroughId: "t", stepId: "s")
        )
        XCTAssertEqual(read.answer, .option("second"))
    }

    func test_readReply_missing_returnsNil() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        XCTAssertNil(store.readReply(walkthroughId: "nope", stepId: "nope"))
    }

    // MARK: - Directory creation

    func test_write_createsDirectoryOnDemand() throws {
        // The temp dir does NOT exist yet — the store must create it.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let store = WalkthroughCheckpointStore(directory: dir)
        try store.writeReply(
            walkthroughId: "t", stepId: "s", answer: .option("X"), at: Date()
        )
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        )
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Filename sanitization (security fence)

    func test_sanitize_stripsPathSeparators() {
        // A hostile id can come from an untrusted dropped script — it
        // must not be able to escape the checkpoint dir. `.` is a legal
        // filename char (kept), but every `/` collapses to `_` so no
        // path component can ever form. Leading dots are then stripped.
        //   "../../etc/passwd"  →  ".._.._etc_passwd"  →  "_.._etc_passwd"
        XCTAssertEqual(
            WalkthroughCheckpointStore.sanitize("../../etc/passwd"),
            "_.._etc_passwd"
        )
        XCTAssertEqual(
            WalkthroughCheckpointStore.sanitize("a/b/c"), "a_b_c"
        )
        // No surviving `/` ⇒ the result is always a single path component.
        XCTAssertFalse(
            WalkthroughCheckpointStore.sanitize("a/../../b").contains("/")
        )
    }

    func test_sanitize_stripsLeadingDots() {
        XCTAssertEqual(WalkthroughCheckpointStore.sanitize("..hidden"), "hidden")
        XCTAssertEqual(WalkthroughCheckpointStore.sanitize("."), "")
        XCTAssertEqual(WalkthroughCheckpointStore.sanitize(".."), "")
    }

    func test_sanitize_keepsSafeChars() {
        XCTAssertEqual(
            WalkthroughCheckpointStore.sanitize("tour-1_step.5"),
            "tour-1_step.5"
        )
    }

    func test_hostileId_cannotEscapeDirectory() throws {
        // End-to-end: a traversal id must still land INSIDE `directory`.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        let url = try store.writeReply(
            walkthroughId: "../../../../tmp/evil",
            stepId: "s",
            answer: .option("X"),
            at: Date()
        )
        // The written file's parent IS the store dir (standardized).
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            dir.standardizedFileURL
        )
    }

    func test_emptyIdentifier_throws() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WalkthroughCheckpointStore(directory: dir)
        XCTAssertThrowsError(
            try store.writeReply(
                walkthroughId: "...", stepId: "s", answer: .option("X"), at: Date()
            )
        ) { err in
            XCTAssertEqual(err as? WalkthroughCheckpointStore.Error, .emptyIdentifier)
        }
    }

    // MARK: - CheckpointAnswer codable

    func test_checkpointAnswer_unknownKind_rejected() {
        let json = Data(#"{"kind":"telepathy","value":"x"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CheckpointAnswer.self, from: json)
        )
    }

    func test_checkpointAnswer_encodesTaggedShape() throws {
        let data = try JSONEncoder().encode(CheckpointAnswer.option("Dark"))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["kind"] as? String, "option")
        XCTAssertEqual(obj["value"] as? String, "Dark")
    }

    // MARK: - Default directory location

    func test_defaultDirectory_isWalkthroughsCheckpointsSibling() {
        let url = WalkthroughCheckpointStore.defaultDirectory()
        XCTAssertEqual(url.lastPathComponent, "checkpoints")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Walkthroughs")
        XCTAssertTrue(
            url.path.contains("com.markdownviewer.MarkdownViewer"),
            "checkpoint dir must live under the bundle-id Application Support subdir"
        )
    }
}
