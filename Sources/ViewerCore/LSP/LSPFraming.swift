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
        // Re-base the slice so all index arithmetic below works from 0.
        // `Data` slices keep their parent's `startIndex` non-zero after
        // a `removeFirst` / `dropFirst`, which makes `buffer.subdata(in:)`
        // calls trap when callers pass `0..<n`. The copy is cheap on
        // small slices; we re-base unconditionally to keep this code
        // robust to any slice the caller hands us.
        let buffer = Data(rawBuffer)
        // Find `\r\n\r\n` header terminator. Byte-search; no string
        // decode — header section is ASCII per spec.
        guard let headerEnd = findHeaderTerminator(in: buffer) else {
            return .needMore
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

    private static func findHeaderTerminator(in buf: Data) -> Int? {
        // Scan for the 4-byte sequence `\r\n\r\n`. Position is the
        // index of the first `\r`.
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard buf.count >= 4 else { return nil }
        // O(n*m) is fine: header is small (<200 bytes typical).
        return buf.withUnsafeBytes { raw -> Int? in
            let p = raw.bindMemory(to: UInt8.self)
            let limit = p.count - 4
            var i = 0
            while i <= limit {
                if p[i] == needle[0] && p[i+1] == needle[1]
                    && p[i+2] == needle[2] && p[i+3] == needle[3] {
                    return i
                }
                i += 1
            }
            return nil
        }
    }
}
