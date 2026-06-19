import Foundation

/// TSK-908 — clipboard text for the commit context-menu "Copy …" actions
/// (the menu was review-only; these add the common git-reference copies). Pure +
/// host-testable; GitLogTab wires these to menu buttons.
public enum CommitClipboard {

    /// Abbreviated SHA — the first `length` characters (default 8, git's short-hash
    /// convention). Shorter SHAs are returned whole.
    public static func shortSHA(_ sha: String, length: Int = 8) -> String {
        String(sha.prefix(max(0, length)))
    }

    /// A one-line commit reference, `git log --oneline` style: "<shortSHA> <subject>".
    public static func reference(sha: String, subject: String) -> String {
        let short = shortSHA(sha)
        return subject.isEmpty ? short : "\(short) \(subject)"
    }
}
