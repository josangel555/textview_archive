import XCTest
@testable import ViewerCore

/// TSK-842: pick the off-main deferral threshold by measuring how long
/// `TextFileLoader.load` (read + UTF-8 decode) takes by size. Env-gated; not in
/// the gate. Run: MDV_RUN_BENCH=1 swift test --filter TextFileLoaderBenchTests
final class TextFileLoaderBenchTests: XCTestCase {
    func testMeasureLoadBySize() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MDV_RUN_BENCH"] == "1",
            "bench: set MDV_RUN_BENCH=1")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-tfl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let line = "The quick brown fox jumps over the lazy dog 0123456789\n"
        let lineBytes = line.utf8.count
        for kb in [256, 512, 1024, 2048, 4096, 16384, 65536] {
            let target = kb * 1024
            let s = String(repeating: line, count: target / lineBytes)
            let url = dir.appendingPathComponent("f\(kb).txt")
            try s.write(to: url, atomically: true, encoding: .utf8)
            _ = try? TextFileLoader().load(url: url)  // warm FS cache
            let t0 = Date()
            _ = try TextFileLoader().load(url: url)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "[TFL-bench] %6d KB: %.2f ms", kb, ms))
        }
    }
}
