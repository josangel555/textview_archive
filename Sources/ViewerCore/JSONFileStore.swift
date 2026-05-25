import Foundation

/// Tiny shared helper for the read/write-JSON-to-disk pattern used by
/// `HistoryStore`, `BookmarksStore`, `SessionStore`. Same encoder
/// config (ISO-8601 dates, pretty-printed + sorted-keys), same
/// max-size check before decoding (so a tampered file can't inflate
/// into memory), same atomic write + parent-dir creation.
///
/// Callers use the static `read` / `write` entrypoints; nothing here
/// holds state.
public enum JSONFileStore {

    /// Read a single Codable value from `url`. Returns nil on:
    /// - file missing
    /// - file larger than `maxSize` (treated like a corrupt file —
    ///   refuse to inflate it)
    /// - decode failure (corrupt JSON / schema drift)
    ///
    /// Never throws — callers historically swallow errors here and
    /// start fresh. Preserving that surface keeps the refactor a
    /// pure extract.
    public static func read<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maxSize: Int = .max
    ) -> T? {
        if maxSize != .max,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxSize {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              maxSize == .max || data.count <= maxSize else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    /// Write `value` to `url`, creating parent dirs as needed. Atomic
    /// write; on disk failure the existing file is preserved.
    ///
    /// Returns true on success. Callers historically ignored the
    /// return value (best-effort persistence), but the bool is
    /// surfaced for tests + future loud-on-error paths.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(value) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Shared encoder / decoder

    /// ISO-8601 dates + pretty + sorted keys. Matches the surface the
    /// three call sites all converged on; pretty-print so the JSON
    /// files are human-debuggable in TextView itself.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
