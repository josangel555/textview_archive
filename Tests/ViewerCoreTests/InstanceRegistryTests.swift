import XCTest
@testable import ViewerCore

/// TSK-353 — CLI instance discovery (find active instance + operate on it).
/// Pins the register → discover → prune-stale → select-newest path over an
/// injectable directory + liveness probe, plus the command-envelope round-trip.
/// Everything host-testable; the socket transport is TSK-400 and out of scope.
final class InstanceRegistryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-instances-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    private func record(
        pid: Int32, secondsAgo: TimeInterval = 0, endpoint: String = "/tmp/mdv.sock",
        version: String = "1.0.0"
    ) -> InstanceRegistry.InstanceRecord {
        InstanceRegistry.InstanceRecord(
            pid: pid,
            launchDate: Date(timeIntervalSinceNow: -secondsAgo),
            endpoint: endpoint,
            version: version)
    }

    // MARK: - Register / round-trip

    func test_register_thenDiscover_returnsTheRecord() throws {
        let r = record(pid: 4242)
        try InstanceRegistry.register(r, in: dir)
        let found = InstanceRegistry.discover(in: dir, isAlive: { _ in true })
        XCTAssertEqual(found.count, 1)
        let back = try XCTUnwrap(found.first)
        XCTAssertEqual(back.pid, r.pid)
        XCTAssertEqual(back.endpoint, r.endpoint)
        XCTAssertEqual(back.version, r.version)
        // ISO-8601 persistence drops sub-second precision, so compare the date
        // at whole-second granularity rather than exact `Date` equality.
        XCTAssertEqual(
            back.launchDate.timeIntervalSince1970, r.launchDate.timeIntervalSince1970,
            accuracy: 1.0)
    }

    func test_register_writesPidNamedFile() throws {
        try InstanceRegistry.register(record(pid: 999), in: dir)
        let url = InstanceRegistry.recordURL(for: 999, in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "999.json")
    }

    func test_register_createsMissingDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        try InstanceRegistry.register(record(pid: 1), in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func test_register_isAtomicReplace_lastWriteWins() throws {
        try InstanceRegistry.register(record(pid: 5, endpoint: "old"), in: dir)
        try InstanceRegistry.register(record(pid: 5, endpoint: "new"), in: dir)
        let found = InstanceRegistry.discover(in: dir, isAlive: { _ in true })
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.endpoint, "new")
    }

    // MARK: - Discover / liveness pruning

    func test_discover_emptyDirectory_returnsEmpty() {
        XCTAssertTrue(InstanceRegistry.discover(in: dir, isAlive: { _ in true }).isEmpty)
    }

    func test_discover_missingDirectory_returnsEmpty_noThrow() {
        let nope = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertTrue(InstanceRegistry.discover(in: nope, isAlive: { _ in true }).isEmpty)
    }

    func test_discover_dropsDeadPids() throws {
        try InstanceRegistry.register(record(pid: 100), in: dir)
        try InstanceRegistry.register(record(pid: 200), in: dir)
        let live = InstanceRegistry.discover(in: dir, isAlive: { $0 == 100 }, pruneStale: false)
        XCTAssertEqual(live.map(\.pid), [100])
    }

    func test_discover_prunesStaleFiles_byDefault() throws {
        try InstanceRegistry.register(record(pid: 300), in: dir)
        // 300 is dead; default pruneStale=true should delete its file.
        _ = InstanceRegistry.discover(in: dir, isAlive: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: InstanceRegistry.recordURL(for: 300, in: dir).path))
    }

    func test_discover_pruneStaleFalse_leavesFile() throws {
        try InstanceRegistry.register(record(pid: 301), in: dir)
        _ = InstanceRegistry.discover(in: dir, isAlive: { _ in false }, pruneStale: false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: InstanceRegistry.recordURL(for: 301, in: dir).path))
    }

    func test_discover_prunesCorruptFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = InstanceRegistry.recordURL(for: 7, in: dir)
        try Data("{not json".utf8).write(to: bad)
        let live = InstanceRegistry.discover(in: dir, isAlive: { _ in true })
        XCTAssertTrue(live.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }

    func test_discover_rejectsPidFileNameMismatch() throws {
        // A file whose name doesn't match its embedded pid is treated as stale
        // (hand-edited / corrupt), even if the pid is "alive".
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = record(pid: 555)
        let data = try InstanceRegistry.encoder.encode(r)
        try data.write(to: dir.appendingPathComponent("111.json"))
        let live = InstanceRegistry.discover(in: dir, isAlive: { _ in true }, pruneStale: false)
        XCTAssertTrue(live.isEmpty)
    }

    func test_discover_ignoresNonJSONFiles() throws {
        try InstanceRegistry.register(record(pid: 12), in: dir)
        try Data("noise".utf8).write(to: dir.appendingPathComponent("README.txt"))
        let live = InstanceRegistry.discover(in: dir, isAlive: { _ in true }, pruneStale: false)
        XCTAssertEqual(live.map(\.pid), [12])
    }

    // MARK: - Ordering / selection

    func test_discover_sortsNewestLaunchFirst() throws {
        try InstanceRegistry.register(record(pid: 1, secondsAgo: 30), in: dir)
        try InstanceRegistry.register(record(pid: 2, secondsAgo: 5), in: dir)
        try InstanceRegistry.register(record(pid: 3, secondsAgo: 60), in: dir)
        let live = InstanceRegistry.discover(in: dir, isAlive: { _ in true })
        XCTAssertEqual(live.map(\.pid), [2, 1, 3])
    }

    func test_mostRecent_picksNewestLive() throws {
        try InstanceRegistry.register(record(pid: 10, secondsAgo: 50), in: dir)
        try InstanceRegistry.register(record(pid: 20, secondsAgo: 1), in: dir)
        let picked = InstanceRegistry.mostRecent(in: dir, isAlive: { _ in true })
        XCTAssertEqual(picked?.pid, 20)
    }

    func test_mostRecent_skipsDead_picksNewestSurvivor() throws {
        try InstanceRegistry.register(record(pid: 10, secondsAgo: 50), in: dir)
        try InstanceRegistry.register(record(pid: 20, secondsAgo: 1), in: dir)
        // The newest (20) is dead → fall through to 10.
        let picked = InstanceRegistry.mostRecent(in: dir, isAlive: { $0 == 10 })
        XCTAssertEqual(picked?.pid, 10)
    }

    func test_mostRecent_noLiveInstance_returnsNil() throws {
        try InstanceRegistry.register(record(pid: 10), in: dir)
        XCTAssertNil(InstanceRegistry.mostRecent(in: dir, isAlive: { _ in false }))
    }

    // MARK: - Deregister

    func test_deregister_removesRecord() throws {
        try InstanceRegistry.register(record(pid: 77), in: dir)
        InstanceRegistry.deregister(pid: 77, in: dir)
        XCTAssertTrue(InstanceRegistry.discover(in: dir, isAlive: { _ in true }).isEmpty)
    }

    func test_deregister_missingFile_isNoOp() {
        // No throw, no crash on a pid that was never registered.
        InstanceRegistry.deregister(pid: 12345, in: dir)
    }

    // MARK: - Liveness probe (real)

    func test_isPidAlive_selfIsAlive() {
        XCTAssertTrue(InstanceRegistry.isPidAlive(ProcessInfo.processInfo.processIdentifier))
    }

    func test_isPidAlive_zeroAndNegative_areDead() {
        XCTAssertFalse(InstanceRegistry.isPidAlive(0))
        XCTAssertFalse(InstanceRegistry.isPidAlive(-1))
    }

    func test_isPidAlive_unusedHighPid_isDead() {
        // PIDs are capped well below this on macOS; treat as a free pid.
        XCTAssertFalse(InstanceRegistry.isPidAlive(2_000_000_000))
    }

    // MARK: - Command envelope

    func test_message_open_roundTrips() throws {
        let msg = InstanceRegistry.InstanceMessage(
            id: "abc", command: .open(paths: ["/a.md", "/b/c.json"]))
        let data = try InstanceRegistry.encodeMessage(msg)
        let back = try InstanceRegistry.decodeMessage(data)
        XCTAssertEqual(back, msg)
        XCTAssertEqual(back.proto, InstanceRegistry.InstanceMessage.currentProtocol)
    }

    func test_message_allCommands_roundTrip() throws {
        let commands: [InstanceRegistry.InstanceCommand] = [
            .open(paths: ["/x"]), .activate, .newWindow, .ping,
        ]
        for c in commands {
            let msg = InstanceRegistry.InstanceMessage(id: "id", command: c)
            let back = try InstanceRegistry.decodeMessage(InstanceRegistry.encodeMessage(msg))
            XCTAssertEqual(back.command, c)
        }
    }

    func test_messageForLaunch_withPaths_isOpen() {
        let m = InstanceRegistry.messageForLaunch(paths: ["/a", "/b"], id: "i")
        XCTAssertEqual(m.command, .open(paths: ["/a", "/b"]))
    }

    func test_messageForLaunch_noPaths_isActivate() {
        let m = InstanceRegistry.messageForLaunch(paths: [], id: "i")
        XCTAssertEqual(m.command, .activate)
    }

    func test_decodeMessage_corruptData_throws() {
        XCTAssertThrowsError(try InstanceRegistry.decodeMessage(Data("garbage".utf8)))
    }
}
