import XCTest
@testable import RustCore

/// TSK-564: the big-payload decoders (decodeTable / decodeSnapshot) read the
/// response frame's body IN PLACE from offset 4 (MsgPackReader startingAt) via
/// `frameBodyStart`, instead of copying `frame[4...]` into a fresh [UInt8]. Pins
/// that the offset decode produces the right value AND that the length prefix is
/// still validated (a wrong offset / corrupt prefix must not silently mis-read).
final class FrameDecodeOffsetTests: XCTestCase {

    private func tableFrame() -> [UInt8] {
        MsgPackValue.map([
            (.string("delimiter"), .string(",")),
            (.string("header"), .array([.string("a"), .string("b")])),
            (.string("rows"), .array([
                .array([.string("1"), .string("2")]),
                .array([.string("3"), .string("4")]),
            ])),
            (.string("truncated"), .bool(false)),
        ]).frame()
    }

    func test_decodeTable_viaOffsetReader_roundTrips() throws {
        let table = try CsvSession.decodeTable(tableFrame())
        XCTAssertEqual(table.delimiter, ",")
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows, [["1", "2"], ["3", "4"]])
        XCTAssertFalse(table.truncated)
    }

    func test_frameBodyStart_validatesPrefix_returnsFour() throws {
        let frame = tableFrame()
        XCTAssertEqual(try CsvSession.frameBodyStart(frame), 4,
                       "the body starts past the 4-byte LE length prefix")
    }

    func test_frameBodyStart_rejectsCorruptLengthPrefix() {
        var bad = tableFrame()
        bad[0] = bad[0] &+ 1   // declared length no longer matches the body
        XCTAssertThrowsError(try CsvSession.frameBodyStart(bad),
                             "a length-prefix that disagrees with the body must throw, not mis-offset")
    }

    func test_frameBodyStart_rejectsShortFrame() {
        XCTAssertThrowsError(try CsvSession.frameBodyStart([0x00, 0x00, 0x00]),
                             "a frame shorter than the length prefix must throw")
    }
}
