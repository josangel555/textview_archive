import XCTest
@testable import ViewerCore

/// Headless coverage for `NewFileCreator` (File ▸ New / folder ▸ New File core).
/// All scratch in a per-test temp dir — never touches ~/Documents etc.
final class NewFileCreatorTests: XCTestCase {

    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func test_create_inEmptyDir_usesBaseName_andIsEmpty() throws {
        let url = try NewFileCreator.create(in: dir)
        XCTAssertEqual(url.lastPathComponent, "Untitled.txt")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 0, "new file is empty")
    }

    func test_create_twice_numbersTheSecond() throws {
        let a = try NewFileCreator.create(in: dir)
        let b = try NewFileCreator.create(in: dir)
        XCTAssertEqual(a.lastPathComponent, "Untitled.txt")
        XCTAssertEqual(b.lastPathComponent, "Untitled 2.txt")
        XCTAssertTrue(exists("Untitled.txt") && exists("Untitled 2.txt"))
    }

    func test_create_numbersBeforeExtension() throws {
        _ = try NewFileCreator.create(in: dir, baseName: "notes.md")
        let b = try NewFileCreator.create(in: dir, baseName: "notes.md")
        XCTAssertEqual(b.lastPathComponent, "notes 2.md")
    }

    func test_create_extensionlessBase() throws {
        _ = try NewFileCreator.create(in: dir, baseName: "README")
        let b = try NewFileCreator.create(in: dir, baseName: "README")
        XCTAssertEqual(b.lastPathComponent, "README 2")
    }

    func test_create_doesNotClobberExistingContent() throws {
        // Pre-place a file at the base name with content.
        let existing = dir.appendingPathComponent("Untitled.txt")
        try Data("DO NOT LOSE".utf8).write(to: existing)
        let created = try NewFileCreator.create(in: dir)
        XCTAssertEqual(created.lastPathComponent, "Untitled 2.txt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "DO NOT LOSE",
                       "existing file's content must be untouched")
    }

    func test_create_missingDirectory_throws() {
        let missing = dir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try NewFileCreator.create(in: missing)) { err in
            guard case NewFileCreator.CreateError.notADirectory = err else {
                return XCTFail("expected .notADirectory, got \(err)")
            }
        }
    }

    func test_create_fileURLAsDirectory_throws() throws {
        let f = dir.appendingPathComponent("a-file")
        try Data().write(to: f)
        XCTAssertThrowsError(try NewFileCreator.create(in: f))  // not a directory
    }

    // Pure helpers.
    func test_splitName() {
        XCTAssertEqual(NewFileCreator.splitName("a.txt").stem, "a")
        XCTAssertEqual(NewFileCreator.splitName("a.txt").ext, "txt")
        XCTAssertEqual(NewFileCreator.splitName("a.b.c").stem, "a.b")
        XCTAssertEqual(NewFileCreator.splitName("a.b.c").ext, "c")
        XCTAssertEqual(NewFileCreator.splitName("README").ext, "")
        XCTAssertEqual(NewFileCreator.splitName(".gitignore").ext, "", "leading-dot file is all stem")
        XCTAssertEqual(NewFileCreator.splitName(".gitignore").stem, ".gitignore")
    }

    func test_nameSequence() {
        XCTAssertEqual(NewFileCreator.name(stem: "Untitled", ext: "txt", index: 1), "Untitled.txt")
        XCTAssertEqual(NewFileCreator.name(stem: "Untitled", ext: "txt", index: 2), "Untitled 2.txt")
        XCTAssertEqual(NewFileCreator.name(stem: "x", ext: "", index: 3), "x 3")
    }

    // The documented safety guarantee: concurrent calls can't stomp each other.
    // This is what the O_CREAT|O_EXCL atomic claim buys — a fileExists-then-
    // create refactor would fail this (duplicate names / lost files).
    func test_create_concurrent_allDistinct_noClobber() {
        let n = 12
        let lock = NSLock()
        var urls: [URL] = []
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            do {
                let u = try NewFileCreator.create(in: dir, baseName: "race.txt")
                lock.lock(); urls.append(u); lock.unlock()
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "no concurrent create should error: \(errors)")
        XCTAssertEqual(urls.count, n)
        XCTAssertEqual(Set(urls.map { $0.lastPathComponent }).count, n,
                       "every concurrent create must get a distinct name")
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("race") }
        XCTAssertEqual(onDisk.count, n, "exactly \(n) files created, none clobbered")
    }

    // Path-traversal guard: a base name with a separator (or `.`/`..`) must be
    // rejected so creation can't escape `directory`.
    func test_create_rejectsPathSeparatorInBaseName() {
        for bad in ["../evil.txt", "a/b.txt", "/etc/x", "..", "."] {
            XCTAssertThrowsError(try NewFileCreator.create(in: dir, baseName: bad)) { err in
                guard case NewFileCreator.CreateError.invalidName = err else {
                    return XCTFail("expected .invalidName for \(bad), got \(err)")
                }
            }
        }
        let escaped = dir.deletingLastPathComponent().appendingPathComponent("evil.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path),
                       "traversal must not have created a file outside the dir")
    }
}
