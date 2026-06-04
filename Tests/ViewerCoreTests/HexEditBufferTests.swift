import XCTest
@testable import ViewerCore

/// Host-safe (T1m) coverage for the editable-hex byte model (#234):
/// `HexEditBuffer` (overwrite edits, dirty tracking, undo/redo, save
/// baseline), `HexNibble` parsing, and `HexBinaryWriter` (binary
/// write-back — exercised against the per-user temp dir only, never
/// `~/Documents` etc.).
final class HexEditBufferTests: XCTestCase {

    // MARK: - HexNibble parsing

    func test_nibble_value_digits() {
        XCTAssertEqual(HexNibble.value(of: "0"), 0)
        XCTAssertEqual(HexNibble.value(of: "9"), 9)
        XCTAssertEqual(HexNibble.value(of: "a"), 10)
        XCTAssertEqual(HexNibble.value(of: "f"), 15)
        XCTAssertEqual(HexNibble.value(of: "A"), 10)
        XCTAssertEqual(HexNibble.value(of: "F"), 15)
    }

    func test_nibble_value_rejectsNonHex() {
        XCTAssertNil(HexNibble.value(of: "g"))
        XCTAssertNil(HexNibble.value(of: "G"))
        XCTAssertNil(HexNibble.value(of: " "))
        XCTAssertNil(HexNibble.value(of: "/"))   // just below '0'
        XCTAssertNil(HexNibble.value(of: ":"))   // just above '9'
    }

    func test_printableASCII_range() {
        XCTAssertTrue(HexNibble.isPrintableASCII(" "))    // 0x20
        XCTAssertTrue(HexNibble.isPrintableASCII("~"))    // 0x7E
        XCTAssertTrue(HexNibble.isPrintableASCII("A"))
        XCTAssertFalse(HexNibble.isPrintableASCII("\n"))  // 0x0A
        XCTAssertFalse(HexNibble.isPrintableASCII("\u{7F}")) // DEL
    }

    // MARK: - Construction / dirty baseline

    func test_init_cleanByDefault() {
        let buf = HexEditBuffer(original: [0x00, 0x11, 0x22])
        XCTAssertFalse(buf.isDirty)
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(buf.data, Data([0x00, 0x11, 0x22]))
        XCTAssertFalse(buf.canUndo)
        XCTAssertFalse(buf.canRedo)
    }

    func test_init_fromData() {
        let buf = HexEditBuffer(data: Data([0xAB, 0xCD]))
        XCTAssertEqual(buf.byte(at: 0), 0xAB)
        XCTAssertEqual(buf.byte(at: 1), 0xCD)
        XCTAssertNil(buf.byte(at: 2))
    }

    // MARK: - Nibble overwrite

    func test_setNibble_high_replacesTopFourBits() {
        var buf = HexEditBuffer(original: [0x00])
        XCTAssertTrue(buf.setNibble(byte: 0, nibble: 0, value: 0xA))
        XCTAssertEqual(buf.byte(at: 0), 0xA0)
        XCTAssertTrue(buf.isDirty)
    }

    func test_setNibble_low_replacesBottomFourBits() {
        var buf = HexEditBuffer(original: [0xA0])
        XCTAssertTrue(buf.setNibble(byte: 0, nibble: 1, value: 0xF))
        XCTAssertEqual(buf.byte(at: 0), 0xAF)
    }

    func test_setNibble_twoNibbles_buildFullByte() {
        // Typing "de" into a zero byte → 0xDE (the two-per-byte path).
        var buf = HexEditBuffer(original: [0x00])
        buf.setNibble(byte: 0, nibble: 0, value: 0xD)
        buf.setNibble(byte: 0, nibble: 1, value: 0xE)
        XCTAssertEqual(buf.byte(at: 0), 0xDE)
    }

    func test_setNibble_masksToFourBits() {
        var buf = HexEditBuffer(original: [0x00])
        buf.setNibble(byte: 0, nibble: 1, value: 0xFF)  // only low 4 bits used
        XCTAssertEqual(buf.byte(at: 0), 0x0F)
    }

    func test_setNibble_sameValue_isNoOp_noUndoEntry() {
        var buf = HexEditBuffer(original: [0xA5])
        XCTAssertFalse(buf.setNibble(byte: 0, nibble: 0, value: 0xA)) // already A
        XCTAssertFalse(buf.canUndo)
        XCTAssertFalse(buf.isDirty)
    }

    func test_setNibble_outOfRange_isNoOp() {
        var buf = HexEditBuffer(original: [0x00])
        XCTAssertFalse(buf.setNibble(byte: 5, nibble: 0, value: 0xF))
        XCTAssertFalse(buf.isDirty)
    }

    // MARK: - ASCII byte overwrite + hex/ascii sync

    func test_setByte_setsWholeByte() {
        var buf = HexEditBuffer(original: [0x00, 0x00])
        XCTAssertTrue(buf.setByte(byte: 1, value: 0x41))  // 'A'
        XCTAssertEqual(buf.byte(at: 1), 0x41)
        XCTAssertTrue(buf.isDirty)
    }

    func test_hexAndAscii_shareOneBuffer() {
        // A nibble edit and an ascii read see the SAME byte — the view's
        // "keep hex + ASCII in sync" requirement reduces to: both columns
        // read `edited`.
        var buf = HexEditBuffer(original: [0x00])
        buf.setNibble(byte: 0, nibble: 0, value: 0x4)
        buf.setNibble(byte: 0, nibble: 1, value: 0x1)
        XCTAssertEqual(buf.byte(at: 0), 0x41)  // == 'A' in the ascii column
    }

    // MARK: - Dirty diff

    func test_dirtyByteIndices_listsOnlyChanged() {
        var buf = HexEditBuffer(original: [0, 1, 2, 3])
        buf.setByte(byte: 1, value: 0xFF)
        buf.setByte(byte: 3, value: 0xEE)
        XCTAssertEqual(buf.dirtyByteIndices, [1, 3])
    }

    func test_editingBackToOriginal_clearsDirty() {
        var buf = HexEditBuffer(original: [0x10])
        buf.setByte(byte: 0, value: 0x20)
        XCTAssertTrue(buf.isDirty)
        buf.setByte(byte: 0, value: 0x10)  // back to original value
        XCTAssertFalse(buf.isDirty, "edited == original ⇒ not dirty")
        XCTAssertTrue(buf.dirtyByteIndices.isEmpty)
    }

    // MARK: - Undo / redo

    func test_undo_revertsLastEdit_returnsIndex() {
        var buf = HexEditBuffer(original: [0x00, 0x00])
        buf.setByte(byte: 1, value: 0x99)
        XCTAssertTrue(buf.canUndo)
        XCTAssertEqual(buf.undo(), 1)
        XCTAssertEqual(buf.byte(at: 1), 0x00)
        XCTAssertFalse(buf.isDirty)
        XCTAssertTrue(buf.canRedo)
    }

    func test_redo_reappliesUndoneEdit() {
        var buf = HexEditBuffer(original: [0x00])
        buf.setByte(byte: 0, value: 0x77)
        buf.undo()
        XCTAssertEqual(buf.redo(), 0)
        XCTAssertEqual(buf.byte(at: 0), 0x77)
        XCTAssertTrue(buf.isDirty)
        XCTAssertFalse(buf.canRedo)
    }

    func test_undo_multipleEdits_lifoOrder() {
        var buf = HexEditBuffer(original: [0, 0, 0])
        buf.setByte(byte: 0, value: 0xA)
        buf.setByte(byte: 1, value: 0xB)
        buf.setByte(byte: 2, value: 0xC)
        XCTAssertEqual(buf.undo(), 2)  // last-in first-out
        XCTAssertEqual(buf.undo(), 1)
        XCTAssertEqual(buf.byte(at: 0), 0xA)  // first edit still applied
        XCTAssertEqual(buf.byte(at: 1), 0x00) // reverted
        XCTAssertEqual(buf.byte(at: 2), 0x00) // reverted
    }

    func test_newEdit_clearsRedoStack() {
        var buf = HexEditBuffer(original: [0, 0])
        buf.setByte(byte: 0, value: 0x1)
        buf.undo()
        XCTAssertTrue(buf.canRedo)
        buf.setByte(byte: 1, value: 0x2)   // new edit branches history
        XCTAssertFalse(buf.canRedo, "a fresh edit must clear the redo stack")
    }

    func test_undo_emptyStack_returnsNil() {
        var buf = HexEditBuffer(original: [0])
        XCTAssertNil(buf.undo())
        XCTAssertNil(buf.redo())
    }

    func test_undo_nibbleEdits_areExactInverses() {
        var buf = HexEditBuffer(original: [0x00])
        buf.setNibble(byte: 0, nibble: 0, value: 0xD)  // 0x00 -> 0xD0
        buf.setNibble(byte: 0, nibble: 1, value: 0xE)  // 0xD0 -> 0xDE
        XCTAssertEqual(buf.byte(at: 0), 0xDE)
        buf.undo()  // -> 0xD0
        XCTAssertEqual(buf.byte(at: 0), 0xD0)
        buf.undo()  // -> 0x00
        XCTAssertEqual(buf.byte(at: 0), 0x00)
        XCTAssertFalse(buf.isDirty)
    }

    // MARK: - Save baseline / revert

    func test_markSaved_rebasesAndClearsHistory() {
        var buf = HexEditBuffer(original: [0x00])
        buf.setByte(byte: 0, value: 0x42)
        buf.markSaved()
        XCTAssertFalse(buf.isDirty, "edited becomes the new clean baseline")
        XCTAssertFalse(buf.canUndo)
        XCTAssertEqual(buf.original(at: 0), 0x42)
    }

    func test_revert_restoresOriginal() {
        var buf = HexEditBuffer(original: [0x10, 0x20])
        buf.setByte(byte: 0, value: 0xFF)
        buf.setByte(byte: 1, value: 0xEE)
        buf.revert()
        XCTAssertFalse(buf.isDirty)
        XCTAssertEqual(buf.data, Data([0x10, 0x20]))
        XCTAssertFalse(buf.canUndo)
    }

    // MARK: - HexBinaryWriter (temp-dir only)

    func test_write_roundTripsBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-hex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)

        // Load → edit → save → re-read.
        var buf = HexEditBuffer(data: try Data(contentsOf: url))
        buf.setNibble(byte: 0, nibble: 0, value: 0xD)
        buf.setNibble(byte: 0, nibble: 1, value: 0xE)  // byte 0 -> 0xDE
        buf.setByte(byte: 3, value: 0xFF)
        let stamp = try HexBinaryWriter.write(buf.data, to: url)

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, Data([0xDE, 0x01, 0x02, 0xFF]))
        XCTAssertEqual(stamp.size, 4)
        XCTAssertNotNil(stamp.mtime)
    }

    func test_write_preservesFileMode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-hex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("script")
        try Data([0x01]).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)

        try HexBinaryWriter.write(Data([0x02]), to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o755, "atomic write must replay the original mode bits")
    }

    func test_write_symlink_refusedByDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-hex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.bin")
        try Data([0xAA]).write(to: target)
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try HexBinaryWriter.write(Data([0xBB]), to: link)) { err in
            guard case HexWriteError.targetIsSymlink = err else {
                return XCTFail("expected .targetIsSymlink, got \(err)")
            }
        }
        // The link's target must be untouched by the refused write.
        XCTAssertEqual(try Data(contentsOf: target), Data([0xAA]))
    }

    func test_write_newFile_succeeds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-hex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("new.bin")  // does not exist yet
        try HexBinaryWriter.write(Data([0x12, 0x34]), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data([0x12, 0x34]))
    }
}
