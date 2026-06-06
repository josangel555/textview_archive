import Foundation
import CryptoKit

/// Pure, side-effect-free text-transform utilities backing the "Tools"
/// command family (TSK-292 SHA-256, TSK-294 Base64, TSK-295 random UUID).
///
/// Kept dependency-free — only Foundation + Apple's system `CryptoKit`
/// (no third-party packages) — and free of any app/UI state so every
/// transform is exhaustively unit-testable in the headless tier. The
/// command / clipboard / editor-insertion *surface* that invokes these is
/// deliberately wired separately (its UX — operate-on-selection vs.
/// clipboard round-trip — is an owner decision); this is the de-risked,
/// correctness-pinned core those surfaces share.
public enum TextTools {

    /// A fresh lowercased v4 UUID, e.g. `f47ac10b-58cc-4372-a567-0e02b2c3d479`.
    /// Lowercased because that's the dominant convention in source/config
    /// (JSON, env files) where these get pasted.
    public static func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    /// Base64-encode the UTF-8 bytes of `text` (standard alphabet, padded).
    public static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Decode a Base64 string back to UTF-8 text. Returns `nil` when the
    /// input isn't decodable Base64 or the decoded bytes aren't valid
    /// UTF-8. `.ignoreUnknownCharacters` tolerates the whitespace/newlines
    /// of pasted or MIME-wrapped Base64.
    public static func base64Decode(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text,
                              options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text` (64 hex chars).
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
