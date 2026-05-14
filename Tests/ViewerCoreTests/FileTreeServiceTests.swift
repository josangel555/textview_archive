import XCTest
@testable import ViewerCore

final class FileTreeServiceTests: XCTestCase {
    private var tmpDir: URL!
    private let service = FileTreeService()

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTreeServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func touch(_ name: String) -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func mkdir(_ name: String) -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Sorting

    func test_directoriesListedBeforeFiles() throws {
        touch("a.txt")
        touch("z.txt")
        mkdir("zzz_folder")
        let nodes = try service.children(of: tmpDir)
        XCTAssertEqual(nodes.map { $0.isDirectory },
                       [true, false, false])
    }

    func test_alphabeticalWithinGroup() throws {
        touch("b.md")
        touch("a.md")
        touch("c.md")
        mkdir("zeta")
        mkdir("alpha")
        let nodes = try service.children(of: tmpDir)
        XCTAssertEqual(nodes.map { $0.name },
                       ["alpha", "zeta", "a.md", "b.md", "c.md"])
    }

    func test_naturalNumericOrdering() throws {
        // localizedStandardCompare treats "10" > "2" (vs lexicographic "10" < "2").
        touch("file2.txt")
        touch("file10.txt")
        touch("file1.txt")
        let nodes = try service.children(of: tmpDir)
        XCTAssertEqual(nodes.map { $0.name },
                       ["file1.txt", "file2.txt", "file10.txt"])
    }

    // MARK: Hidden files

    func test_hiddenFilesSkippedByDefault() throws {
        touch("visible.md")
        touch(".hidden")
        let nodes = try service.children(of: tmpDir)
        XCTAssertEqual(nodes.map { $0.name }, ["visible.md"])
    }

    func test_hiddenFilesIncludedWhenRequested() throws {
        touch("visible.md")
        touch(".hidden")
        let nodes = try service.children(of: tmpDir, includeHidden: true)
        XCTAssertEqual(Set(nodes.map { $0.name }), [".hidden", "visible.md"])
    }

    // MARK: Empty / edge cases

    func test_emptyDirectoryReturnsEmpty() throws {
        XCTAssertEqual(try service.children(of: tmpDir), [])
    }

    func test_throwsOnMissingDirectory() {
        let url = tmpDir.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try service.children(of: url)) { error in
            XCTAssertEqual(error as? FileTreeError, .notFound)
        }
    }

    func test_throwsOnFileAsDirectory() {
        let file = touch("a-file.txt")
        XCTAssertThrowsError(try service.children(of: file)) { error in
            XCTAssertEqual(error as? FileTreeError, .notDirectory)
        }
    }

    // MARK: FileNode identity

    func test_fileNode_idIsURL() {
        let n = FileNode(url: URL(fileURLWithPath: "/a"), name: "a", isDirectory: false)
        XCTAssertEqual(n.id, URL(fileURLWithPath: "/a"))
    }
}
