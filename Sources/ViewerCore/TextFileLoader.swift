import Foundation

public enum FileLoadError: Error, Equatable {
    case fileNotFound
    case notReadable
    case decodingFailed
    /// File exceeds the loader's hard read ceiling. `bytes` is the
    /// file's on-disk size; `ceiling` is the limit it tripped. Carrying
    /// the ceiling lets the user-facing message present this as a real
    /// cap ("exceeds the 512 MB read limit") rather than an arbitrary
    /// refusal — the prior message only said the size, which read as a
    /// bug for a 33 MB file under the old 32 MB gate.
    case tooLarge(bytes: Int, ceiling: Int)
    case binaryFile
}

public struct TextFile: Sendable {
    public let url: URL
    public let contents: String
    public let encoding: String.Encoding
    public let byteCount: Int
    /// Mtime captured at `TextFileLoader.load` time from
    /// `attributesOfItem(atPath:)[.modificationDate]`. `nil` only when
    /// the filesystem failed to report a mtime (rare — synthetic
    /// in-memory `TextFile`s constructed by tests).
    ///
    /// Used as part of derived-product cache keys (rendered HTML,
    /// highlight runs) so a same-byte-length file-watcher reload
    /// (`# Hello\n` → `# World\n`) invalidates without paying an
    /// O(N) content hash on every SwiftUI body re-eval. APFS mtime
    /// is nanosecond-resolution so a back-to-back edit-and-reload
    /// produces a distinct timestamp.
    public let modifiedTime: Date?

    /// True when the file loaded above the loader's `softWarnBytes`
    /// watermark (default 64 MiB). A signal — NOT an identity field —
    /// that tells the read/view path to degrade gracefully: source
    /// mode forces the no-allocation plain fast path and skips the
    /// O(N)-per-interaction overlays (newline-offset index, selection-
    /// highlight, pretty-print) so a few-hundred-MB log stays
    /// interactive. Syntax highlighting is already auto-off above the
    /// 512 KiB `highlightMaxBytes` cap, so a large file never paints
    /// runs regardless.
    ///
    /// Intentionally NOT part of `Equatable` (mirrors `modifiedTime`):
    /// it's derived from `byteCount` + the loader's watermark, so two
    /// equal-`byteCount` loads always agree on it. Folding it into
    /// equality would either be redundant or — if a caller constructed
    /// the same file with a different watermark — introduce spurious
    /// SwiftUI diff churn.
    public let isLargeReadOnly: Bool

    public init(
        url: URL,
        contents: String,
        encoding: String.Encoding,
        byteCount: Int,
        modifiedTime: Date? = nil,
        isLargeReadOnly: Bool = false
    ) {
        self.url = url
        self.contents = contents
        self.encoding = encoding
        self.byteCount = byteCount
        self.modifiedTime = modifiedTime
        self.isLargeReadOnly = isLargeReadOnly
    }
}

/// Equatable by metadata only — full `contents` compare would be O(N).
/// `byteCount` change detects file-watcher reloads (post-write the
/// file size virtually always differs); for the pathological "edit
/// in place same length" case, callers that need bit-equality compare
/// `contents` explicitly.
///
/// `modifiedTime` is intentionally NOT part of equality — it's the
/// cache-key channel, not the "are these the same file?" check. Two
/// loads of an unchanged file constructed at different wall times
/// still compare equal so SwiftUI doesn't see redundant diff churn.
extension TextFile: Equatable {
    public static func == (lhs: TextFile, rhs: TextFile) -> Bool {
        lhs.url == rhs.url
            && lhs.byteCount == rhs.byteCount
            && lhs.encoding == rhs.encoding
    }
}

/// Hard cap on the bytes the source / `NSTextView` loader will pull into
/// memory. This is the WIDEST display cap in the app and MUST be >= every
/// downstream display cap so a file the editor / markdown / highlight path
/// would accept can always at least be loaded off disk.
///
/// SCALE-1 / MAGIC-002: the loader previously hard-coded 32 MB, which is
/// *below* `codeMirrorEditorMaxBytes` (50 MB). A 40 MB file the CM6 editor
/// would happily open could not even be read off disk — the loader threw
/// `.tooLarge` first, so the editor's higher ceiling was dead code. The
/// loader is the single funnel every viewer reads through, so its cap is
/// the union (max) of the per-view caps, never the min.
///
/// Downstream display caps stay at their (lower) values — they govern
/// whether a *successfully loaded* file gets highlighted / rendered /
/// editor-mode, not whether it can be opened at all:
///   * `highlightMaxBytes`        = 512 KB
///   * `markdownRenderMaxBytes`   =   4 MB
///   * `codeMirrorEditorMaxBytes` =  50 MB
public let sourceViewMaxBytes: Int = 64 * 1024 * 1024

public struct TextFileLoader: Sendable {
    /// Two-tier read cap (read/view path, read-only).
    ///
    /// `readableMaxBytes` is the HARD ceiling (default 512 MiB): files
    /// at/below it load fully into a single Swift `String`; above it we
    /// still throw `.tooLarge` — no app survives slurping a multi-GB
    /// file into one String, so this is the OOM backstop, not an
    /// arbitrary refusal. We accept ~1.5–2x file-size resident cost for
    /// the open tab (String + UTF-16 NSTextStorage backing) as the
    /// documented v1 tradeoff; the ceiling bounds the worst case.
    ///
    /// `softWarnBytes` is the watermark (default 64 MiB) above which the
    /// resulting `TextFile.isLargeReadOnly` is set so the view layer
    /// degrades gracefully (plain fast path, skip O(N) overlays). It
    /// does NOT block the load — the file still opens read-only in
    /// source mode.
    ///
    /// A true mmap / line-indexed pager with bounded RAM for GB-class
    /// files (and its own Find / jump-to-line / SIGBUS-lifecycle design)
    /// is the deferred follow-up; `Data(.mappedIfSafe)` is the lower-
    /// risk path to evaluate then (note: bridging mapped `Data` to
    /// `String` copies the whole thing, so it is not a free win for v1).
    public let readableMaxBytes: Int

    /// Files above this size load successfully but are tagged
    /// `isLargeReadOnly` so the source view skips per-interaction O(N)
    /// overlay work. See `readableMaxBytes` doc for the full rationale.
    public let softWarnBytes: Int

    /// Back-compat alias for the prior single `maxBytes` knob — maps to
    /// the hard read ceiling so existing callers / tests that pass
    /// `TextFileLoader(maxBytes:)` keep working unchanged.
    public var maxBytes: Int { readableMaxBytes }

    public init(
        readableMaxBytes: Int = 512 * 1024 * 1024,
        softWarnBytes: Int = 64 * 1024 * 1024
    ) {
        self.readableMaxBytes = readableMaxBytes
        self.softWarnBytes = softWarnBytes
    }

    /// Back-compat initializer mirroring the prior `init(maxBytes:)`.
    /// Sets the hard read ceiling to `maxBytes` and keeps the default
    /// soft watermark (clamped never to exceed the ceiling so a small
    /// custom ceiling can't accidentally leave the watermark above it).
    public init(maxBytes: Int) {
        self.readableMaxBytes = maxBytes
        self.softWarnBytes = min(64 * 1024 * 1024, maxBytes)
    }

    /// Load `url` as text. `forceText` (WAVE 2b item 6 — "Open As… text /
    /// CSV / JSON / source") bypasses the NUL-byte binary heuristic: when
    /// the user explicitly asks to view a binary file as text, we decode
    /// the bytes with a lossy fallback (Latin-1 never fails) rather than
    /// throwing `.binaryFile`. The size ceiling + not-readable / not-found
    /// errors still apply.
    public func load(url: URL, forceText: Bool = false) throws -> TextFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileLoadError.fileNotFound
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        // Stat-first refusal: we check size BEFORE reading so a file
        // above the ceiling never allocates. (Tests rely on this
        // ordering — a sparse/truncated file whose stat size exceeds the
        // ceiling trips this without writing the bytes. Do NOT reorder
        // to read-before-stat.)
        if let size = attrs?[.size] as? Int, size > readableMaxBytes {
            throw FileLoadError.tooLarge(bytes: size, ceiling: readableMaxBytes)
        }
        // Derived once from the on-disk size; threaded into every
        // TextFile construction below. `byteCount` (data.count) equals
        // the stat size for the non-BOM paths and is 2–3 bytes smaller
        // for BOM-stripped paths — immaterial at the 64 MiB watermark,
        // and we key the flag off the actual `data.count` we store so
        // the flag and byteCount never disagree.
        // Captured once at load time so derived-product caches (rendered
        // HTML, highlight runs) can key off it without re-stat'ing the
        // file on every body re-eval. APFS gives nanosecond resolution,
        // so a back-to-back rewrite of the same byte length still
        // produces a distinct timestamp — invalidates the cache where
        // the prior `byteCount`-only key would have served stale output.
        let mtime = attrs?[.modificationDate] as? Date

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileLoadError.notReadable
        }

        switch TextDecoder.decode(data) {
        case .text(let s, let enc):
            return TextFile(
                url: url, contents: s, encoding: enc,
                byteCount: data.count, modifiedTime: mtime,
                isLargeReadOnly: data.count > softWarnBytes
            )
        case .binary:
            // "Open As… text" override: decode the raw bytes as Latin-1
            // (a total, never-failing 1:1 byte→codepoint map) so the user
            // can inspect a binary's textual fragments. Without the
            // override this is a hard `.binaryFile` → HEX fall-through.
            if forceText {
                let s = String(decoding: data, as: UTF8.self).isEmpty
                    ? Self.latin1(data)
                    : (String(data: data, encoding: .utf8) ?? Self.latin1(data))
                return TextFile(
                    url: url, contents: s, encoding: .isoLatin1,
                    byteCount: data.count, modifiedTime: mtime,
                    isLargeReadOnly: data.count > softWarnBytes
                )
            }
            throw FileLoadError.binaryFile
        case .undecodable:
            if forceText {
                return TextFile(
                    url: url, contents: Self.latin1(data), encoding: .isoLatin1,
                    byteCount: data.count, modifiedTime: mtime,
                    isLargeReadOnly: data.count > softWarnBytes
                )
            }
            throw FileLoadError.decodingFailed
        }
    }

    /// Lossless Latin-1 decode: every byte 0x00–0xFF maps to the same
    /// Unicode scalar, so this never fails — the fallback for the
    /// force-text path on otherwise-undecodable / binary content.
    private static func latin1(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    // Encoding-detection statics moved to `TextDecoder` (shared with
    // `CrossFileSearch`). Thin re-exports retained for the existing
    // unit tests that probe them by name.
    static func decodeViaBOM(_ data: Data) -> (String, String.Encoding)? {
        TextDecoder.decodeViaBOM(data)
    }
    static func looksBinary(_ data: Data) -> Bool { TextDecoder.looksBinary(data) }
    static func decodeUTF16WithoutBOM(_ data: Data) -> (string: String, encoding: String.Encoding)? {
        TextDecoder.decodeUTF16WithoutBOM(data)
    }
}

/// Shared text-decoding chain used by both `TextFileLoader` (whole-file
/// open) and `CrossFileSearch` (per-file grep). Centralizes the BOM →
/// UTF-16 → UTF-8 → Windows-1252 → Latin-1 ladder so the two call sites
/// can't drift (I18N-02 / PARSE-08).
///
/// Ordering rationale:
///   1. **BOM** — unambiguous; UTF-16/UTF-8 BOMs pin the encoding.
///   2. **NUL heuristic** — a NUL in the first 8 KB means either real
///      binary OR BOM-less UTF-16 (one NUL per ASCII char). Probe
///      BOM-less UTF-16 before declaring `.binary`.
///   3. **Strict UTF-8** — the overwhelmingly common case.
///   4. **Windows-1252 (CP1252)** — inserted BEFORE Latin-1 (I18N-01).
///      CP1252 is a superset of Latin-1 over 0x80–0x9F (smart quotes,
///      em-dash, euro sign). Latin-1 maps those bytes to C1 control
///      codes, silently mis-decoding the most common non-UTF-8 Windows
///      text. We only fall to CP1252 when strict UTF-8 fails, so valid
///      UTF-8 is never mis-attributed.
///   5. **Latin-1** — final catch-all. Maps every byte 0x00–0xFF to a
///      scalar, so it never fails; reached only for the rare byte
///      sequence CP1252 rejects (0x81/0x8D/0x8F/0x90/0x9D are undefined
///      in CP1252 and make `String(data:encoding:.windowsCP1252)` fail).
public enum TextDecoder {

    public enum Decoded: Equatable {
        case text(String, String.Encoding)
        case binary
        case undecodable
    }

    /// Full chain. Returns the decoded string + the encoding chosen
    /// (so callers can surface it to a status bar), `.binary` for NUL-
    /// laden non-UTF-16 content, or `.undecodable` (effectively never —
    /// Latin-1 is total — but kept for symmetry).
    public static func decode(_ data: Data) -> Decoded {
        // (1) BOM.
        if let (s, enc) = decodeViaBOM(data) { return .text(s, enc) }

        // (2) Binary guard, with a BOM-less UTF-16 escape hatch.
        if looksBinary(data) {
            if let s = decodeUTF16WithoutBOM(data) {
                return .text(s.string, s.encoding)
            }
            return .binary
        }

        // (3) Strict UTF-8.
        if let s = String(data: data, encoding: .utf8) {
            return .text(s, .utf8)
        }
        // (4) Windows-1252 before Latin-1 (I18N-01).
        if let s = String(data: data, encoding: .windowsCP1252) {
            return .text(s, .windowsCP1252)
        }
        // (5) Latin-1 — total, last resort.
        if let s = String(data: data, encoding: .isoLatin1) {
            return .text(s, .isoLatin1)
        }
        return .undecodable
    }

    /// Convenience for callers that only need the string and treat
    /// binary / undecodable as "skip" (e.g. CrossFileSearch).
    public static func decodeToString(_ data: Data) -> String? {
        if case .text(let s, _) = decode(data) { return s }
        return nil
    }

    /// Attempt to decode `data` as UTF-16 (either endianness) when the
    /// caller has already ruled out BOM-prefixed UTF-16. Used as a
    /// fallback after `looksBinary` triggers, to catch BOM-less UTF-16
    /// files that appear binary because of interleaved NUL bytes.
    ///
    /// Heuristic: ASCII-heavy UTF-16 has NUL at EVERY odd byte (LE) or
    /// EVERY even byte (BE). Anything weaker than ~80% of slots being
    /// NUL in one parity is almost certainly real binary content.
    /// Requires the sample to be at least 32 bytes, otherwise the
    /// signal is too weak to trust.
    public static func decodeUTF16WithoutBOM(_ data: Data) -> (string: String, encoding: String.Encoding)? {
        guard data.count >= 32, data.count % 2 == 0 else { return nil }
        let sample = data.prefix(2048)
        let n = sample.count
        // Count NUL positions in even/odd byte slots. UTF-16 LE ASCII
        // text has NUL at every odd index; UTF-16 BE ASCII at every
        // even index. Random binary distributes NULs evenly.
        var oddNULs = 0
        var evenNULs = 0
        var oddNonZero = 0
        var evenNonZero = 0
        for i in 0..<n {
            let byte = sample[sample.startIndex + i]
            if i % 2 == 0 {
                if byte == 0 { evenNULs += 1 } else { evenNonZero += 1 }
            } else {
                if byte == 0 { oddNULs += 1 } else { oddNonZero += 1 }
            }
        }
        // Require ≥ 80% of one parity slot to be NUL AND the other
        // parity to be non-NUL ≥ 80% — the ASCII-heavy UTF-16 fingerprint.
        let halfSlots = n / 2
        let strong = (halfSlots * 8) / 10  // 80%
        if oddNULs >= strong, evenNonZero >= strong,
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return (s, .utf16LittleEndian)
        }
        if evenNULs >= strong, oddNonZero >= strong,
           let s = String(data: data, encoding: .utf16BigEndian) {
            return (s, .utf16BigEndian)
        }
        return nil
    }

    // MARK: - Encoding detection

    public static func decodeViaBOM(_ data: Data) -> (String, String.Encoding)? {
        guard data.count >= 2 else { return nil }
        // Index via `startIndex` offsets so a non-zero-based slice (the
        // macOS-26 `Data` slice-offset trap) still reads the right bytes.
        let base = data.startIndex
        let b0 = data[base], b1 = data[base + 1]
        // UTF-16 LE (FF FE)
        if b0 == 0xFF && b1 == 0xFE {
            if let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return (s, .utf16LittleEndian)
            }
        }
        // UTF-16 BE (FE FF)
        if b0 == 0xFE && b1 == 0xFF {
            if let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return (s, .utf16BigEndian)
            }
        }
        // UTF-8 (EF BB BF)
        if data.count >= 3 && b0 == 0xEF && b1 == 0xBB && data[base + 2] == 0xBF {
            if let s = String(data: data.dropFirst(3), encoding: .utf8) {
                return (s, .utf8)
            }
        }
        return nil
    }

    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        for byte in sample where byte == 0 {
            return true
        }
        return false
    }
}
