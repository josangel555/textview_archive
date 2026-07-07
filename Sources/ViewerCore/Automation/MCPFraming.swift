import Foundation

/// Content-Length framed JSON-RPC codec for the MCP stdio transport.
///
/// We use the LSP-style framing (`Content-Length: N\r\n\r\n<body>`)
/// rather than newline-delimited JSON for two reasons:
///
///   1. The design doc (docs/AUTOMATION.md §7) and the task brief
///      specify Content-Length. We honour that.
///   2. JSON bodies in MCP can contain newlines (pretty-printed args,
///      embedded code blocks in tool results). NDJSON would force us
///      to either escape newlines or compact-serialise — both fragile
///      against future schema changes. Length-prefixing sidesteps it.
///
/// We accept either CRLF or LF line endings on the header block to be
/// tolerant of clients written quickly by hand. We always write CRLF
/// on the wire because that's what LSP-compliant clients parse.
///
/// Framing is intentionally minimal: no `Content-Type`, no transfer
/// encoding negotiation. JSON is the only body type we ever send.
public enum MCPFraming {

    public enum DecodeError: Error, Equatable {
        case missingContentLength
        case malformedHeader(String)
        case bodyTooLarge(Int)
        case unexpectedEOF
        case io(String)
    }

    /// 16 MiB ceiling. A single MCP message larger than this is almost
    /// certainly a runaway snapshot (PNG bytes, view-tree dump) or an
    /// attacker feeding us garbage. Reject early so we never allocate
    /// the read buffer.
    public static let maxBodyBytes: Int = 16 * 1024 * 1024

    /// Wire mode of one message. TSK-1545: the MCP stdio spec delimits
    /// messages by NEWLINES; real clients (Claude Code) write `{...}\n` and
    /// hung against our Content-Length-only decode. We now sniff per
    /// message — first byte `{` ⇒ `.ndjson`, else the LSP-style
    /// `Content-Length` path (kept for back-compat with existing tooling)
    /// — and the server replies IN KIND.
    public enum Mode: Sendable, Equatable {
        case contentLength
        case ndjson
    }

    // MARK: - Encode

    /// Serialise `body` as `Content-Length: N\r\n\r\n<body>` ready for
    /// stdout. Caller is responsible for the actual write.
    public static func encode(body: Data) -> Data {
        encode(body: body, mode: .contentLength)
    }

    /// Serialise `body` in the given wire mode. `.ndjson` requires the
    /// body to be single-line JSON (our `JSONEncoder` output is compact —
    /// never pretty-printed — so this holds by construction).
    public static func encode(body: Data, mode: Mode) -> Data {
        switch mode {
        case .contentLength:
            var out = Data()
            let header = "Content-Length: \(body.count)\r\n\r\n"
            out.append(header.data(using: .utf8)!)
            out.append(body)
            return out
        case .ndjson:
            var out = Data(body)
            out.append(0x0A)
            return out
        }
    }

    // MARK: - Decode

    /// Reader abstraction so unit tests can drive framed decode from a
    /// `Data` buffer without spawning a process. `FileHandleReader`
    /// adapts a real `FileHandle` to this for production use.
    public protocol ByteReader {
        /// Read **exactly** `count` bytes. Returns nil at EOF. Throws
        /// on I/O errors. Implementations may block.
        mutating func read(exactly count: Int) throws -> Data?
        /// Read one byte, or nil at EOF. Used while scanning the
        /// variable-length header block.
        mutating func readByte() throws -> UInt8?
    }

    /// Reads one framed JSON-RPC message. Returns nil cleanly at EOF
    /// (the only signal we use to terminate the server loop).
    public static func decode<R: ByteReader>(from reader: inout R) throws -> Data? {
        try decodeDetecting(from: &reader)?.body
    }

    /// Reads one message AND reports which wire mode it arrived in, so the
    /// server can reply in kind (TSK-1545). Skips blank lines between
    /// NDJSON messages; per-message sniff on the first significant byte.
    public static func decodeDetecting<R: ByteReader>(
        from reader: inout R
    ) throws -> (body: Data, mode: Mode)? {
        // Sniff: consume inter-message whitespace (NDJSON clients separate
        // messages with newlines; tolerate stray blank lines), then branch
        // on the first significant byte.
        var first: UInt8
        repeat {
            guard let b = try reader.readByte() else { return nil }  // clean EOF
            first = b
        } while first == 0x0A || first == 0x0D || first == 0x20 || first == 0x09

        if first == UInt8(ascii: "{") {
            // NDJSON: the message is this line, terminated by LF. The body
            // is compact JSON by spec; cap at maxBodyBytes like the framed
            // path so a runaway line can't balloon the buffer.
            var line = Data([first])
            while true {
                guard let b = try reader.readByte() else {
                    // EOF mid-line: treat what we have as the final message
                    // (a client that exits right after its last unterminated
                    // line is within spec tolerance).
                    return (line, .ndjson)
                }
                if b == 0x0A { break }
                line.append(b)
                if line.count > maxBodyBytes { throw DecodeError.bodyTooLarge(line.count) }
            }
            // Tolerate CRLF line endings.
            if line.last == 0x0D { line.removeLast() }
            return (line, .ndjson)
        }

        // Content-Length path (LSP-style). Scan the header block
        // byte-by-byte until we see CRLF-CRLF (or LF-LF for hand-written
        // clients). Headers are tiny — a single Content-Length line is the
        // only one we need — so the byte-loop overhead is irrelevant.
        var headerBytes = Data([first])
        let headerCap = 8 * 1024     // headers shouldn't exceed 8 KiB
        while headerBytes.count < headerCap {
            guard let b = try reader.readByte() else {
                // Mid-header EOF = peer crashed; surface as error so the
                // server loop can log it before exiting.
                throw DecodeError.unexpectedEOF
            }
            headerBytes.append(b)
            if endsWithBlankLine(headerBytes) { break }
        }
        guard endsWithBlankLine(headerBytes) else {
            throw DecodeError.malformedHeader("header block exceeded \(headerCap) bytes")
        }

        guard let headerString = String(data: headerBytes, encoding: .utf8) else {
            throw DecodeError.malformedHeader("non-UTF8 header bytes")
        }

        let length = try parseContentLength(headerString)
        guard length >= 0 else {
            throw DecodeError.malformedHeader("negative Content-Length")
        }
        guard length <= maxBodyBytes else {
            throw DecodeError.bodyTooLarge(length)
        }
        guard length > 0 else {
            return (Data(), .contentLength)
        }
        guard let body = try reader.read(exactly: length) else {
            throw DecodeError.unexpectedEOF
        }
        guard body.count == length else {
            throw DecodeError.unexpectedEOF
        }
        return (body, .contentLength)
    }

    // MARK: - Internals

    /// True if `buf` ends with CRLF-CRLF or LF-LF.
    private static func endsWithBlankLine(_ buf: Data) -> Bool {
        let n = buf.count
        if n >= 4 {
            // CRLF CRLF = 0x0D 0x0A 0x0D 0x0A
            if buf[n - 4] == 0x0D, buf[n - 3] == 0x0A,
               buf[n - 2] == 0x0D, buf[n - 1] == 0x0A {
                return true
            }
        }
        if n >= 2 {
            if buf[n - 2] == 0x0A, buf[n - 1] == 0x0A {
                return true
            }
        }
        return false
    }

    private static func parseContentLength(_ headers: String) throws -> Int {
        // Tolerant header parser: case-insensitive name, trim surrounding
        // whitespace on the value. We only care about Content-Length;
        // other headers (Content-Type, etc.) are ignored.
        //
        // IMPORTANT: split on Unicode scalars, not Characters. Swift
        // treats CRLF as a single extended-grapheme-cluster Character,
        // so a `Character`-level split-by-`\r`-or-`\n` against
        // `"Content-Length: 24\r\n\r\n"` matches zero positions and
        // returns the entire header block as one "line". UnicodeScalar
        // is the unambiguous code-point level we want.
        let scalarLines = headers.unicodeScalars
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for scalars in scalarLines {
            let s = String(String.UnicodeScalarView(scalars))
            guard let colon = s.firstIndex(of: ":") else { continue }
            let name = s[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let value = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let n = Int(value) else {
                throw DecodeError.malformedHeader("Content-Length not an integer: \(value)")
            }
            return n
        }
        throw DecodeError.missingContentLength
    }
}

// MARK: - In-memory reader (for tests)

extension MCPFraming {
    /// `ByteReader` backed by a `Data` buffer. Used by unit tests; not
    /// exposed for production callers (use `FileHandleReader`).
    public struct DataReader: ByteReader {
        private let data: Data
        private var offset: Int = 0
        /// Re-base via `Data(_:)` so `subdata(in:)` / subscript indexing
        /// below is always 0-based. Without this, a caller that hands us
        /// a `Data` slice with non-zero internal `startIndex` (e.g.
        /// `bigBuffer.suffix(from: k)`) hits the macOS 26
        /// `Data.subdata(in:)` slice-offset bug — `subdata(in: 0..<n)`
        /// returns garbage bytes because the underlying storage offset
        /// isn't surfaced consistently. See `LSPFraming.decode` for the
        /// same defensive pattern. Same goes for `data[offset]`: the
        /// subscript is in the slice's index space, so a slice with
        /// startIndex > 0 reads from the wrong position.
        public init(_ data: Data) { self.data = Data(data) }

        public mutating func read(exactly count: Int) throws -> Data? {
            guard offset + count <= data.count else { return nil }
            let slice = data.subdata(in: offset..<(offset + count))
            offset += count
            return slice
        }
        public mutating func readByte() throws -> UInt8? {
            guard offset < data.count else { return nil }
            let b = data[offset]
            offset += 1
            return b
        }
    }
}

// MARK: - FileHandle reader (for production)

extension MCPFraming {
    /// `ByteReader` over a `FileHandle` (typically `FileHandle.standardInput`).
    /// Uses blocking reads — the MCP server runs its own thread and
    /// expects to be parked in `read(2)` between messages.
    public struct FileHandleReader: ByteReader {
        private let handle: FileHandle
        /// Small look-ahead buffer so per-byte header scanning doesn't
        /// pay a syscall per byte. Body reads bypass this and call
        /// `read(exactly:)` directly which still works correctly because
        /// we drain the buffer first.
        ///
        /// INVARIANT: every assignment to `buffer` goes through
        /// `Data(_:)` so its internal `startIndex` is 0. `removeFirst`
        /// and `suffix(from:)` both produce slices with non-zero start
        /// offsets that, on macOS 26, mis-interpret subsequent
        /// `subdata(in:)` / subscript indexing (see LESSONS.md
        /// "Data.subdata(in:) after removeFirst slice-offset bug").
        /// LSPFraming.decode applies the same rebase defensively.
        private var buffer: Data = Data()
        /// Read cursor into `buffer`, measured from `buffer.startIndex`.
        /// Bytes in `buffer[startIndex ..< startIndex+cursor]` are
        /// already consumed; the live region is
        /// `buffer[startIndex+cursor ..< endIndex]`.
        ///
        /// Why a cursor instead of `removeFirst()`: `availableData`
        /// typically returns a whole frame (header + body, up to 16 MiB)
        /// in one read, and the header is then scanned byte-by-byte.
        /// `removeFirst()` + `Data(buffer)` each copy the *entire*
        /// remaining buffer per byte, so a ~40-byte header drained
        /// against a megabyte body was O(header_len × body_len). A
        /// cursor makes `readByte()` O(1); we only rebase via `Data(_:)`
        /// when the buffer is fully drained (cursor at end) — preserving
        /// the macOS-26 0-based-storage invariant above, since every
        /// refilled buffer is freshly `Data(_:)`-copied and the cursor
        /// resets to 0.
        private var cursor: Int = 0

        public init(_ handle: FileHandle) { self.handle = handle }

        public mutating func readByte() throws -> UInt8? {
            if cursor >= buffer.count {
                // Buffer drained — refill via RAW read(2), not
                // `availableData`: the FileHandle API raises an UNCATCHABLE
                // (from Swift) ObjC NSFileHandleOperationException when the
                // descriptor is closed under a blocked reader — exactly what
                // happens when the listener/app shuts a live connection
                // (TSK-1552 found it as a test crash; the app quit path had
                // the same landmine). read(2) returns -1/EBADF instead,
                // which we treat as EOF. EINTR retries.
                var tmp = [UInt8](repeating: 0, count: 64 * 1024)
                var n: Int
                repeat {
                    n = Darwin.read(handle.fileDescriptor, &tmp, tmp.count)
                } while n < 0 && errno == EINTR
                if n <= 0 { return nil }          // EOF, or a closed/dead fd
                buffer = Data(tmp[0..<n])
                cursor = 0
            }
            // O(1): index the live region without copying or shifting.
            let b = buffer[buffer.startIndex + cursor]
            cursor += 1
            return b
        }

        public mutating func read(exactly count: Int) throws -> Data? {
            var out = Data()
            out.reserveCapacity(count)
            // Drain any buffered (not-yet-consumed) bytes first.
            let buffered = buffer.count - cursor
            if buffered > 0 {
                let take = min(buffered, count)
                let base = buffer.startIndex + cursor
                out.append(buffer.subdata(in: base ..< (base + take)))
                cursor += take
            }
            // Once the buffered region is consumed, clear it so the
            // cursor stays small and `buffer` doesn't pin a large frame.
            if cursor >= buffer.count {
                buffer = Data()
                cursor = 0
            }
            while out.count < count {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF before all bytes arrived → caller treats as
                    // unexpectedEOF.
                    return nil
                }
                let needed = count - out.count
                if chunk.count <= needed {
                    out.append(chunk)
                } else {
                    out.append(chunk.prefix(needed))
                    // `suffix(from:)` returns a slice with non-zero
                    // startIndex; rebase to a canonical 0-based view and
                    // reset the cursor — the stashed leftover is unread.
                    buffer = Data(chunk.suffix(from: chunk.startIndex.advanced(by: needed)))
                    cursor = 0
                }
            }
            return out
        }
    }
}
