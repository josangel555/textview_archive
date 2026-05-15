import XCTest
@testable import ViewerCore

final class CrossFileSearchTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XSearch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func write(_ path: String, _ contents: String) -> URL {
        let url = tmpDir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_singleFile_match() {
        write("a.md", "alpha\nbeta needle here\ngamma\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].matches.count, 1)
        XCTAssertEqual(groups[0].matches[0].lineNumber, 2)
        XCTAssertEqual(groups[0].matches[0].line, "beta needle here")
    }

    func test_multipleFiles_multipleMatches() {
        write("a.md", "needle\n")
        write("b/sub.md", "needle in subdir\n")
        write("c.md", "no match\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 2)
        let names = Set(groups.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, Set(["a.md", "sub.md"]))
    }

    func test_caseInsensitive_byDefault() {
        write("a.md", "NEEDLE\nneedle\nNeedle\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].matches.count, 3)
    }

    func test_caseSensitive_optional() {
        write("a.md", "NEEDLE\nneedle\nNeedle\n")
        var opts = CrossFileSearch.Options()
        opts.caseSensitive = true
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle", options: opts)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].matches.count, 1)
        XCTAssertEqual(groups[0].matches[0].line, "needle")
    }

    func test_skipsBinaryFiles() {
        // Write a file with a NUL byte in the first 4KiB — should be skipped.
        let url = tmpDir.appendingPathComponent("img.bin")
        var bytes: [UInt8] = Array(repeating: 0xAA, count: 100)
        bytes.append(0x00)
        bytes.append(contentsOf: Array("needle".utf8))
        try? Data(bytes).write(to: url)
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertTrue(groups.isEmpty)
    }

    func test_skipsLargeFiles() {
        let url = tmpDir.appendingPathComponent("big.md")
        let big = String(repeating: "x", count: 200) + "\nneedle\n"
        let huge = String(repeating: big, count: 50_000)  // ~10 MiB
        try? huge.write(to: url, atomically: true, encoding: .utf8)
        var opts = CrossFileSearch.Options()
        opts.maxFileBytes = 1024  // tiny limit, ensure the file is skipped
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle", options: opts)
        XCTAssertTrue(groups.isEmpty)
    }

    func test_skipsVCSAndBuildDirs() {
        write(".git/index", "needle in git\n")
        write("node_modules/lib.js", "needle in node_modules\n")
        write(".build/cache", "needle in build\n")
        write("real.md", "needle in real file\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].url.lastPathComponent, "real.md")
    }

    func test_emptyQuery_returnsNothing() {
        write("a.md", "anything\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "")
        XCTAssertTrue(groups.isEmpty)
    }

    func test_maxResults_caps_totalMatches() {
        for i in 0..<10 {
            write("f\(i).md", "needle\n")
        }
        var opts = CrossFileSearch.Options()
        opts.maxResults = 3
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle", options: opts)
        let total = groups.reduce(0) { $0 + $1.matches.count }
        XCTAssertLessThanOrEqual(total, 3)
    }

    func test_matchRange_pointsAtNeedleInLine() {
        write("a.md", "hello WORLD foo\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "world")
        XCTAssertEqual(groups.count, 1)
        let m = groups[0].matches[0]
        XCTAssertNotNil(m.matchRange)
        if let r = m.matchRange {
            XCTAssertEqual(String(m.line[r]).lowercased(), "world")
        }
    }
}
