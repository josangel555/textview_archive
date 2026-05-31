import Foundation

/// LSP wire framing: `Content-Length: N\r\n[Content-Type: ...\r\n]\r\n` +
/// exactly N bytes of UTF-8 JSON.
///
/// Pure-byte parser by construction — naive line-oriented decoders
/// corrupt on payloads with embedded `\r\n` inside string values
/// (extremely common in `hover.contents` markdown). Unit tests in
/// `LSPFramingTests` exercise the boundary cases without spawning a
/// server.
public enum LSPFraming {

    // MARK: - Caps (PARSE-01 / MAGIC-001)

    /// Hard ceiling on a single framed message body. A hostile or buggy
    /// server can send `Content-Length: 9999999999` and, without a cap,
    /// the reader keeps buffering until the body "arrives" — an
    /// unbounded heap allocation (OOM the viewer). 32 MiB comfortably
    /// covers the largest realistic LSP payloads (a huge
    /// `documentSymbol` / `workspace/symbol` result on a monorepo) while
    /// bounding the blast radius. Oversize is rejected as a framing
    /// error *before* we wait for / allocate the body.
    public static let maxBodyBytes = 32 * 1024 * 1024

    /// Hard ceiling on the header section (everything up to and
    /// including `\r\n\r\n`). Legitimate LSP headers are <200 bytes
    /// (`Content-Length` + optional `Content-Type`). A stream that
    /// never emits the terminator would otherwise make us buffer +
    /// re-scan without bound. 16 KiB is generous slack; exceeding it
    /// means the peer isn't speaking LSP framing.
    public static let maxHeaderBytes = 16 * 1024

    /// Frame an outgoing JSON body into the on-wire `Content-Length`
    /// envelope. `body` must already be UTF-8 encoded JSON.
    public static func frame(_ body: Data) -> Data {
        // `\r\n` is required by the spec — `\n` alone breaks rust-analyzer
        // and at least some VS Code internal servers.
        var out = Data()
        let header = "Content-Length: \(body.count)\r\n\r\n"
        out.append(header.data(using: .ascii)!)
        out.append(body)
        return out
    }

    /// Result of one framing-decode pass against a buffer.
    public enum DecodeStep: Equatable {
        /// A complete message was parsed; `consumed` bytes should be
        /// dropped from the front of the buffer.
        case message(body: Data, consumed: Int)
        /// Not enough data yet; caller should append more and retry.
        case needMore
    }

    /// Try to parse one message out of `buffer`. Caller is expected to
    /// loop and drain repeatedly until `.needMore` is returned, because
    /// a single read may deliver multiple framed messages back-to-back.
    public static func decode(_ rawBuffer: Data) throws -> DecodeStep {
        var ignored = 0
        return try decode(rawBuffer, headerScanStart: &ignored)
    }

    /// Streaming-aware variant. `headerScanStart` is a resume hint: the
    /// scan for the `\r\n\r\n` terminator begins there instead of at 0,
    /// so a header dribbling in over many reads costs O(total header)
    /// across all calls rather than O(n²) (PARSE-01). The caller keeps
    /// the cursor between `.needMore` results and resets it to 0 after
    /// consuming a message (the buffer's front shifts). Passing 0 is
    /// always correct, just potentially slower.
    public static func decode(
        _ rawBuffer: Data, headerScanStart: inout Int
    ) throws -> DecodeStep {
        // Re-base the slice so all index arithmetic below works from 0.
        // `Data` slices keep their parent's `startIndex` non-zero after
        // a `removeFirst` / `dropFirst`, which makes `buffer.subdata(in:)`
        // calls trap when callers pass `0..<n`. The copy is cheap on
        // small slices; we re-base unconditionally to keep this code
        // robust to any slice the caller hands us.
        let buffer = Data(rawBuffer)
        // Find `\r\n\r\n` header terminator. Byte-search; no string
        // decode — header section is ASCII per spec. Resume from the
        // last scanned offset (backed up 3 bytes so a terminator that
        // straddled the previous chunk boundary isn't missed).
        let scanFrom = max(0, min(headerScanStart, buffer.count))
        guard let headerEnd = findHeaderTerminator(in: buffer, from: scanFrom) else {
            // No terminator yet. Advance the resume cursor to just
            // before the buffer end (keeping a 3-byte overlap so a
            // split `\r\n\r\n` is caught next time) and bound the
            // header section: a peer that never terminates the header
            // must not make us buffer without limit.
            if buffer.count > maxHeaderBytes {
                throw LSPError.framingError(
                    "header exceeds \(maxHeaderBytes) bytes without terminator")
            }
            headerScanStart = max(0, buffer.count - 3)
            return .needMore
        }
        // Found — the next decode pass on the remaining buffer starts
        // fresh from 0 (the caller drops `consumed` bytes after a
        // message, or re-scans the same header on `.needMore` below).
        headerScanStart = 0
        // Defensive: a header longer than the cap (but terminated) is
        // still pathological. Reject before parsing.
        if headerEnd > maxHeaderBytes {
            throw LSPError.framingError(
                "header section \(headerEnd) bytes exceeds cap \(maxHeaderBytes)")
        }
        let headerData = buffer.prefix(headerEnd)
        guard let headerStr = String(data: headerData, encoding: .ascii) else {
            throw LSPError.framingError("non-ASCII header bytes")
        }
        var contentLength: Int?
        // CRLF is a single grapheme cluster, but using
        // `components(separatedBy:)` is unambiguous either way.
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.isEmpty { continue }
            // Case-insensitive `Content-Length:` per RFC 7230-ish parsing
            // (spec says headers follow HTTP conventions).
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard let n = Int(value), n >= 0 else {
                    throw LSPError.framingError("invalid Content-Length: \(value)")
                }
                // PARSE-01: reject oversize BEFORE returning `.needMore`
                // and waiting for the body. Without this we'd buffer up
                // to `n` bytes of attacker-controlled length → OOM.
                guard n <= maxBodyBytes else {
                    throw LSPError.framingError(
                        "Content-Length \(n) exceeds cap \(maxBodyBytes)")
                }
                contentLength = n
            }
            // Content-Type: ignored. Spec says we may assume UTF-8.
        }
        guard let n = contentLength else {
            throw LSPError.framingError("missing Content-Length header")
        }
        let bodyStart = headerEnd + 4 // length of "\r\n\r\n"
        let totalNeeded = bodyStart + n
        if buffer.count < totalNeeded {
            return .needMore
        }
        let body = buffer.subdata(in: bodyStart..<totalNeeded)
        return .message(body: body, consumed: totalNeeded)
    }

    private static func findHeaderTerminator(in buf: Data, from start: Int = 0) -> Int? {
        // Scan for the 4-byte sequence `\r\n\r\n`. Position is the
        // index of the first `\r`. `start` lets the caller resume a
        // scan it has already done up to (PARSE-01: turns the repeated
        // re-scan of a slowly-arriving header from O(n^2) into O(n)).
        guard buf.count >= 4 else { return nil }
        let begin = max(0, min(start, buf.count - 4))
        return buf.withUnsafeBytes { raw -> Int? in
            let p = raw.bindMemory(to: UInt8.self)
            let limit = p.count - 4
            var i = begin
            while i <= limit {
                if p[i] == 0x0D && p[i+1] == 0x0A
                    && p[i+2] == 0x0D && p[i+3] == 0x0A {
                    return i
                }
                i += 1
            }
            return nil
        }
    }
}
