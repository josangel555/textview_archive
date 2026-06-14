import Foundation

/// Human-readable names for CoreMedia media-subtype FourCC codes (TSK-348 deep
/// metadata — the codec rows in the file-info panel). Pure + host-testable: the
/// AVAsset side just hands us the `CMFormatDescriptionGetMediaSubType` FourCC.
public enum MediaCodecName {

    /// Map a media-subtype FourCC (e.g. `'avc1'`) to a friendly name, falling
    /// back to the raw 4-char tag (trimmed) for anything we don't recognize —
    /// so an unknown codec still shows something meaningful rather than blank.
    public static func display(fourCC: UInt32) -> String {
        if let known = known[fourCC] { return known }
        let raw = tag(fourCC).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "Unknown" : raw
    }

    /// Decode a FourCharCode into its 4 ASCII characters (big-endian byte
    /// order, as CoreMedia stores them). Non-printable bytes render as '?'.
    static func tag(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let scalars = bytes.map { b -> Character in
            (b >= 0x20 && b < 0x7F) ? Character(UnicodeScalar(b)) : "?"
        }
        return String(scalars)
    }

    /// Build a FourCC from a 4-character ASCII tag (helper for the table + tests).
    static func code(_ tag: String) -> UInt32 {
        var out: UInt32 = 0
        for b in tag.utf8.prefix(4) { out = (out << 8) | UInt32(b) }
        return out
    }

    /// Known media subtypes → display names. Video + audio.
    static let known: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        func put(_ tags: [String], _ name: String) { for t in tags { m[code(t)] = name } }
        // Video
        put(["avc1", "avc3"], "H.264")
        put(["hvc1", "hev1"], "HEVC")
        put(["mp4v"], "MPEG-4")
        put(["ap4h", "apch", "apcn", "apcs", "apco", "ap4x"], "ProRes")
        put(["vp09"], "VP9")
        put(["av01"], "AV1")
        put(["jpeg"], "Motion JPEG")
        // Audio
        put(["mp4a", "aac "], "AAC")
        put([".mp3", "mp3 "], "MP3")
        put(["alac"], "ALAC")
        put(["lpcm"], "Linear PCM")
        put(["flac"], "FLAC")
        put(["opus"], "Opus")
        put(["ac-3"], "AC-3")
        return m
    }()
}
