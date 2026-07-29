import Foundation

/// TSK-1605 (owner 2026-07-25: "New file should first ask the filename. Do not
/// create Untitled.txt.") — validation for the NAME the new-file prompt
/// collects, so the UI can reject bad input BEFORE touching the disk and say
/// exactly why.
///
/// Mirrors `FileRenamer`'s rules (one in-directory component; no separator,
/// NUL, `.` or `..`) plus a no-clobber check against the target directory, so
/// creating and renaming behave identically.
public enum NewFileNameValidator {

    public enum Verdict: Equatable {
        case ok(String)               // the trimmed, usable name
        case empty
        case invalid(String)          // separator / NUL / . / ..
        case exists(String)           // something already occupies the name
    }

    /// Validate `rawName` for creation inside `directory`.
    /// `fileExists` is injectable so the rule set is host-testable without
    /// touching a real filesystem.
    public static func validate(
        _ rawName: String,
        in directory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Verdict {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard !trimmed.contains("/"), !trimmed.contains("\0"),
              trimmed != ".", trimmed != ".." else {
            return .invalid(trimmed)
        }
        if fileExists(directory.appendingPathComponent(trimmed)) {
            return .exists(trimmed)
        }
        return .ok(trimmed)
    }

    /// A human-readable reason for a rejected verdict (nil when `.ok`).
    public static func message(for verdict: Verdict) -> String? {
        switch verdict {
        case .ok: return nil
        case .empty:
            return "Enter a file name."
        case .invalid(let n):
            return "\u{201C}\(n)\u{201D} isn't a valid file name — "
                + "it can't contain \u{201C}/\u{201D} or be \u{201C}.\u{201D} / \u{201C}..\u{201D}."
        case .exists(let n):
            return "\u{201C}\(n)\u{201D} already exists in this folder."
        }
    }

    /// The prompt's pre-filled suggestion for a `NewFileType`: the type's
    /// default base name with the STEM selected by the caller, so typing
    /// replaces "untitled" while keeping the extension.
    public static func suggestion(for type: NewFileType) -> String {
        type.baseName
    }
}
