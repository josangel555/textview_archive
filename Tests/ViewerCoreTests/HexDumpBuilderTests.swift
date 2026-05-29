import XCTest
@testable import ViewerCore

/// Host-safe tests for `HexDumpBuilder`. The view side streams these
/// chunks into an NSTextView — but the chunking math, header
/// emission, and per-row rendering are all pure-string work that we
/// can pin without spinning up AppKit.
final class HexDumpBuilderTests: XCTestCase {

    // MARK: Helpers

    private func makeFile(byteCount: Int,
                          totalByteCount: Int? = nil,
                          isTruncated: Bool = false,
                          fillByte: UInt8 = 0x41) -> BinaryFile {
        BinaryFile(
            url: URL(fileURLWithPath: "/tmp/hex-test"),
            data: Data(repeating: fillByte, count: byteCount),
            totalByteCount: totalByteCount ?? byteCount,
            isTruncated: isTruncated
        )
    }

    private func makeFile(data: Data,
                          totalByteCount: Int? = nil,
                          isTruncated: Bool = false) -> BinaryFile {
        BinaryFile(
            url: URL(fileURLWithPath: "/tmp/hex-test"),
            data: data,
            totalByteCount: totalByteCount ?? data.count,
            isTruncated: isTruncated
        )
    }

    // MARK: - Plan math

    func test_plan_emptyFile_zeroChunksAndRows() {
        let p = HexDumpBuilder.plan(byteCount: 0,
                                    totalByteCount: 0,
                                    isTruncated: false,
                                    width: 16)
        XCTAssertEqual(p.rowCount, 0)
        XCTAssertEqual(p.chunkCount, 0)
        XCTAssertEqual(p.headerCharCount, 0)
        XCTAssertEqual(p.header, "")
    }

    func test_plan_singleRow_emitsOneChunk() {
        let p = HexDumpBuilder.plan(byteCount: 16,
                                    totalByteCount: 16,
                                    isTruncated: false,
                                    width: 16,
                                    rowsPerChunk: 4096)
        XCTAssertEqual(p.rowCount, 1)
        XCTAssertEqual(p.chunkCount, 1)
        XCTAssertEqual(p.chunkStartRow(0), 0)
        XCTAssertEqual(p.chunkRowCount(0), 1)
        XCTAssertEqual(p.chunkStartByte(0, width: 16), 0)
        XCTAssertNil(p.chunkStartRow(1))
        XCTAssertNil(p.chunkRowCount(1))
    }

    /// 4 MB at width=16, rowsPerChunk=4096 → 262144 rows = 64 chunks.
    /// This is the canonical "stale main-thread" case the new path
    /// avoids — pinning the chunk count guarantees the producer is
    /// in fact splitting the work.
    func test_plan_4MB_width16_64chunks() {
        let p = HexDumpBuilder.plan(byteCount: 4 * 1024 * 1024,
                                    totalByteCount: 4 * 1024 * 1024,
                                    isTruncated: false,
                                    width: 16,
                                    rowsPerChunk: 4096)
        XCTAssertEqual(p.rowCount, 262_144)
        XCTAssertEqual(p.chunkCount, 64)
        XCTAssertEqual(p.chunkStartRow(0), 0)
        XCTAssertEqual(p.chunkStartRow(63), 63 * 4096)
        XCTAssertEqual(p.chunkRowCount(63), 4096)
        XCTAssertEqual(p.chunkStartByte(63, width: 16), 63 * 4096 * 16)
    }

    /// At width=64 the same 4 MB file has 65536 rows and 16 chunks
    /// (rowsPerChunk default = 4096). Sanity-checks that the
    /// chunk-count derivation respects the row count, not the byte
    /// count.
    func test_plan_4MB_width64_16chunks() {
        let p = HexDumpBuilder.plan(byteCount: 4 * 1024 * 1024,
                                    totalByteCount: 4 * 1024 * 1024,
                                    isTruncated: false,
                                    width: 64,
                                    rowsPerChunk: 4096)
        XCTAssertEqual(p.rowCount, 65_536)
        XCTAssertEqual(p.chunkCount, 16)
        XCTAssertEqual(p.chunkRowCount(15), 4096)
    }

    /// Partial last chunk: 4097 rows at rowsPerChunk=4096 → 2 chunks,
    /// the second containing one row.
    func test_plan_partialLastChunk() {
        // 4097 rows at width=16 = 16 * 4097 = 65552 bytes.
        let p = HexDumpBuilder.plan(byteCount: 65_552,
                                    totalByteCount: 65_552,
                                    isTruncated: false,
                                    width: 16,
                                    rowsPerChunk: 4096)
        XCTAssertEqual(p.rowCount, 4097)
        XCTAssertEqual(p.chunkCount, 2)
        XCTAssertEqual(p.chunkRowCount(0), 4096)
        XCTAssertEqual(p.chunkRowCount(1), 1)
    }

    func test_plan_truncated_emitsHeader() {
        let p = HexDumpBuilder.plan(byteCount: 4 * 1024 * 1024,
                                    totalByteCount: 12 * 1024 * 1024,
                                    isTruncated: true,
                                    width: 16)
        XCTAssertGreaterThan(p.headerCharCount, 0)
        XCTAssertTrue(p.header.contains("Showing first"))
        XCTAssertTrue(p.header.contains("\(4 * 1024 * 1024)"))
        XCTAssertTrue(p.header.contains("\(12 * 1024 * 1024)"))
        XCTAssertEqual(p.headerCharCount, p.header.count)
    }

    func test_plan_rowsPerChunkClampedToOne() {
        // Zero / negative input must not divide-by-zero; clamp to 1.
        let p = HexDumpBuilder.plan(byteCount: 100,
                                    totalByteCount: 100,
                                    isTruncated: false,
                                    width: 16,
                                    rowsPerChunk: 0)
        XCTAssertEqual(p.rowsPerChunk, 1)
        XCTAssertEqual(p.chunkCount, p.rowCount)
    }

    // MARK: - Streaming order + bookkeeping

    func test_build_emptyFile_emitsNothing() {
        let file = makeFile(byteCount: 0)
        var calls: [(Int, String)] = []
        let p = HexDumpBuilder.build(file: file, width: 16) { idx, s in
            calls.append((idx, s))
            return true
        }
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(p.chunkCount, 0)
    }

    func test_build_emitsHeaderFirstWhenTruncated() {
        let file = makeFile(byteCount: 32,
                            totalByteCount: 1024,
                            isTruncated: true)
        var calls: [(Int, String)] = []
        _ = HexDumpBuilder.build(file: file, width: 16) { idx, s in
            calls.append((idx, s))
            return true
        }
        XCTAssertGreaterThanOrEqual(calls.count, 2,
                                    "should have header + body chunks")
        XCTAssertEqual(calls.first?.0, 0)
        XCTAssertTrue(calls.first?.1.hasPrefix("Showing first 32 of 1024") == true)
    }

    func test_build_omitsHeaderWhenNotTruncated() {
        let file = makeFile(byteCount: 32)
        var calls: [(Int, String)] = []
        _ = HexDumpBuilder.build(file: file, width: 16) { idx, s in
            calls.append((idx, s))
            return true
        }
        XCTAssertEqual(calls.count, 1, "small file → single body chunk")
        XCTAssertFalse(calls[0].1.contains("Showing first"))
    }

    func test_build_respectsRowsPerChunk() {
        // 100 rows at width=16, rowsPerChunk=10 → 10 chunks.
        let file = makeFile(byteCount: 100 * 16)
        var chunkCount = 0
        let p = HexDumpBuilder.build(file: file,
                                     width: 16,
                                     rowsPerChunk: 10) { _, _ in
            chunkCount += 1
            return true
        }
        XCTAssertEqual(p.chunkCount, 10)
        XCTAssertEqual(chunkCount, 10)
    }

    /// Callback returning `false` aborts further chunking — the path
    /// the UI uses to drop a stale build when (file, width) changes.
    func test_build_stopsWhenCallbackReturnsFalse() {
        let file = makeFile(byteCount: 100 * 16)
        var calls = 0
        _ = HexDumpBuilder.build(file: file,
                                 width: 16,
                                 rowsPerChunk: 10) { _, _ in
            calls += 1
            return calls < 3   // stop after 3 chunks
        }
        XCTAssertEqual(calls, 3)
    }

    /// The chunk indices the callback receives must be strictly
    /// increasing from 0 with no gaps — the controller appends in
    /// receive order and the layout math depends on the sequential
    /// fill.
    func test_build_indicesAreContiguousFromZero() {
        let file = makeFile(byteCount: 1024,
                            totalByteCount: 8 * 1024,
                            isTruncated: true)
        var seen: [Int] = []
        _ = HexDumpBuilder.build(file: file,
                                 width: 16,
                                 rowsPerChunk: 16) { idx, _ in
            seen.append(idx)
            return true
        }
        XCTAssertEqual(seen, Array(0..<seen.count))
    }

    // MARK: - Equivalence: chunked output = buildAll output

    /// The crucial invariant: streaming chunks (any rowsPerChunk)
    /// concatenated must equal the all-at-once string. If they
    /// diverge, the live view will mis-address bytes via the row /
    /// column math and click-to-highlight will paint the wrong cells.
    func test_chunkedOutput_equalsBuildAll_width16_smallFile() {
        let bytes: [UInt8] = (0..<256).map { UInt8($0 & 0xFF) }
        let file = makeFile(data: Data(bytes))
        let oneShot = HexDumpBuilder.buildAll(file: file, width: 16)
        for rpc in [1, 2, 7, 16, 100, 4096] {
            var streamed = ""
            _ = HexDumpBuilder.build(file: file,
                                     width: 16,
                                     rowsPerChunk: rpc) { _, s in
                streamed += s
                return true
            }
            XCTAssertEqual(streamed, oneShot,
                           "rowsPerChunk=\(rpc) must reconstruct full dump")
        }
    }

    func test_chunkedOutput_equalsBuildAll_width32() {
        let bytes: [UInt8] = (0..<300).map { UInt8($0 & 0xFF) }
        let file = makeFile(data: Data(bytes))
        let oneShot = HexDumpBuilder.buildAll(file: file, width: 32)
        var streamed = ""
        _ = HexDumpBuilder.build(file: file,
                                 width: 32,
                                 rowsPerChunk: 4) { _, s in
            streamed += s
            return true
        }
        XCTAssertEqual(streamed, oneShot)
    }

    func test_chunkedOutput_equalsBuildAll_width64_partialLastRow() {
        // 100 bytes at width=64 → 2 rows, the second short.
        let bytes: [UInt8] = (0..<100).map { UInt8($0 & 0xFF) }
        let file = makeFile(data: Data(bytes))
        let oneShot = HexDumpBuilder.buildAll(file: file, width: 64)
        var streamed = ""
        _ = HexDumpBuilder.build(file: file,
                                 width: 64,
                                 rowsPerChunk: 1) { _, s in
            streamed += s
            return true
        }
        XCTAssertEqual(streamed, oneShot)
    }

    func test_chunkedOutput_includesHeaderInStream() {
        let bytes: [UInt8] = (0..<32).map { _ in UInt8(0x41) }
        let file = makeFile(data: Data(bytes),
                            totalByteCount: 1024,
                            isTruncated: true)
        let oneShot = HexDumpBuilder.buildAll(file: file, width: 16)
        var streamed = ""
        _ = HexDumpBuilder.build(file: file,
                                 width: 16,
                                 rowsPerChunk: 1) { _, s in
            streamed += s
            return true
        }
        XCTAssertEqual(streamed, oneShot)
        XCTAssertTrue(streamed.hasPrefix("Showing first 32 of 1024"))
    }

    // MARK: - Row formatting

    /// Each non-final row must emit exactly `renderedRowLength(width:)`
    /// characters including its newline. The live view relies on this
    /// to address bytes by `(row * rowLength + col)`.
    func test_eachRow_isExactlyRenderedRowLength() {
        let file = makeFile(byteCount: 16 * 5)
        var streamed = ""
        _ = HexDumpBuilder.build(file: file, width: 16) { _, s in
            streamed += s; return true
        }
        let rows = streamed.split(separator: "\n", omittingEmptySubsequences: false)
        // Last entry is the empty trailing component after the final \n.
        let bodyRows = rows.dropLast()
        let perRow = HexLayout.renderedRowLength(width: 16)
        for r in bodyRows {
            // Per-row chars include the newline (+1) — our split
            // dropped the newline, so the substring length is
            // `perRow - 1`.
            XCTAssertEqual(r.count, perRow - 1,
                           "row '\(r)' should be \(perRow - 1) chars (sans \\n)")
        }
    }

    /// Final partial row (e.g. 5 bytes at width=16) must still be
    /// padded to full row length so the layout math holds.
    func test_partialFinalRow_isFullLength() {
        let bytes = Data((0..<5).map { UInt8($0) })
        let file = makeFile(data: bytes)
        var streamed = ""
        _ = HexDumpBuilder.build(file: file, width: 16) { _, s in
            streamed += s; return true
        }
        let rows = streamed.split(separator: "\n",
                                  omittingEmptySubsequences: false)
        let bodyRows = rows.dropLast()
        XCTAssertEqual(bodyRows.count, 1)
        let perRow = HexLayout.renderedRowLength(width: 16)
        XCTAssertEqual(bodyRows.first?.count, perRow - 1)
    }

    func test_renderedRow_offsetPrefix_isEightHexDigits() {
        let file = makeFile(byteCount: 32)
        let dump = HexDumpBuilder.buildAll(file: file, width: 16)
        // First row should start with eight hex digits followed by 2 spaces.
        XCTAssertTrue(dump.hasPrefix("00000000  "), "got: \(dump.prefix(12))")
        // Second row offset = 16 = 0x10.
        let secondNewline = dump.firstIndex(of: "\n")!
        let afterFirst = dump.index(after: secondNewline)
        let secondPrefix = dump[afterFirst..<dump.index(afterFirst, offsetBy: 10)]
        XCTAssertEqual(String(secondPrefix), "00000010  ")
    }

    func test_renderedRow_asciiColumn_replacesNonPrintableWithDot() {
        // First 16 bytes: 0x00..0x0F — none printable → all dots.
        let bytes = Data((0..<16).map { UInt8($0) })
        let file = makeFile(data: bytes)
        let dump = HexDumpBuilder.buildAll(file: file, width: 16)
        // ASCII section starts at `asciiCharOffset(inRowColumn: 0, width: 16)`
        let asciiStart = HexLayout.asciiCharOffset(inRowColumn: 0, width: 16)
        let i0 = dump.index(dump.startIndex, offsetBy: asciiStart)
        let i1 = dump.index(i0, offsetBy: 16)
        XCTAssertEqual(String(dump[i0..<i1]), String(repeating: ".", count: 16))
    }

    func test_renderedRow_asciiColumn_emitsPrintableBytes() {
        let bytes = Data("Hello, World!!!\n".utf8) // 16 bytes
        XCTAssertEqual(bytes.count, 16)
        let file = makeFile(data: bytes)
        let dump = HexDumpBuilder.buildAll(file: file, width: 16)
        let asciiStart = HexLayout.asciiCharOffset(inRowColumn: 0, width: 16)
        let i0 = dump.index(dump.startIndex, offsetBy: asciiStart)
        let i1 = dump.index(i0, offsetBy: 16)
        XCTAssertEqual(String(dump[i0..<i1]), "Hello, World!!!.")
    }

    // MARK: - Microbench (host-safe)

    /// Time-to-first-chunk on a 4 MB file at width=16. The chunked
    /// path's whole point is making this small even when the total
    /// build is hundreds of ms — so the user sees content before the
    /// dump fully materializes. Asserts an upper bound rather than a
    /// floor; a real regression would push this into hundreds of ms.
    func test_microbench_4MB_firstChunk_isFast() {
        let file = makeFile(byteCount: 4 * 1024 * 1024)
        var firstChunkElapsed: TimeInterval = 0
        let t0 = Date()
        _ = HexDumpBuilder.build(file: file, width: 16) { idx, _ in
            if idx == 0 {
                firstChunkElapsed = -t0.timeIntervalSinceNow
                return false  // abort — we only timed the first chunk
            }
            return true
        }
        // 4096 rows × ~73 chars = ~300 KB string. On any modern Mac
        // this is in the low single-digit ms range. Generous bound
        // so the test doesn't flake on a busy CI host but tight
        // enough to catch a real perf regression (e.g. someone
        // dropping the `String.reserveCapacity` call).
        XCTAssertLessThan(firstChunkElapsed, 0.5,
                          "First chunk took \(firstChunkElapsed * 1000) ms — "
                          + "expected < 500 ms")
    }
}
