import XCTest
@testable import ViewerCore

/// TOCTOU guard for bookmark targets (TSK-309). A bookmark stores a path; the
/// path can be re-pointed (symlink/dir swap, `mv`) between the moment it is
/// added and the moment it is opened. These tests pin the identity-capture +
/// open-time re-validation that refuses to follow a swapped target.
///
/// All scratch lives under `FileManager.temporaryDirectory` (per CLAUDE.md —
/// never `~/Documents`). Each test builds its own inode swap and asserts the
/// validator's verdict.
final class BookmarkTocTouTests: XCTestCase {

    private var root: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkTocTou-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeURL = root.appendingPathComponent("bookmarks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> BookmarksStore {
        JSONFileStore.flushSync()
        return BookmarksStore(storeURL: storeURL, maxEntries: 100)
    }

    private func writeFile(_ url: URL, _ contents: String = "x") throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Identity capture

    func test_capture_recordsDevInodeAndDirness_forFile() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        let id = try XCTUnwrap(BookmarkTargetIdentity.capture(at: f))
        XCTAssertFalse(id.isDirectory)
        XCTAssertGreaterThan(id.inode, 0)
        // resolvedPath is the realpath of the same file.
        XCTAssertEqual(URL(fileURLWithPath: id.resolvedPath).lastPathComponent, "a.md")
    }

    func test_capture_recordsDirness_forDirectory() throws {
        let d = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let id = try XCTUnwrap(BookmarkTargetIdentity.capture(at: d))
        XCTAssertTrue(id.isDirectory)
    }

    func test_capture_nonexistent_returnsNil() {
        let missing = root.appendingPathComponent("nope.md")
        XCTAssertNil(BookmarkTargetIdentity.capture(at: missing))
    }

    func test_capture_followsSymlink_toResolvedTarget() throws {
        // A symlink and its target share resolved identity (stat follows it).
        let target = root.appendingPathComponent("real.md")
        try writeFile(target)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let viaLink = try XCTUnwrap(BookmarkTargetIdentity.capture(at: link))
        let direct = try XCTUnwrap(BookmarkTargetIdentity.capture(at: target))
        XCTAssertEqual(viaLink.inode, direct.inode)
        XCTAssertEqual(viaLink.device, direct.device)
    }

    // MARK: - Validation verdicts

    func test_validate_unchangedFile_returnsOk() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        let id = BookmarkTargetIdentity.capture(at: f)
        XCTAssertEqual(BookmarkValidation.validate(url: f, against: id), .ok)
    }

    func test_validate_nilIdentity_returnsUnverified() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        // Legacy entry with no captured identity → never spuriously refused.
        XCTAssertEqual(BookmarkValidation.validate(url: f, against: nil), .unverified)
        XCTAssertTrue(BookmarkValidation.validate(url: f, against: nil).isSafeToOpen)
    }

    func test_validate_deletedTarget_returnsMissing() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        let id = BookmarkTargetIdentity.capture(at: f)
        try FileManager.default.removeItem(at: f)
        XCTAssertEqual(BookmarkValidation.validate(url: f, against: id), .missing)
        XCTAssertFalse(BookmarkValidation.validate(url: f, against: id).isSafeToOpen)
    }

    /// The core TOCTOU case: a path replaced by a DIFFERENT inode between add
    /// and open. We add a file, capture its identity, then atomically swap the
    /// SAME path to point at a new file (different inode) and assert mismatch.
    func test_validate_pathSwappedToDifferentInode_returnsIdentityChanged() throws {
        let path = root.appendingPathComponent("doc.md")
        try writeFile(path, "original")
        let id = try XCTUnwrap(BookmarkTargetIdentity.capture(at: path))

        // Swap: remove the original, drop a brand-new file at the same path.
        try FileManager.default.removeItem(at: path)
        try writeFile(path, "ATTACKER CONTENT")

        let verdict = BookmarkValidation.validate(url: path, against: id)
        guard case .identityChanged(let was, let now) = verdict else {
            return XCTFail("expected identityChanged, got \(verdict)")
        }
        XCTAssertNotEqual(was.inode, now.inode, "the swapped file must have a new inode")
        XCTAssertFalse(verdict.isSafeToOpen)
    }

    /// Symlink re-point: a bookmarked path is a symlink. Capture identity while
    /// it points at A; repoint it at B (different inode); validation must trip.
    func test_validate_symlinkRepointed_returnsIdentityChanged() throws {
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try writeFile(a, "A")
        try writeFile(b, "B")
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)

        let id = try XCTUnwrap(BookmarkTargetIdentity.capture(at: link))

        // Repoint the symlink at B.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)

        let verdict = BookmarkValidation.validate(url: link, against: id)
        XCTAssertFalse(verdict.isSafeToOpen,
                       "a repointed symlink must NOT be silently followed")
        guard case .identityChanged = verdict else {
            return XCTFail("expected identityChanged, got \(verdict)")
        }
    }

    /// File → directory swap at the same path is a mismatch even if dev/ino
    /// somehow collide: the dir-ness flag differs.
    func test_validate_fileSwappedToDirectory_returnsIdentityChanged() throws {
        let path = root.appendingPathComponent("thing")
        try writeFile(path, "i am a file")
        let id = try XCTUnwrap(BookmarkTargetIdentity.capture(at: path))
        XCTAssertFalse(id.isDirectory)

        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let verdict = BookmarkValidation.validate(url: path, against: id)
        XCTAssertFalse(verdict.isSafeToOpen)
        guard case .identityChanged = verdict else {
            return XCTFail("expected identityChanged, got \(verdict)")
        }
    }

    // MARK: - Store integration

    func test_store_add_capturesIdentity() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        let s = makeStore()
        let entry = s.add(url: f)
        XCTAssertNotNil(entry.identity, "add must snapshot the resolved target identity")
        XCTAssertEqual(s.validate(entry), .ok)
    }

    func test_store_validate_afterSwap_isRefused() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f, "v1")
        let s = makeStore()
        let entry = s.add(url: f)

        // TOCTOU swap of the same path.
        try FileManager.default.removeItem(at: f)
        try writeFile(f, "v2-different-inode")

        let verdict = s.validate(entry)
        XCTAssertFalse(verdict.isSafeToOpen,
                       "store.validate must refuse a swapped bookmark target")
    }

    func test_store_addToNonexistentPath_validatesUnverified() throws {
        // A bookmark to a path that doesn't exist yet (no identity captured)
        // must not be refused — it validates as unverified, not missing/changed.
        let ghost = root.appendingPathComponent("ghost.md")
        let s = makeStore()
        let entry = s.add(url: ghost)
        XCTAssertNil(entry.identity)
        XCTAssertEqual(s.validate(entry), .unverified)
    }

    // MARK: - Persistence round-trip

    func test_identity_survivesPersistenceRoundTrip() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        let s1 = makeStore()
        let added = s1.add(url: f)
        s1.flush()

        // Reopen from disk — the persisted identity must decode and still
        // validate ok against the unchanged file.
        let s2 = makeStore()
        let reloaded = try XCTUnwrap(s2.all().first(where: { $0.url == added.url }))
        XCTAssertEqual(reloaded.identity, added.identity,
                       "identity must round-trip through JSON unchanged")
        XCTAssertEqual(s2.validate(reloaded), .ok)
    }

    /// A bookmarks.json written before identity tracking (no `identity` key)
    /// must decode with nil identity → unverified, never crash or refuse.
    func test_legacyEntryWithoutIdentity_decodesUnverified() throws {
        let f = root.appendingPathComponent("a.md")
        try writeFile(f)
        // Hand-write a legacy entry (no `identity` field).
        let legacy = """
        [{"url":"\(f.absoluteString)","addedAt":0,"displayName":"a.md"}]
        """
        try legacy.write(to: storeURL, atomically: true, encoding: .utf8)

        let s = makeStore()
        let entry = try XCTUnwrap(s.all().first)
        XCTAssertNil(entry.identity)
        XCTAssertEqual(s.validate(entry), .unverified)
    }
}
