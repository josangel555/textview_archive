import XCTest
@testable import ViewerCore
import ViewerKit

/// Host tests for the per-filename view-mode lock (TSK-811): the override
/// store's put/get/clear + persistence, and the pure resolution function
/// (locked mode wins over the inferred default for a matching name/ext, but
/// only when it's in `availableModes`; non-matching falls back to inferred).
final class ViewModeLockStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewModeLockStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        storeURL = tmpDir.appendingPathComponent("view-mode-locks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/me/docs/\(name)")
    }

    // MARK: - lock / get / clear

    func test_lock_thenLockedModeReturnsIt() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("notes.txt")
        XCTAssertNil(store.lockedMode(for: u))
        XCTAssertFalse(store.isLocked(for: u))

        store.lock(u, to: .editor)
        XCTAssertEqual(store.lockedMode(for: u), .editor)
        XCTAssertTrue(store.isLocked(for: u))
        XCTAssertEqual(store.count, 1)
    }

    func test_lock_isCaseInsensitiveOnFilename() {
        // macOS default FS is case-insensitive — a lock set on `Notes.TXT`
        // must apply when the same file reopens as `notes.txt`.
        let store = ViewModeLockStore(storeURL: storeURL)
        store.lock(url("Notes.TXT"), to: .rendered)
        XCTAssertEqual(store.lockedMode(for: url("notes.txt")), .rendered)
    }

    func test_lock_overwritesExistingNameLock() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("a.json")
        store.lock(u, to: .formatted)
        store.lock(u, to: .hex)
        XCTAssertEqual(store.lockedMode(for: u), .hex)
        XCTAssertEqual(store.count, 1)
    }

    func test_clear_removesLock() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("a.md")
        store.lock(u, to: .source)
        XCTAssertTrue(store.clear(for: u))
        XCTAssertNil(store.lockedMode(for: u))
        XCTAssertFalse(store.isLocked(for: u))
        // Clearing an already-cleared file is a no-op (returns false).
        XCTAssertFalse(store.clear(for: u))
    }

    func test_clear_removesBothNameAndExtensionLocksForFile() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("report.csv")
        store.lock(u, to: .table)            // name key
        store.lockExtension(u, to: .source)  // .csv key
        XCTAssertEqual(store.count, 2)
        XCTAssertTrue(store.clear(for: u))
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.lockedMode(for: u))
    }

    func test_clearAll_dropsEverything() {
        let store = ViewModeLockStore(storeURL: storeURL)
        store.lock(url("a.txt"), to: .editor)
        store.lock(url("b.md"), to: .source)
        XCTAssertEqual(store.count, 2)
        store.clearAll()
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - extension locks + precedence

    func test_extensionLock_appliesToAnyFileOfThatExtension() {
        let store = ViewModeLockStore(storeURL: storeURL)
        store.lockExtension(url("anything.log"), to: .hex)
        XCTAssertEqual(store.lockedMode(for: url("other.log")), .hex)
        XCTAssertEqual(store.lockedMode(for: url("deep.LOG")), .hex)  // case-insensitive ext
        XCTAssertNil(store.lockedMode(for: url("nope.txt")))
    }

    func test_exactNameLockBeatsExtensionLock() {
        let store = ViewModeLockStore(storeURL: storeURL)
        store.lockExtension(url("x.txt"), to: .hex)     // all .txt → hex
        store.lock(url("special.txt"), to: .rendered)   // this file → rendered
        XCTAssertEqual(store.lockedMode(for: url("special.txt")), .rendered)
        XCTAssertEqual(store.lockedMode(for: url("plain.txt")), .hex)
    }

    func test_extensionlessFile_onlyNameKeyApplies() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("Makefile")
        // No extension → lockExtension is a no-op.
        store.lockExtension(u, to: .hex)
        XCTAssertNil(store.lockedMode(for: u))
        XCTAssertEqual(store.count, 0)
        // Exact-name lock still works.
        store.lock(u, to: .source)
        XCTAssertEqual(store.lockedMode(for: u), .source)
    }

    // MARK: - toggle (the lock-icon click)

    func test_toggle_locksWhenUnlocked_clearsWhenLocked() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("a.txt")
        XCTAssertEqual(store.toggle(u, mode: .editor), .editor) // locks
        XCTAssertEqual(store.lockedMode(for: u), .editor)
        XCTAssertNil(store.toggle(u, mode: .editor))            // clears
        XCTAssertFalse(store.isLocked(for: u))
    }

    func test_toggle_clearsEvenWhenLockedViaExtension() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("a.csv")
        store.lockExtension(u, to: .table)
        // Toggling a file locked by extension clears it (clear removes both keys).
        XCTAssertNil(store.toggle(u, mode: .source))
        XCTAssertFalse(store.isLocked(for: u))
    }

    // MARK: - resolvedMode (the pure resolution function)

    func test_resolvedMode_lockedWinsWhenAvailable() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("readme.md")
        store.lock(u, to: .source)
        // A .md file offers [.rendered, .source, .editor, .hex]; inferred
        // default is .rendered, but the lock pins .source.
        let avail = ViewModeOptions.availableModes(for: u, isRenderableText: true)
        let resolved = store.resolvedMode(
            for: u, available: avail, inferredDefault: .rendered)
        XCTAssertEqual(resolved, .source)
    }

    func test_resolvedMode_noLockFallsBackToInferred() {
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("readme.md")
        let avail = ViewModeOptions.availableModes(for: u, isRenderableText: true)
        let resolved = store.resolvedMode(
            for: u, available: avail, inferredDefault: .rendered)
        XCTAssertEqual(resolved, .rendered)
    }

    func test_resolvedMode_staleLockDegradesToInferred() {
        // A lock pins a mode the file can't satisfy (e.g. .table locked but the
        // file only offers source/editor/hex). It must NOT desync — fall back.
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("plain.txt")
        store.lock(u, to: .table)
        let avail = ViewModeOptions.availableModes(for: u, isRenderableText: true)
        XCTAssertFalse(avail.contains(.table))
        let resolved = store.resolvedMode(
            for: u, available: avail, inferredDefault: .source)
        XCTAssertEqual(resolved, .source)
    }

    func test_resolvedMode_onlyHonorsModesInAvailable() {
        // .rendered is NOT in a plain .txt's availableModes; even locked, it
        // degrades to the inferred default.
        let store = ViewModeLockStore(storeURL: storeURL)
        let u = url("plain.txt")
        store.lock(u, to: .rendered)
        let avail = ViewModeOptions.availableModes(for: u, isRenderableText: true)
        XCTAssertFalse(avail.contains(.rendered))
        let resolved = store.resolvedMode(
            for: u, available: avail, inferredDefault: .source)
        XCTAssertEqual(resolved, .source)
    }

    func test_resolvedMode_extensionLockResolvesForMatchingExtension() {
        // Lock all .json files to .formatted; a fresh .json resolves to it.
        let store = ViewModeLockStore(storeURL: storeURL)
        store.lockExtension(url("config.json"), to: .formatted)
        let u = url("other.json")
        let avail = ViewModeOptions.availableModes(for: u, isRenderableText: true)
        XCTAssertTrue(avail.contains(.formatted))
        let resolved = store.resolvedMode(
            for: u, available: avail, inferredDefault: .source)
        XCTAssertEqual(resolved, .formatted)
    }

    // MARK: - key derivation

    func test_keyDerivation() {
        XCTAssertEqual(ViewModeLockStore.nameKey(for: url("Foo.MD")), "foo.md")
        XCTAssertEqual(ViewModeLockStore.extensionKey(for: url("Foo.MD")), ".md")
        XCTAssertNil(ViewModeLockStore.extensionKey(for: url("Makefile")))
        XCTAssertEqual(ViewModeLockStore.nameKey(for: url("Makefile")), "makefile")
    }

    // MARK: - persistence

    func test_persistenceRoundTrip() {
        let s1 = ViewModeLockStore(storeURL: storeURL)
        s1.lock(url("a.txt"), to: .editor)
        s1.lockExtension(url("x.csv"), to: .table)
        s1.flush()

        let s2 = ViewModeLockStore(storeURL: storeURL)
        XCTAssertEqual(s2.lockedMode(for: url("a.txt")), .editor)
        XCTAssertEqual(s2.lockedMode(for: url("anything.csv")), .table)
        XCTAssertEqual(s2.count, 2)
    }

    func test_persistence_clearSurvivesReopen() {
        let s1 = ViewModeLockStore(storeURL: storeURL)
        s1.lock(url("a.txt"), to: .editor)
        s1.flush()
        s1.clear(for: url("a.txt"))
        s1.flush()

        let s2 = ViewModeLockStore(storeURL: storeURL)
        XCTAssertNil(s2.lockedMode(for: url("a.txt")))
        XCTAssertEqual(s2.count, 0)
    }

    func test_load_tamperedFileDegradesGracefully() throws {
        // A map with an unknown ViewMode value drops that entry; valid ones survive.
        let json = #"{"a.txt":"editor","b.txt":"bogusmode"}"#
        try json.data(using: .utf8)!.write(to: storeURL)
        let store = ViewModeLockStore(storeURL: storeURL)
        XCTAssertEqual(store.lockedMode(for: url("a.txt")), .editor)
        XCTAssertNil(store.lockedMode(for: url("b.txt")))
    }

    func test_capRejectsNewKeysPastLimit() {
        let store = ViewModeLockStore(storeURL: storeURL, maxEntries: 2)
        store.lock(url("a.txt"), to: .source)
        store.lock(url("b.txt"), to: .source)
        store.lock(url("c.txt"), to: .source)  // past cap → ignored
        XCTAssertEqual(store.count, 2)
        XCTAssertNil(store.lockedMode(for: url("c.txt")))
        // Overwriting an EXISTING key at cap is still allowed.
        store.lock(url("a.txt"), to: .hex)
        XCTAssertEqual(store.lockedMode(for: url("a.txt")), .hex)
        XCTAssertEqual(store.count, 2)
    }
}
