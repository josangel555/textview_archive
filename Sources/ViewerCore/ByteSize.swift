import Foundation

/// Byte-size string formatting shared across the large-file cap banners
/// (Rendered / CodeMirror / HTML "this file is X, capped at Y"). These
/// banners only appear for multi-megabyte files, so a fixed "%.1f MB"
/// rendering is intentional — previously this was a private `byteString`
/// duplicated in three views.
public enum ByteSize {
    public static func mbString(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
