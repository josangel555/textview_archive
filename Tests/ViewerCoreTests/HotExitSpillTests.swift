import XCTest
@testable import ViewerCore

/// TSK-1026: sidecar spill for hot-exit unsaved buffers over the 1 MiB inline
/// cap. Exercises the helper against a scratch dir (never the real store).
final class HotExitSpillTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotexit-spill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_write_read_roundTrip_multiMiB() {
        let big = String(repeating: "x", count: 2 << 20)   // 2 MiB — over the inline cap
        let path = "/Users/me/big.txt"
        XCTAssertTrue(HotExitSpill.write(big, forPath: path, in: dir))
        XCTAssertEqual(HotExitSpill.read(forPath: path, in: dir), big,
                       "a >1 MiB unsaved buffer survives the spill round-trip")
    }

    func test_remove_clearsSpill() {
        let path = "/tmp/a.txt"
        HotExitSpill.write("hi", forPath: path, in: dir)
        XCTAssertNotNil(HotExitSpill.read(forPath: path, in: dir))
        HotExitSpill.remove(forPath: path, in: dir)
        XCTAssertNil(HotExitSpill.read(forPath: path, in: dir))
    }

    func test_distinctPaths_areIndependent() {
        HotExitSpill.write("A", forPath: "/x/a.txt", in: dir)
        HotExitSpill.write("B", forPath: "/x/b.txt", in: dir)
        XCTAssertEqual(HotExitSpill.read(forPath: "/x/a.txt", in: dir), "A")
        XCTAssertEqual(HotExitSpill.read(forPath: "/x/b.txt", in: dir), "B")
    }

    func test_pruneOrphans_dropsUnreferenced_keepsReferenced() {
        HotExitSpill.write("keep", forPath: "/x/keep.txt", in: dir)
        HotExitSpill.write("drop", forPath: "/x/drop.txt", in: dir)
        HotExitSpill.pruneOrphans(keepingPaths: ["/x/keep.txt"], in: dir)
        XCTAssertEqual(HotExitSpill.read(forPath: "/x/keep.txt", in: dir), "keep")
        XCTAssertNil(HotExitSpill.read(forPath: "/x/drop.txt", in: dir),
                     "an unreferenced spill is pruned")
    }
}
