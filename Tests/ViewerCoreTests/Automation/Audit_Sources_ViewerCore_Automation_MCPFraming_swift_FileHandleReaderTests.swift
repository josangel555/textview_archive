import XCTest
@testable import ViewerCore

/// Regression coverage for the cursor-based `MCPFraming.FileHandleReader`
/// rework (audit S4 perf: header scan was O(header_len × buffered_bytes)
/// because `readByte()` did `removeFirst()` + `Data(buffer)` per byte).
///
/// The existing `MCPFramingTests` only exercise the in-memory `DataReader`;
/// the production `FileHandleReader` path (the one the audit finding is
/// about) had no direct coverage. These tests drive a real `FileHandle`
/// via a `Pipe` so the cursor refill/drain/leftover-stash interplay and
/// the macOS-26 0-based-rebase invariant are exercised on the actual
/// production reader, not the test double.
///
/// Host-safe (`XCTestCase`, no GUI / no app bundle) — runs in the headless
/// merge gate.
final class Audit_Sources_ViewerCore_Automation_MCPFraming_swift_FileHandleReaderTests: XCTestCase {

    /// Writes `bytes` to a pipe, closes the write end (so reads see EOF
    /// once drained), and returns a `FileHandleReader` over the read end.
    ///
    /// The write happens on a background queue: a pipe's kernel buffer is
    /// ~64 KiB, so a >64 KiB payload (the large-body test) would block the
    /// writer until the reader drains. Writing concurrently avoids a
    /// same-thread write/read deadlock.
    private func reader(for bytes: Data) -> MCPFraming.FileHandleReader {
        let pipe = Pipe()
        DispatchQueue.global(qos: .userInitiated).async {
            pipe.fileHandleForWriting.write(bytes)
            try? pipe.fileHandleForWriting.close()
        }
        return MCPFraming.FileHandleReader(pipe.fileHandleForReading)
    }

    // MARK: - Whole frame in one write (the quadratic case)

    func test_wholeFrameInOneWrite_decodesCorrectly() throws {
        // The normal MCP write pattern: header + body land in a single
        // kernel read, so the header is scanned while the buffer still
        // holds the entire body. This is the path the cursor optimizes.
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)
        var r = reader(for: MCPFraming.encode(body: body))
        XCTAssertEqual(try MCPFraming.decode(from: &r), body)
        // Stream is exhausted → clean EOF → nil.
        XCTAssertNil(try MCPFraming.decode(from: &r))
    }

    func test_largeBody_wholeFrameInOneWrite() throws {
        // A megabyte-class body is exactly where the old per-byte
        // `Data(buffer)` rebase was quadratic. Correctness must hold.
        let body = Data(repeating: 0x41 /* 'A' */, count: 1_000_000)
        var r = reader(for: MCPFraming.encode(body: body))
        XCTAssertEqual(try MCPFraming.decode(from: &r), body)
    }

    // MARK: - Multiple frames in one buffer (cursor straddles frames)

    func test_multipleFramesInOneWrite() throws {
        let a = Data(#"{"a":1}"#.utf8)
        let b = Data(#"{"b":22}"#.utf8)
        let c = Data(#"{"c":333}"#.utf8)
        var combined = Data()
        combined.append(MCPFraming.encode(body: a))
        combined.append(MCPFraming.encode(body: b))
        combined.append(MCPFraming.encode(body: c))
        var r = reader(for: combined)
        // Frame B's header is scanned starting from a mid-buffer cursor
        // (after frame A's body was read via read(exactly:)), and frame C
        // likewise — exercising the readByte/read(exactly:) interleave.
        XCTAssertEqual(try MCPFraming.decode(from: &r), a)
        XCTAssertEqual(try MCPFraming.decode(from: &r), b)
        XCTAssertEqual(try MCPFraming.decode(from: &r), c)
        XCTAssertNil(try MCPFraming.decode(from: &r))
    }

    // MARK: - Body with embedded newlines

    func test_bodyWithEmbeddedCRLF() throws {
        // A body containing CRLF-CRLF must NOT be mistaken for the header
        // terminator: read(exactly:) consumes it by length, never scans.
        let body = Data("line1\r\n\r\nline2\r\n\r\nline3".utf8)
        var r = reader(for: MCPFraming.encode(body: body))
        XCTAssertEqual(try MCPFraming.decode(from: &r), body)
    }

    // MARK: - LF-only header tolerance through the real reader

    func test_lfOnlyHeader() throws {
        var raw = Data("Content-Length: 4\n\n".utf8)
        raw.append(Data("abcd".utf8))
        var r = reader(for: raw)
        XCTAssertEqual(try MCPFraming.decode(from: &r), Data("abcd".utf8))
    }

    // MARK: - EOF semantics

    func test_cleanEOF_returnsNil() throws {
        var r = reader(for: Data())
        XCTAssertNil(try MCPFraming.decode(from: &r))
    }

    func test_truncatedBody_throwsUnexpectedEOF() {
        var raw = Data("Content-Length: 10\r\n\r\n".utf8)
        raw.append(Data("abc".utf8))   // only 3 of 10 promised bytes
        var r = reader(for: raw)
        XCTAssertThrowsError(try MCPFraming.decode(from: &r)) { error in
            XCTAssertEqual(error as? MCPFraming.DecodeError, .unexpectedEOF)
        }
    }

    // MARK: - Direct reader-level interleave (readByte then read(exactly:))

    func test_readByteThenReadExactly_acrossSingleBuffer() throws {
        // Consume some bytes via readByte (advancing the cursor), then a
        // bulk read(exactly:) that must slice from the live cursor region,
        // then more readByte from the leftover. This directly stresses the
        // cursor bookkeeping the audit fix introduced.
        let payload = Data("ABCDEFGHIJ".utf8)
        var r = reader(for: payload)
        XCTAssertEqual(try r.readByte(), UInt8(ascii: "A"))
        XCTAssertEqual(try r.readByte(), UInt8(ascii: "B"))
        XCTAssertEqual(try r.read(exactly: 4), Data("CDEF".utf8))
        XCTAssertEqual(try r.readByte(), UInt8(ascii: "G"))
        XCTAssertEqual(try r.read(exactly: 3), Data("HIJ".utf8))
        // Exhausted.
        XCTAssertNil(try r.readByte())
        XCTAssertNil(try r.read(exactly: 1))
    }
}
