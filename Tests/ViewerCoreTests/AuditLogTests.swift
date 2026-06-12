import XCTest
@testable import ViewerCore
import RustCore

/// AuditLog (TSK-636): JSONL shape, rotation, the kill switch, and the
/// transport-seam hook (failures recorded; the hook fires on both routing
/// outcomes). Paths/contents discipline: events carry paths and outcomes,
/// NEVER file contents.
final class AuditLogTests: XCTestCase {

    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var log: AuditLog!

    override func setUp() {
        super.setUp()
        suiteName = "AuditLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-audit-\(UUID().uuidString)", isDirectory: true)
        log = AuditLog(directory: dir, defaults: defaults)
    }

    override func tearDown() {
        log.closeForTesting()
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
        CoreTransportRegistry.auditHook = nil
        super.tearDown()
    }

    private func lines() -> [String] {
        log.closeForTesting()
        let text = (try? String(contentsOf: log.logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func test_events_areOneJSONObjectPerLine_sortedKeys() throws {
        log.record(.fileOpen, action: "open", target: "/tmp/a.md")
        log.record(.processSpawn, action: "git", target: "status", meta: ["repo": "/r"])
        let lines = lines()
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let obj = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(obj["ts"])
            XCTAssertNotNil(obj["kind"])
            XCTAssertNotNil(obj["action"])
            XCTAssertNotNil(obj["target"])
        }
        XCTAssertTrue(lines[0].contains("file.open"))
        XCTAssertTrue(lines[1].contains("\"repo\":\"\\/r\"") || lines[1].contains("\"repo\":\"/r\""))
    }

    func test_killSwitch_explicitFalseDisables() {
        defaults.set(false, forKey: AuditLog.enabledKey)
        log.record(.fileOpen, action: "open", target: "/tmp/a.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logURL.path),
                       "disabled log must not even create the file")
        // Re-enable: events flow again.
        defaults.set(true, forKey: AuditLog.enabledKey)
        log.record(.fileOpen, action: "open", target: "/tmp/b.md")
        XCTAssertEqual(lines().count, 1)
    }

    func test_rotation_movesToGenerationOne_andContinues() {
        // Shrink the threshold indirectly: write events until past 5MB is
        // impractical — instead exercise rotateLocked via the public seam:
        // many small events stay under the cap, so emulate by writing one
        // oversized meta blob per event until rotation triggers.
        let blob = String(repeating: "x", count: 512 * 1024)
        for i in 0..<12 {  // ~6 MB of events
            log.record(.fileOpen, action: "open", target: "/tmp/\(i)", meta: ["pad": blob])
        }
        log.closeForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.rotatedURL.path),
                      "rotation must produce audit.1.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.logURL.path),
                      "a fresh live file continues after rotation")
        let liveSize = (try? FileManager.default.attributesOfItem(atPath: log.logURL.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(liveSize ?? 0, Int(AuditLog.maxBytes))
    }

    /// Sendable capture box for the hook events.
    private final class Captured: @unchecked Sendable {
        let lock = NSLock()
        private(set) var events: [(String, String, Bool)] = []
        func append(_ e: (String, String, Bool)) {
            lock.lock()
            events.append(e)
            lock.unlock()
        }
        var snapshot: [(String, String, Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    func test_transportHook_firesOnFailure_viaTheRealSeam() throws {
        let captured = Captured()
        CoreTransportRegistry.auditHook = { method, transport, ok in
            captured.append((method, transport, ok))
        }
        defer { CoreTransportRegistry.auditHook = nil }
        // Success path:
        _ = try mdvCoreFindSearch(text: "x", pattern: "x", kind: "literal",
                                  caseSensitive: false, wholeWord: false)
        // Failure path (unknown method through the in-process table):
        XCTAssertThrowsError(try InProcessTransport().call("no.such", requestBody: [0x80]))
        let events = captured.snapshot
        XCTAssertTrue(events.contains { $0.0 == "find_search" && $0.2 },
                      "success audited")
        XCTAssertTrue(events.contains { $0.0 == "no.such" && !$0.2 },
                      "failure audited")
        XCTAssertTrue(events.allSatisfy { $0.1 == "in-process" })
    }
}
