import XCTest
@testable import ViewerCore

final class EditorBufferTests: XCTestCase {

    // MARK: - Dirty flag

    func test_freshBuffer_isClean() {
        let buf = EditorBuffer(url: URL(fileURLWithPath: "/tmp/x.txt"), original: "hello")
        XCTAssertFalse(buf.isDirty)
    }

    func test_setText_flipsDirty() {
        var buf = EditorBuffer(url: URL(fileURLWithPath: "/tmp/x.txt"), original: "hello")
        buf.setText("hello world")
        XCTAssertTrue(buf.isDirty)
    }

    func test_setSameText_staysClean() {
        var buf = EditorBuffer(url: URL(fileURLWithPath: "/tmp/x.txt"), original: "hello")
        buf.setText("hello")
        XCTAssertFalse(buf.isDirty)
    }

    func test_revertToOriginal_becomesClean() {
        var buf = EditorBuffer(url: URL(fileURLWithPath: "/tmp/x.txt"), original: "abc")
        buf.setText("abcd")
        XCTAssertTrue(buf.isDirty)
        buf.setText("abc")
        XCTAssertFalse(buf.isDirty)
    }

    func test_refreshSavedFingerprint_keepsDirtyAndBaseline() {
        // S1-A: "Keep My Edits" branch must preserve `originalText`
        // (so isDirty stays true and a future Revert still works)
        // while bumping the disk fingerprint so the next duplicate
        // watcher event doesn't re-prompt.
        var buf = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/x.txt"),
            original: "baseline",
            lastSavedMTime: Date(timeIntervalSince1970: 100),
            lastSavedSize: 8
        )
        buf.setText("baseline + my edits")
        XCTAssertTrue(buf.isDirty)
        let newMTime = Date(timeIntervalSince1970: 200)
        let newSize = 99  // disk size (other process wrote something)
        buf.refreshSavedFingerprint(diskMTime: newMTime, diskSize: newSize)
        // Baseline unchanged → still dirty.
        XCTAssertTrue(
            buf.isDirty,
            "refreshSavedFingerprint must not collapse dirt"
        )
        XCTAssertEqual(buf.originalText, "baseline")
        XCTAssertEqual(buf.text, "baseline + my edits")
        // Fingerprint updated → watcher sees no external edit at new size.
        XCTAssertFalse(
            buf.hasExternalEdit(currentMTime: newMTime, currentSize: newSize),
            "duplicate watcher event for same write should be silent"
        )
        // But a later, different write IS still detected.
        XCTAssertTrue(
            buf.hasExternalEdit(
                currentMTime: newMTime.addingTimeInterval(10), currentSize: newSize
            )
        )
    }

    func test_markSaved_clearsDirty_andRefreshesBaseline() {
        var buf = EditorBuffer(url: URL(fileURLWithPath: "/tmp/x.txt"), original: "v1")
        buf.setText("v2")
        XCTAssertTrue(buf.isDirty)
        let now = Date(timeIntervalSince1970: 1_000)
        buf.markSaved(diskMTime: now, diskSize: 2)
        XCTAssertFalse(buf.isDirty)
        XCTAssertEqual(buf.lastSavedMTime, now)
        XCTAssertEqual(buf.lastSavedSize, 2)
        // Further edits go dirty against the NEW baseline.
        buf.setText("v3")
        XCTAssertTrue(buf.isDirty)
    }

    // MARK: - External edit detection

    func test_externalEdit_mtimeChange() {
        let saved = Date(timeIntervalSince1970: 1_000)
        let buf = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/x.txt"), original: "hi",
            lastSavedMTime: saved, lastSavedSize: 2
        )
        XCTAssertFalse(
            buf.hasExternalEdit(currentMTime: saved, currentSize: 2),
            "same fingerprint should not look external"
        )
        XCTAssertTrue(
            buf.hasExternalEdit(currentMTime: saved.addingTimeInterval(5), currentSize: 2),
            "different mtime should signal external edit"
        )
    }

    func test_externalEdit_sizeChange() {
        let saved = Date(timeIntervalSince1970: 1_000)
        let buf = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/x.txt"), original: "hi",
            lastSavedMTime: saved, lastSavedSize: 2
        )
        XCTAssertTrue(
            buf.hasExternalEdit(currentMTime: saved, currentSize: 3),
            "different size should signal external edit"
        )
    }

    func test_externalEdit_noBaseline_returnsFalse() {
        // Buffers never bound to a fingerprint can't tell — that's
        // documented behavior. Caller decides what to do.
        let buf = EditorBuffer(url: URL(fileURLWithPath: "/tmp/x.txt"), original: "hi")
        XCTAssertFalse(buf.hasExternalEdit(currentMTime: Date(), currentSize: 99))
    }

    // MARK: - Save round trip

    func test_save_writesFile_thenReloadEquals() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        var buf = EditorBuffer(url: url, original: "hello")
        buf.setText("hello\nworld\n")

        let stamp = try EditorWriter.save(buf.text, to: buf.url)
        XCTAssertNotNil(stamp.mtime)
        XCTAssertEqual(stamp.size, "hello\nworld\n".utf8.count)

        let reloaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(reloaded, "hello\nworld\n")
    }

    func test_save_isAtomic_overwritesExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        try "first".write(to: url, atomically: true, encoding: .utf8)

        _ = try EditorWriter.save("second", to: url)
        let reloaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(reloaded, "second")
    }

    func test_load_thenSave_thenLoad_clearsDirty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        try "alpha".write(to: url, atomically: true, encoding: .utf8)

        var buf = try EditorBuffer.load(url: url)
        XCTAssertEqual(buf.text, "alpha")
        XCTAssertFalse(buf.isDirty)
        XCTAssertNotNil(buf.lastSavedMTime)
        XCTAssertEqual(buf.lastSavedSize, "alpha".utf8.count)

        buf.setText("beta")
        XCTAssertTrue(buf.isDirty)
        let stamp = try EditorWriter.save(buf.text, to: buf.url)
        buf.markSaved(diskMTime: stamp.mtime, diskSize: stamp.size)
        XCTAssertFalse(buf.isDirty)
        XCTAssertEqual(buf.lastSavedSize, "beta".utf8.count)
    }

    // MARK: - External-edit conflict simulation

    func test_simulatedDiskChange_whileDirty_isDetected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("conflict.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)

        var buf = try EditorBuffer.load(url: url)
        buf.setText("local edits")
        XCTAssertTrue(buf.isDirty)

        // Simulate an external write by another process. Sleep one
        // mtime tick so APFS's 1ns mtime resolution definitely
        // differs from our load timestamp.
        Thread.sleep(forTimeInterval: 0.05)
        try "external write".write(to: url, atomically: true, encoding: .utf8)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs[.modificationDate] as? Date
        let size = attrs[.size] as? Int
        XCTAssertTrue(
            buf.hasExternalEdit(currentMTime: mtime, currentSize: size),
            "post-external-write fingerprint should diverge from saved baseline"
        )
    }

    // MARK: - Encoding edge case

    func test_save_failsOnEncodingMismatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ascii.txt")
        // ASCII can't represent emoji — encoding step should throw.
        XCTAssertThrowsError(
            try EditorWriter.save("plain emoji \u{1F600}", to: url, encoding: .ascii)
        ) { err in
            guard case EditorWriteError.encodingFailed(let enc) = err else {
                return XCTFail("expected encodingFailed, got \(err)")
            }
            XCTAssertEqual(enc, .ascii)
        }
    }

    // MARK: - Symlink safety (S5.1, 2026-05-25)

    func test_save_refusesSymlinkTarget_byDefault() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Create a real file, then a symlink that points to it. Saving
        // through the symlink should refuse — otherwise Data.write would
        // replace the symlink with a regular file, breaking the user's
        // dotfile / config layout.
        let realFile = dir.appendingPathComponent("real.txt")
        try "real contents".write(to: realFile, atomically: true, encoding: .utf8)
        let linkFile = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: linkFile, withDestinationURL: realFile
        )
        XCTAssertThrowsError(
            try EditorWriter.save("new contents", to: linkFile)
        ) { err in
            guard case EditorWriteError.targetIsSymlink(let target) = err else {
                return XCTFail("expected targetIsSymlink, got \(err)")
            }
            XCTAssertTrue(target.hasSuffix("real.txt"))
        }
        // The original file must still contain its original bytes —
        // the refused save did NOT silently overwrite via the link.
        let still = try String(contentsOf: realFile, encoding: .utf8)
        XCTAssertEqual(still, "real contents")
    }

    func test_save_allowSymlinkOptIn_writesThroughLink() throws {
        // The opt-in path preserves the legacy "follow the link"
        // behavior for callers that have explicitly prompted the
        // user. Note: Data.write(.atomic) still replaces the symlink
        // with a regular file — the opt-in only suppresses the throw.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realFile = dir.appendingPathComponent("real.txt")
        try "real contents".write(to: realFile, atomically: true, encoding: .utf8)
        let linkFile = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: linkFile, withDestinationURL: realFile
        )
        _ = try EditorWriter.save(
            "new contents", to: linkFile, allowSymlink: true
        )
        // The new file lives where the link was (now a regular file).
        let written = try String(contentsOf: linkFile, encoding: .utf8)
        XCTAssertEqual(written, "new contents")
    }

    func test_save_regularFile_unchanged() throws {
        // Regression guard for the non-symlink case — the new
        // pre-check must not change behavior when the path is a
        // plain file.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        _ = try EditorWriter.save("y", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "y")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        // Per project rules — never write to ~/Documents etc. The
        // per-user /var/folders tmpdir is safe + isolated per test
        // run.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorBufferTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
