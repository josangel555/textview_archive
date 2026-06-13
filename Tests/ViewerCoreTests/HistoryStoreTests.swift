import XCTest
@testable import ViewerCore

final class HistoryStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storeURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { self.current = start }
        func tick() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(1)
            return value
        }
    }

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_700_000_000),
                          maxEntries: Int = 100) -> HistoryStore {
        // P2: `save()` is now async/coalesced (off-main). A roundtrip test
        // that records into one store and reopens another reads from disk —
        // so drain any pending write from the prior store before this new
        // one loads. Deterministic + still exercises the real disk path.
        JSONFileStore.flushSync()
        let clock = TestClock(start: now)
        return HistoryStore(storeURL: storeURL, maxEntries: maxEntries) {
            clock.tick()
        }
    }

    private func makeFile(_ name: String) -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Recording

    func test_record_addsEntry() {
        let store = makeStore()
        let url = makeFile("a.md")
        let entry = store.record(url: url)
        XCTAssertEqual(entry.url.lastPathComponent, "a.md")
        XCTAssertEqual(store.count, 1)
    }

    func test_record_isNewestFirst() {
        let store = makeStore()
        let a = makeFile("a.md")
        let b = makeFile("b.md")
        store.record(url: a)
        store.record(url: b)
        let recent = store.recent()
        XCTAssertEqual(recent.map { $0.url.lastPathComponent }, ["b.md", "a.md"])
    }

    func test_record_sameURL_dedupesAndBumpsTimestamp() {
        let store = makeStore()
        let a = makeFile("a.md")
        let b = makeFile("b.md")
        store.record(url: a)
        store.record(url: b)
        store.record(url: a)  // bump a back to front
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.recent().map { $0.url.lastPathComponent }, ["a.md", "b.md"])
    }

    func test_record_normalizesURLs() {
        let store = makeStore()
        let raw = tmpDir.appendingPathComponent("./a.md")
        let clean = tmpDir.appendingPathComponent("a.md")
        try? "x".write(to: clean, atomically: true, encoding: .utf8)
        store.record(url: raw)
        store.record(url: clean)
        XCTAssertEqual(store.count, 1, "normalization should dedupe ./a.md with a.md")
    }

    // MARK: Cap

    func test_capLimit_dropsOldest() {
        let store = makeStore(maxEntries: 3)
        for i in 0..<5 {
            store.record(url: makeFile("f\(i).md"))
        }
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.recent().map { $0.url.lastPathComponent },
                       ["f4.md", "f3.md", "f2.md"])
    }

    // MARK: Remove / clear

    func test_remove() {
        let store = makeStore()
        let a = makeFile("a.md")
        let b = makeFile("b.md")
        store.record(url: a)
        store.record(url: b)
        store.remove(url: a)
        XCTAssertEqual(store.recent().map { $0.url.lastPathComponent }, ["b.md"])
    }

    func test_remove_missingURL_isNoop() {
        let store = makeStore()
        store.record(url: makeFile("a.md"))
        store.remove(url: tmpDir.appendingPathComponent("never.md"))
        XCTAssertEqual(store.count, 1)
    }

    func test_clear() {
        let store = makeStore()
        store.record(url: makeFile("a.md"))
        store.record(url: makeFile("b.md"))
        store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.recent(), [])
    }

    // MARK: Persistence

    func test_persistence_roundTrip() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let store = makeStore(now: now)
            store.record(url: makeFile("a.md"))
            store.record(url: makeFile("b.md"))
        }
        let reopened = makeStore(now: now)
        XCTAssertEqual(reopened.count, 2)
        XCTAssertEqual(reopened.recent().map { $0.url.lastPathComponent },
                       ["b.md", "a.md"])
    }

    func test_corruptStoreFile_returnsEmptyAndDoesNotCrash() throws {
        try Data("not json at all".utf8).write(to: storeURL)
        let store = makeStore()
        XCTAssertEqual(store.count, 0)
        // It should still be usable after the corrupt read.
        store.record(url: makeFile("a.md"))
        XCTAssertEqual(store.count, 1)
    }

    func test_persistence_capLimitAppliedOnLoad() {
        let now = Date()
        let big = makeStore(now: now, maxEntries: 100)
        for i in 0..<10 {
            big.record(url: makeFile("f\(i).md"))
        }
        // Now reopen with a tighter cap.
        let tight = makeStore(now: now, maxEntries: 3)
        XCTAssertEqual(tight.count, 3)
    }

    func test_folderKind_persists() {
        let store = makeStore()
        let folder = tmpDir.appendingPathComponent("docs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.record(url: folder, kind: .folder)
        let reopened = makeStore()
        XCTAssertEqual(reopened.recent().first?.kind, .folder)
    }

    func test_recent_limit() {
        let store = makeStore()
        for i in 0..<10 {
            store.record(url: makeFile("f\(i).md"))
        }
        XCTAssertEqual(store.recent(limit: 3).count, 3)
    }

    // S8 — tampered file beyond maxStoreFileBytes is treated as corrupt.
    func test_oversizedStoreFile_isIgnoredOnLoad() throws {
        // Write a structurally-valid (but huge) JSON array to the store URL.
        // It would parse fine; we want the *size* gate to refuse it before
        // decode even runs.
        let bigPath = String(repeating: "x", count: 5000)
        let entry = """
        {"id":"\(bigPath)","url":"file:///x","kind":"file","lastOpenedAt":"2026-05-14T00:00:00Z","displayName":"x"}
        """
        let arrayJSON = "[" + Array(repeating: entry, count: 500).joined(separator: ",") + "]"
        try arrayJSON.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(
            storeURL: storeURL,
            maxEntries: 100,
            maxStoreFileBytes: 10_000,  // way smaller than the file we just wrote
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        XCTAssertEqual(store.count, 0, "oversized store file should be skipped, not decoded")
    }

    // S8 — well-formed JSON with the wrong schema (array of strings) is
    // treated as corrupt and starts fresh, not crashed.
    func test_storeFile_validJSONWrongSchema_isTreatedAsEmpty() throws {
        try #"["just","strings","not","entries"]"#.write(
            to: storeURL, atomically: true, encoding: .utf8
        )
        let store = makeStore()
        XCTAssertEqual(store.count, 0)
        // And the store is still usable after that.
        store.record(url: makeFile("a.md"))
        XCTAssertEqual(store.count, 1)
    }

    // MARK: PERSIST-02 — one bad element must not nuke the whole store

    func test_oneMalformedEntry_doesNotDiscardTheRest() throws {
        // Two valid entries plus one element missing the required `url`
        // key. The lenient array decode must keep the two good ones and
        // drop only the bad element — not start from empty.
        let json = """
        [
          {"url":"file:///x/a.md","kind":"file",
           "lastOpenedAt":"2026-05-14T00:00:00Z","displayName":"a.md"},
          {"kind":"file","lastOpenedAt":"2026-05-14T00:00:00Z","displayName":"broken"},
          {"url":"file:///x/b.md","kind":"file",
           "lastOpenedAt":"2026-05-13T00:00:00Z","displayName":"b.md"}
        ]
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertEqual(store.count, 2,
            "the bad middle element should be dropped, the two valid ones kept (PERSIST-02)")
        XCTAssertEqual(Set(store.recent().map { $0.url.lastPathComponent }),
                       ["a.md", "b.md"])
    }

    // PERSIST-02 — an unknown `kind` from a newer build must not drop
    // the entry; it decodes to `.file` as a forward-compat fallback.
    func test_unknownKind_fallsBackToFile_andEntrySurvives() throws {
        let json = """
        [
          {"url":"file:///x/a.md","kind":"symlink",
           "lastOpenedAt":"2026-05-14T00:00:00Z","displayName":"a.md"}
        ]
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertEqual(store.count, 1, "unknown kind must not poison the entry")
        XCTAssertEqual(store.recent().first?.kind, .file,
                       "unknown kind should fall back to .file")
    }

    func test_emptyArray_loadsAsEmpty_notNil() throws {
        try "[]".write(to: storeURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertEqual(store.count, 0)
        store.record(url: makeFile("a.md"))
        XCTAssertEqual(store.count, 1)
    }

    // MARK: parentFolderLabel (TSK-763 — grey "(folder)" suffix)

    private func entry(_ path: String, kind: HistoryEntry.Kind = .file) -> HistoryEntry {
        HistoryEntry(url: URL(fileURLWithPath: path), kind: kind,
                     lastOpenedAt: Date(timeIntervalSince1970: 0))
    }

    func test_parentFolderLabel_immediateParentName() {
        XCTAssertEqual(entry("/Users/me/projects/notes.md").parentFolderLabel, "projects")
        // Folder entries report THEIR containing folder too.
        XCTAssertEqual(entry("/Users/me/projects/src", kind: .folder).parentFolderLabel, "projects")
    }

    func test_parentFolderLabel_homeAbbreviatesToTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home.appendingPathComponent("notes.md")
        XCTAssertEqual(HistoryEntry(url: file, kind: .file,
                                    lastOpenedAt: Date(timeIntervalSince1970: 0)).parentFolderLabel,
                       "~", "a file directly in the home dir shows ~, not the username")
    }

    func test_parentFolderLabel_fileAtRoot_showsSlash() {
        XCTAssertEqual(entry("/notes.md").parentFolderLabel, "/")
    }

    func test_parentFolderLabel_disambiguatesSameNameDifferentFolders() {
        // The whole point: two recents named the same get distinct suffixes.
        XCTAssertNotEqual(entry("/a/x/readme.md").parentFolderLabel,
                          entry("/a/y/readme.md").parentFolderLabel)
        XCTAssertEqual(entry("/a/x/readme.md").parentFolderLabel, "x")
        XCTAssertEqual(entry("/a/y/readme.md").parentFolderLabel, "y")
    }
}
