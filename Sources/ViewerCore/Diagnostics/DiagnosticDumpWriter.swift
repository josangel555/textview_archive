import Darwin
import Foundation

/// Owner-only (0600) export of a `DiagnosticSnapshot` to a JSON file.
///
/// Mirrors the proven 0600-write discipline already used for the SIGUSR1
/// view-tree dump (`AppDelegate.writeDataPrivate`, Sources/MarkdownViewer/
/// Diagnostics.swift): open with an explicit `0o600` mode and `O_TRUNC` so the
/// file is never momentarily group/other-readable, then `fchmod` again in case
/// the file pre-existed with looser perms.
///
/// ## Never auto-persist (PRIORITIZED_PLAN §5 guardrail #7)
/// This writer is invoked ONLY by an explicit owner action (a "Copy / Export"
/// button in the debug window). It is never wired to a timer, app lifecycle
/// hook, or — critically — the MCP host. The default `redactPaths: true`
/// keeps an exported artifact from embedding absolute paths.
public enum DiagnosticDumpWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case open(path: String, errno: Int32)
        case write(path: String, errno: Int32)
        case encode(underlying: Error)

        public var description: String {
            switch self {
            case .open(let p, let e):
                return "diagnostic dump open(\(p)) failed: \(String(cString: strerror(e)))"
            case .write(let p, let e):
                return "diagnostic dump write(\(p)) failed: \(String(cString: strerror(e)))"
            case .encode(let underlying):
                return "diagnostic dump JSON encode failed: \(underlying)"
            }
        }
    }

    /// Serialise `snapshot` (redacting absolute paths by default) to
    /// pretty-printed, sorted-key JSON and write it 0600 to `path`.
    ///
    /// - Parameters:
    ///   - snapshot: the curated snapshot.
    ///   - path: destination file (per-user tmpdir recommended).
    ///   - redactPaths: redact absolute paths before serialising. Defaults to
    ///     true — an exported artifact should not carry `/Users/<name>/...`.
    public static func write(
        _ snapshot: DiagnosticSnapshot,
        toPath path: String,
        redactPaths: Bool = true
    ) throws {
        let toEmit = redactPaths ? snapshot.redactingPaths() : snapshot
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: toEmit.jsonObject(),
                options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw WriteError.encode(underlying: error)
        }
        try writePrivate(data, toPath: path)
    }

    /// Write `data` to `path` with owner-only (0600) perms, truncating any
    /// existing file. Re-asserts the mode after open in case the file
    /// pre-existed with looser perms (open() honors the mode arg only on
    /// creation).
    static func writePrivate(_ data: Data, toPath path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw WriteError.open(path: path, errno: errno) }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress, remaining.count)
            }
            if written <= 0 { throw WriteError.write(path: path, errno: errno) }
            remaining = remaining.suffix(remaining.count - written)
        }
    }
}
