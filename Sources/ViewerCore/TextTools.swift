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

/// Command-ready, surface-agnostic catalog of the Tools verbs. A future
/// command/clipboard/editor surface iterates `allCases` to register each as
/// a palette action, then calls `TextTools.apply(_:to:)` with the input it
/// has on hand (clipboard string or editor selection) — so this layer does
/// NOT commit to a particular UX. `rawValue` doubles as the canonical
/// `scriptVerb` for `CommandDescriptor`.
public enum TextToolVerb: String, CaseIterable, Sendable {
    case generateUUID = "tools.uuid"
    case sha256       = "tools.sha256"
    case base64Encode = "tools.base64Encode"
    case base64Decode = "tools.base64Decode"

    /// Human-readable command title (palette / menu label).
    public var title: String {
        switch self {
        case .generateUUID: return "Generate UUID"
        case .sha256:       return "SHA-256 (hex)"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        }
    }

    /// `false` for generators (`.generateUUID` ignores input); `true` for
    /// transforms that consume the current selection/clipboard text.
    public var transformsInput: Bool { self != .generateUUID }
}

public extension TextTools {
    /// Apply a `TextToolVerb` to optional input text (an editor selection or
    /// the clipboard). Returns the result, or `nil` when a transform fails
    /// (e.g. `.base64Decode` on non-Base64 input). `.generateUUID` ignores
    /// `input`. The whole Tools surface bottoms out here, so the actual
    /// transforms stay in one tested place regardless of how they're invoked.
    static func apply(_ verb: TextToolVerb, to input: String?) -> String? {
        switch verb {
        case .generateUUID: return uuid()
        case .sha256:       return sha256Hex(input ?? "")
        case .base64Encode: return base64Encode(input ?? "")
        case .base64Decode: return input.flatMap(base64Decode)
        }
    }
}
