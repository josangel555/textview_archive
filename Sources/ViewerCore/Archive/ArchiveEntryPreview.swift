import Foundation

/// TSK-1469 — the select-an-entry → INLINE PREVIEW model for the archive
/// browser. `ArchiveCatalog.zipEntryBytes` (the hardened unzip pipe) supplies
/// the bytes; this classifies them into what the pane renders — pure over
/// (name, bytes/size), so every branch is host-tested. The SwiftUI pane and
/// the Extract… save-panel flow (which routes its destination through
/// `OutputNaming.nonColliding` — never overwrite) are the render tail.
public enum ArchiveEntryPreview: Equatable, Sendable {
    /// Decoded UTF-8 text, ready for the text lens. `truncated` when the
    /// entry was cut at the preview cap.
    case text(String, truncated: Bool)
    /// An image the pane shows inline (raw bytes + the matched format).
    case image(Data, format: ImageFormat)
    /// Binary content — show the size + a hex-lens affordance instead.
    case binary(byteCount: Int)
    /// Larger than the preview cap and not previewable in a window — show
    /// the size + "extract to view".
    case tooBig(byteCount: Int)
    /// The entry couldn't be read (corrupt archive, encrypted entry, tool
    /// failure) — show the reason, never crash.
    case unreadable(reason: String)

    /// Image formats recognized for inline preview, sniffed by MAGIC BYTES
    /// (extension is a hint, bytes are the truth — an archive can lie).
    public enum ImageFormat: String, Equatable, Sendable {
        case png, jpeg, gif
    }

    /// Preview cap: entries above this aren't decoded/shown inline (the
    /// archive pane is a PEEK, not a viewer — extract for the full file).
    public static let previewCap = 2 * 1024 * 1024  // 2 MiB

    /// Classify entry `bytes` (as returned by the catalog) into a preview.
    /// `fullSize` is the entry's uncompressed size from the LISTING — when it
    /// exceeds the cap the caller may pass truncated bytes (or none) and gets
    /// `.tooBig`/`.text(truncated:)` accordingly.
    public static func classify(name: String, bytes: Data, fullSize: Int? = nil) -> ArchiveEntryPreview {
        let total = fullSize ?? bytes.count
        // Magic-byte image sniff FIRST (bytes are the truth).
        if let fmt = sniffImage(bytes) {
            return total <= previewCap
                ? .image(bytes, format: fmt)
                : .tooBig(byteCount: total)
        }
        if total > previewCap {
            // Text entries above the cap still get a truncated text PEEK when
            // the caller supplied prefix bytes and they decode.
            if !bytes.isEmpty, bytes.count <= previewCap,
               let head = decodeUTF8Prefix(bytes) {
                return .text(head, truncated: true)
            }
            return .tooBig(byteCount: total)
        }
        if let text = String(data: bytes, encoding: .utf8), !looksBinary(text) {
            return .text(text, truncated: false)
        }
        return .binary(byteCount: total)
    }

    /// The failure branch the pane renders when `zipEntryBytes` throws —
    /// mapped here so the reason wording is single-sourced + testable.
    public static func failed(_ error: Error) -> ArchiveEntryPreview {
        .unreadable(reason: (error as? LocalizedError)?.errorDescription
            ?? String(describing: error))
    }

    // MARK: - sniffers

    static func sniffImage(_ bytes: Data) -> ImageFormat? {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        return nil
    }

    /// A control-character density check: NUL or a high density of C0
    /// controls (excluding \t \n \r) means "not really text".
    static func looksBinary(_ s: String) -> Bool {
        if s.isEmpty { return false }
        var controls = 0
        var total = 0
        for u in s.unicodeScalars {
            total += 1
            if u.value == 0 { return true }
            if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" {
                controls += 1
            }
            if total >= 4096 { break }  // sample the head; enough signal
        }
        return total > 0 && controls * 20 > total  // >5% controls
    }

    /// Decode a byte PREFIX as UTF-8, trimming a torn trailing code point
    /// (a truncated multi-byte sequence must not fail the whole decode).
    static func decodeUTF8Prefix(_ bytes: Data) -> String? {
        var slice = bytes
        for _ in 0..<4 {  // a UTF-8 code point is ≤4 bytes
            if let s = String(data: slice, encoding: .utf8) {
                return looksBinary(s) ? nil : s
            }
            if slice.isEmpty { return nil }
            slice = slice.dropLast()
        }
        return nil
    }
}
