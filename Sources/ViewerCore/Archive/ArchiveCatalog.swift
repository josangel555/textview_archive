import Foundation

/// TSK-311 — browse archives without a manual unzip, via the SYSTEM
/// tools that ship on every macOS (`/usr/bin/unzip`, `/usr/bin/tar`) —
/// the owner-approved host-tools pattern (the ffmpeg precedent): zero
/// new dependencies, best-effort capability.
///
/// SECURITY (the zip-slip class): entry names from the archive NEVER
/// drive filesystem paths. Listing is parse-only; single-entry
/// extraction streams the entry over STDOUT (`unzip -p` / `tar -xOf`)
/// into an app-chosen temp filename, so a hostile `../../…` entry name
/// cannot place a file anywhere — pinned by tests.
public enum ArchiveCatalog {

    /// One archive member.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let name: String
        public let isDirectory: Bool
        /// Uncompressed size where the lister reports one; nil for tar
        /// kinds we list name-only.
        public let sizeBytes: Int?
        public var id: String { name }

        public init(name: String, isDirectory: Bool, sizeBytes: Int? = nil) {
            self.name = name
            self.isDirectory = isDirectory
            self.sizeBytes = sizeBytes
        }
    }

    /// Archive kinds v1 can serve with system tools. 7z/rar stay icon-only
    /// (no system tool to lean on — a future best-effort locator like
    /// FFmpegLocator if the owner wants them).
    public enum Kind: Equatable, Sendable {
        case zip
        case tar
        case tarGz
        case tarBz2
    }

    public enum ArchiveError: Error, Equatable {
        case unsupportedKind
        case toolFailed(status: Int32)
        case timeout
        case entryTooLarge(limit: Int)
        case emptyEntry
    }

    /// Caps: a listing never returns more than this many entries…
    public static let maxEntries = 20_000
    /// …and a single extracted entry never exceeds this many bytes
    /// (64 MiB — generous for "peek inside an archive", refusing the
    /// decompression-bomb class).
    public static let maxEntryBytes = 64 * 1024 * 1024
    /// Wall-clock cap on either subprocess.
    public static let toolTimeout: TimeInterval = 20

    /// Kind by filename (case-insensitive). nil = not an archive we serve.
    public static func kind(for url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") || name.hasSuffix(".jar") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { return .tarBz2 }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }

    /// List the archive's members. Bounded by `maxEntries` (the `truncated`
    /// flag reports the cut).
    public static func list(
        _ url: URL
    ) throws -> (entries: [Entry], truncated: Bool) {
        guard let kind = kind(for: url) else { throw ArchiveError.unsupportedKind }
        let out: Data
        switch kind {
        case .zip:
            // `unzip -l`: "  size  date time  name" rows between header/footer.
            out = try run("/usr/bin/unzip", ["-l", "--", url.path])
        case .tar, .tarGz, .tarBz2:
            out = try run("/usr/bin/tar", ["-t" + tarFlag(kind), "-f", url.path])
        }
        let text = String(decoding: out, as: UTF8.self)
        var entries: [Entry]
        switch kind {
        case .zip: entries = parseUnzipList(text)
        case .tar, .tarGz, .tarBz2:
            entries = text.split(separator: "\n").map { line in
                let name = String(line)
                return Entry(name: name, isDirectory: name.hasSuffix("/"))
            }
        }
        let truncated = entries.count > maxEntries
        if truncated { entries = Array(entries.prefix(maxEntries)) }
        return (entries, truncated)
    }

    /// Extract ONE member's raw bytes from a ZIP-CONTAINER file, regardless of
    /// its filename extension. OOXML formats (`.xlsx`/`.docx`/`.pptx`) are ZIP
    /// containers but don't carry a `.zip` suffix, so `kind(for:)` would reject
    /// them — this entry point bypasses the suffix gate for the zip case while
    /// reusing the SAME hardened `unzip -p` pipe: the member streams over stdout,
    /// its NAME never becomes a filesystem path (zip-slip safe), and the
    /// `maxEntryBytes` bomb cap still applies. The caller supplies a FIXED,
    /// app-known entry name (e.g. `"xl/workbook.xml"`), never user input.
    ///
    /// Returns the entry bytes, or throws `toolFailed` when the entry is absent
    /// (unzip exits non-zero), `entryTooLarge` past the cap, or `emptyEntry`.
    public static func zipEntryBytes(named name: String, fromZipAt url: URL) throws -> Data {
        let data = try run("/usr/bin/unzip", ["-p", "--", url.path, name])
        guard !data.isEmpty else { throw ArchiveError.emptyEntry }
        guard data.count <= maxEntryBytes else {
            throw ArchiveError.entryTooLarge(limit: maxEntryBytes)
        }
        return data
    }

    /// Extract ONE member to an app-chosen temp file and return its URL.
    /// The member streams over stdout — its NAME never becomes a path.
    /// The temp filename keeps only the sanitized last path component
    /// (display/extension affordance); collisions are avoided with a UUID
    /// directory.
    public static func extractEntry(
        named name: String, from url: URL
    ) throws -> URL {
        guard let kind = kind(for: url) else { throw ArchiveError.unsupportedKind }
        let data: Data
        switch kind {
        case .zip:
            data = try run("/usr/bin/unzip", ["-p", "--", url.path, name])
        case .tar, .tarGz, .tarBz2:
            data = try run("/usr/bin/tar", ["-x" + tarFlag(kind), "-O", "-f", url.path, "--", name])
        }
        guard !data.isEmpty else { throw ArchiveError.emptyEntry }
        guard data.count <= maxEntryBytes else {
            throw ArchiveError.entryTooLarge(limit: maxEntryBytes)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let leaf = sanitizedLeaf(of: name)
        let dest = dir.appendingPathComponent(leaf)
        try data.write(to: dest, options: [.atomic])
        return dest
    }

    /// The last path component of an entry name with path separators and
    /// leading dots stripped — used ONLY for the temp file's display name.
    /// (Safety doesn't depend on this: the write target directory is ours
    /// regardless. Defense in depth + a readable tab title.)
    static func sanitizedLeaf(of entryName: String) -> String {
        let leaf = entryName
            .split(separator: "/").last.map(String.init) ?? entryName
        let cleaned = leaf
            .replacingOccurrences(of: "\\", with: "_")
            .drop(while: { $0 == "." })
        return cleaned.isEmpty ? "entry" : String(cleaned)
    }

    // MARK: - Internals

    private static func tarFlag(_ kind: Kind) -> String {
        switch kind {
        case .tarGz: return "z"
        case .tarBz2: return "j"
        case .tar, .zip: return ""
        }
    }

    /// `unzip -l` rows: `   123  06-12-2026 19:00   dir/name.txt` between
    /// a header and the `---------` footer. Parse size + name; tolerate
    /// the locale-stable column shape unzip has had forever.
    static func parseUnzipList(_ text: String) -> [Entry] {
        var out: [Entry] = []
        for raw in text.split(separator: "\n") {
            let cols = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, let size = Int(cols[0]) else { continue }
            // Name = everything after the time column, joined (names with
            // spaces). Find the time token (HH:MM) and take the remainder
            // of the RAW line after it to preserve internal spacing.
            guard let timeRange = raw.range(of: #"\d{2}:\d{2}\s+"#, options: .regularExpression) else {
                continue
            }
            let name = String(raw[timeRange.upperBound...])
            guard !name.isEmpty else { continue }
            out.append(Entry(
                name: name,
                isDirectory: name.hasSuffix("/"),
                sizeBytes: size
            ))
        }
        return out
    }

    /// Run a tool with a wall-clock timeout, capturing stdout. Non-zero
    /// exit (or timeout-kill) throws.
    private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()   // discard; non-zero exit is the signal
        try p.run()
        // Read stdout CONCURRENTLY with the wait: a large entry fills the
        // pipe buffer and deadlocks a run-then-read sequence.
        var data = Data()
        let reader = Thread {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        reader.start()
        let deadline = Date().addingTimeInterval(toolTimeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning {
            p.terminate()
            throw ArchiveError.timeout
        }
        // Drain the reader (bounded: the process has exited, EOF arrives).
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        guard p.terminationStatus == 0 else {
            throw ArchiveError.toolFailed(status: p.terminationStatus)
        }
        return data
    }
}
