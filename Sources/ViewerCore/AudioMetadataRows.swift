import Foundation

/// Builds the Title/Artist/Album/Year tag rows for the file-info panel's Audio
/// section (TSK-807) from AVFoundation common-metadata items. Pure — the
/// AVAsset → `(key,value)` extraction lives in the view layer (un-host-testable,
/// like the other AVAsset stats), but the key→label mapping, display order,
/// empty-omission, and year extraction are host-tested here.
public enum AudioMetadataRows {

    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// AVMetadata common-key rawValues → display labels, in display order.
    private static let ordered: [(key: String, label: String)] = [
        ("title", "Title"),
        ("artist", "Artist"),
        ("albumName", "Album"),
        ("creationDate", "Year"),
    ]

    /// Ordered, de-duplicated tag rows from common-metadata `(keyRawValue, value)`
    /// pairs. Unknown keys are ignored; empty/whitespace values are omitted; the
    /// first value wins for a repeated key; a `creationDate` is shown as a 4-digit
    /// year when the value leads with one.
    public static func build(common: [(key: String, value: String?)]) -> [Row] {
        var byKey: [String: String] = [:]
        for (key, value) in common {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty, byKey[key] == nil { byKey[key] = trimmed }
        }
        return ordered.compactMap { (key, label) in
            guard let raw = byKey[key] else { return nil }
            return Row(label, key == "creationDate" ? yearOnly(raw) : raw)
        }
    }

    /// Extract a leading 4-digit year from a date-ish string ("2021",
    /// "2021-05-01", "2021-05-01T09:00Z"); returns the input unchanged when it
    /// doesn't lead with four digits.
    static func yearOnly(_ s: String) -> String {
        let prefix = s.prefix(4)
        if prefix.count == 4, prefix.allSatisfy({ $0.isNumber }) { return String(prefix) }
        return s
    }
}
