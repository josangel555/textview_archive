import XCTest
@testable import ViewerCore

/// TSK-1473 — the collision-safe output-naming primitive (never overwrite).
final class OutputNamingTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/out")
    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func test_noCollision_returnsDesired() {
        let out = OutputNaming.nonColliding(desired: url("pic.png")) { _ in false }
        XCTAssertEqual(out, url("pic.png"))
    }

    func test_oneCollision_appendsDash2() {
        let taken: Set<String> = [url("pic.png").path]
        let out = OutputNaming.nonColliding(desired: url("pic.png")) { taken.contains($0.path) }
        XCTAssertEqual(out, url("pic-2.png"))
    }

    func test_runOfCollisions_findsFirstFree() {
        let taken: Set<String> = [
            url("pic.png").path, url("pic-2.png").path, url("pic-3.png").path,
        ]
        let out = OutputNaming.nonColliding(desired: url("pic.png")) { taken.contains($0.path) }
        XCTAssertEqual(out, url("pic-4.png"))
    }

    func test_extensionless_getsBareDashN() {
        let taken: Set<String> = [url("README").path]
        let out = OutputNaming.nonColliding(desired: url("README")) { taken.contains($0.path) }
        XCTAssertEqual(out, url("README-2"))
    }

    func test_multiDot_keepsOnlyLastExtension() {
        let taken: Set<String> = [url("archive.tar.gz").path]
        let out = OutputNaming.nonColliding(desired: url("archive.tar.gz")) { taken.contains($0.path) }
        XCTAssertEqual(out, url("archive.tar-2.gz"), "suffix splits at the LAST dot")
    }

    func test_neverReturnsAnExistingPath() {
        // Fuzz-ish: whatever the taken set, the result must be free (unless exhausted).
        let taken: Set<String> = [
            url("f.txt").path, url("f-2.txt").path, url("f-3.txt").path, url("f-4.txt").path,
        ]
        let out = OutputNaming.nonColliding(desired: url("f.txt")) { taken.contains($0.path) }
        XCTAssertFalse(taken.contains(out.path), "the chosen URL is always free")
        XCTAssertEqual(out, url("f-5.txt"))
    }

    func test_exhaustion_returnsLastCandidate_notInfiniteLoop() {
        // Every candidate collides → returns the last (write then fails loudly).
        let out = OutputNaming.nonColliding(desired: url("x.png"),
                                            exists: { _ in true }, maxAttempts: 5)
        XCTAssertEqual(out, url("x-5.png"))
    }

    func test_preservesDirectory() {
        let deep = URL(fileURLWithPath: "/a/b/c/pic.png")
        let taken: Set<String> = [deep.path]
        let out = OutputNaming.nonColliding(desired: deep) { taken.contains($0.path) }
        XCTAssertEqual(out, URL(fileURLWithPath: "/a/b/c/pic-2.png"))
    }
}
