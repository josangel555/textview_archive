import Foundation

/// Pure, host-testable decoder for the **OSC 7** "report current working
/// directory" escape (TSK-341 terminal-session persistence).
///
/// Shells configured with the de-facto standard precmd hook emit, on every
/// prompt, `ESC ] 7 ; file://<host>/<percent-encoded-path> ST` so a terminal
/// emulator can track the live cwd as the user `cd`s around. We persist the
/// *spawn* cwd already (`TerminalTabSet.Tab.cwd`), but never updated it as the
/// user moved between directories, so a restored tab re-opened in the ORIGINAL
/// directory rather than where the user left off. This decoder is the piece the
/// `ANSIParser` feeds the OSC-7 payload into to recover the live directory.
///
/// Strictly a value transformer — no filesystem access, no I/O — so the whole
/// thing is unit-testable in `ViewerCoreTests` without spawning a shell. The
/// parser proper (`ANSIParser`) owns the OSC framing (accumulating the payload
/// between `ESC]` and the BEL/ST terminator); this enum owns ONLY the payload
/// → `URL` rule.
public enum TerminalOSC7 {

    /// Decode an OSC payload (the bytes BETWEEN `ESC]` and the terminator, with
    /// the `Ps;` selector still present) into a local-directory `URL`, or `nil`
    /// when it isn't a usable OSC-7 cwd report.
    ///
    /// Accepted shape: `7;file://<host>/<path>` where `<path>` is
    /// percent-encoded per RFC 3986 (spaces → `%20`, etc.). Rules:
    /// - the selector must be exactly `7` (other OSC codes — title `0`/`2`,
    ///   hyperlink `8`, etc. — return nil so the caller ignores them),
    /// - the URI scheme must be `file`,
    /// - a non-empty `<host>` that is neither `localhost` nor the local
    ///   hostname is treated as a REMOTE cwd and rejected (we can't `cd` the
    ///   local shell into a path on another machine),
    /// - the percent-decoded path must be absolute (`/…`),
    /// - a missing/garbled/non-file payload returns nil.
    public static func directory(fromOSCPayload payload: String,
                                 localHost: String? = nil) -> URL? {
        // Split off the `Ps` selector: everything up to the FIRST ';'.
        guard let sep = payload.firstIndex(of: ";") else { return nil }
        let selector = payload[payload.startIndex..<sep]
        guard selector == "7" else { return nil }
        let uri = String(payload[payload.index(after: sep)...])
        return directory(fromFileURI: uri, localHost: localHost)
    }

    /// Decode the `file://…` URI part (the payload with the `7;` selector
    /// already stripped) into a local-directory `URL`, applying the host check.
    /// Split out so it is independently testable and reusable.
    public static func directory(fromFileURI uri: String,
                                 localHost: String? = nil) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: trimmed), scheme == "file" else { return nil }

        // Strip `file://` (authority form) or `file:` (rare schemeless-authority
        // form some emitters use). After the authority marker the remainder is
        // `<host><path>`; the FIRST '/' begins the absolute path.
        let afterScheme: Substring
        if let r = trimmed.range(of: "file://") {
            afterScheme = trimmed[r.upperBound...]
        } else if let r = trimmed.range(of: "file:") {
            // `file:/abs/path` — no authority; the path starts at the slash.
            afterScheme = trimmed[r.upperBound...]
        } else {
            return nil
        }

        // Separate host (up to the first '/') from the path (from that '/').
        let host: Substring
        let rawPath: Substring
        if let slash = afterScheme.firstIndex(of: "/") {
            host = afterScheme[afterScheme.startIndex..<slash]
            rawPath = afterScheme[slash...]
        } else {
            // No path component at all — not a directory report.
            return nil
        }

        // Reject a genuinely-remote host. An empty host or `localhost` is
        // local; a host equal to the machine's own name is local too.
        if !host.isEmpty {
            let h = host.lowercased()
            var isLocal = h == "localhost" || h == "127.0.0.1"
            if let localHost {
                let full = localHost.lowercased()
                // Accept the full hostname ("machine.local") OR its bare short
                // form ("machine") — emitters report either.
                let short = full.split(separator: ".").first.map(String.init) ?? full
                isLocal = isLocal || h == full || h == short
            }
            guard isLocal else { return nil }
        }

        // Percent-decode the path (spaces, unicode, etc.).
        guard let decoded = String(rawPath).removingPercentEncoding,
              decoded.hasPrefix("/") else { return nil }

        return URL(fileURLWithPath: decoded, isDirectory: true).standardizedFileURL
    }

    /// The URI scheme (lowercased) up to the first ':', or nil if absent.
    private static func scheme(of uri: String) -> String? {
        guard let colon = uri.firstIndex(of: ":") else { return nil }
        let s = uri[uri.startIndex..<colon]
        guard !s.isEmpty else { return nil }
        return s.lowercased()
    }
}
