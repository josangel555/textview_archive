import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Audit THEME 1 ("editable-HEX path has NO conflict/no-clobber machinery",
/// fixed 2026-07-29). Three holes, each pinned here:
///   1. `saveHexEdits` wrote blind — an external write between load and ⌘S
///      was silently destroyed by the stale stash. Now a write-time stat
///      guard + explicit prompt (Cancel default).
///   2. The watcher's conflict branch keyed on an EDITOR buffer, which hex
///      tabs never have — a dirty hex tab silently auto-reloaded (and the
///      surviving stash then clobbered on save). Now the conflict banner.
///   3. The banner's resolver only handled editor buffers — hex resolution
///      routes through the unpreserved-discard confirm (binary can't go to
///      Local History, so no branch may pretend a copy exists).
@MainActor
final class HexConflictGuardTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexConflictGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "HexConflictGuard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// A hex-dirty tab whose no-clobber baseline matches the CURRENT file —
    /// the state a real load leaves behind.
    private func hexDirtyTab(
        _ model: DocumentModel, name: String = "bin.dat",
        disk: [UInt8] = [0x00, 0x01], edits: [UInt8] = [0xAA, 0xBB]
    ) throws -> (id: UUID, url: URL) {
        let url = tmpDir.appendingPathComponent(name)
        try Data(disk).write(to: url, options: .atomic)
        model.open(url: url)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        model.hexDiskBaseline[id] = HexDiskStamp.current(for: url)
        model.stashHexBytes(Data(edits), forTabID: id)
        model.setHexDirty(true, forTabID: id)
        return (id, url)
    }

    /// The file changes on disk with a DIFFERENT fingerprint. A bare rewrite
    /// can share the same second-granularity mtime AND size — set an mtime
    /// firmly in the past so the stamp always diverges.
    private func externalWrite(_ url: URL, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
    }

    // MARK: 1 — write-time guard

    func test_save_overDivergedDisk_prompts_andCancelAbortsTheWrite() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model)
        try externalWrite(url, [0xEE, 0xEE, 0xEE])

        var prompted = false
        model.hexOverwritePromptOverride = { _ in prompted = true; return .cancel }

        XCTAssertFalse(model.saveHexEdits(forTabID: id), "cancel must abort the save")
        XCTAssertTrue(prompted, "an external change must be surfaced, never overwritten silently")
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEE, 0xEE, 0xEE]),
                       "the external bytes survive a cancel")
        XCTAssertNotNil(model.peekHexDirtyBytesForTest(id), "the edits stay pending")
    }

    func test_save_overDivergedDisk_overwriteChoiceWrites() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model, edits: [0xAA, 0xBB])
        try externalWrite(url, [0xEE])
        model.hexOverwritePromptOverride = { _ in .overwrite }

        XCTAssertTrue(model.saveHexEdits(forTabID: id))
        XCTAssertEqual(try Data(contentsOf: url), Data([0xAA, 0xBB]),
                       "an explicit Overwrite writes the edits")
    }

    func test_save_withUnchangedDisk_neverPrompts() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model, edits: [0x42])
        var prompted = false
        model.hexOverwritePromptOverride = { _ in prompted = true; return .cancel }

        XCTAssertTrue(model.saveHexEdits(forTabID: id))
        XCTAssertFalse(prompted, "no divergence → the ordinary silent save")
        XCTAssertEqual(try Data(contentsOf: url), Data([0x42]))
    }

    /// After a save, the baseline tracks the WRITE — a second save must not
    /// false-positive against the original load stamp.
    func test_save_rebaselines_soTheNextSaveDoesNotFalseConflict() throws {
        let model = makeModel()
        let (id, _) = try hexDirtyTab(model, edits: [0x42])
        var prompts = 0
        model.hexOverwritePromptOverride = { _ in prompts += 1; return .cancel }

        XCTAssertTrue(model.saveHexEdits(forTabID: id))
        model.stashHexBytes(Data([0x43]), forTabID: id)
        model.setHexDirty(true, forTabID: id)
        XCTAssertTrue(model.saveHexEdits(forTabID: id), "second save is clean")
        XCTAssertEqual(prompts, 0)
    }

    // MARK: 3 — banner resolution for hex

    private func raiseConflict(_ model: DocumentModel, id: UUID, url: URL) {
        model.activeDiskConflict = DiskConflictBannerInfo(tabID: id, index: 0, url: url)
    }

    func test_takeDisk_confirms_thenDropsEditsAndReloads() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model)
        try externalWrite(url, [0xEE])
        raiseConflict(model, id: id, url: url)

        var asked: DocumentModel.ConflictSide?
        model.unpreservedDiscardPromptOverride = { _, side, _ in
            asked = side; return .proceedAnyway
        }
        model.resolveDiskConflict(.takeDisk)

        XCTAssertEqual(asked, .mine, "must confirm MY edits are unrecoverable")
        XCTAssertNil(model.peekHexDirtyBytesForTest(id), "stash dropped")
        XCTAssertNil(model.activeDiskConflict)
        XCTAssertEqual(model.tabs.selected?.isDirty, false, "dirty dot cleared")
    }

    func test_takeDisk_cancelKeepsTheEditsAndTheBanner() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model)
        try externalWrite(url, [0xEE])
        raiseConflict(model, id: id, url: url)
        model.unpreservedDiscardPromptOverride = { _, _, _ in .cancel }

        model.resolveDiskConflict(.takeDisk)

        XCTAssertNotNil(model.peekHexDirtyBytesForTest(id), "cancel keeps the edits")
        XCTAssertNotNil(model.activeDiskConflict, "the conflict is still unresolved")
    }

    /// Keep Mine's cost is the DISK side (the next save overwrites it, and
    /// binary can't be preserved) — it must confirm too, then stop the
    /// watcher re-raising by re-baselining.
    func test_keepMine_confirmsTheDiskSide_andRebaselines() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model)
        try externalWrite(url, [0xEE])
        raiseConflict(model, id: id, url: url)

        var asked: DocumentModel.ConflictSide?
        model.unpreservedDiscardPromptOverride = { _, side, _ in
            asked = side; return .proceedAnyway
        }
        model.resolveDiskConflict(.keepMine)

        XCTAssertEqual(asked, .disk, "must name the disk version as the casualty")
        XCTAssertNil(model.activeDiskConflict)
        XCTAssertNotNil(model.peekHexDirtyBytesForTest(id), "my edits survive")
        XCTAssertEqual(model.hexDiskBaseline[id], HexDiskStamp.current(for: url),
                       "re-baselined — the save guard honours the decision")
        // And the honoured decision: the save now writes without re-prompting.
        var prompted = false
        model.hexOverwritePromptOverride = { _ in prompted = true; return .cancel }
        XCTAssertTrue(model.saveHexEdits(forTabID: id))
        XCTAssertFalse(prompted)
    }

    func test_merge_isRefusedForBinary_bannerStays() throws {
        let model = makeModel()
        let (id, url) = try hexDirtyTab(model)
        raiseConflict(model, id: id, url: url)

        model.resolveDiskConflict(.merge)

        XCTAssertNotNil(model.activeDiskConflict, "merge can't resolve a binary conflict")
        XCTAssertNotNil(model.peekHexDirtyBytesForTest(id))
    }
}
