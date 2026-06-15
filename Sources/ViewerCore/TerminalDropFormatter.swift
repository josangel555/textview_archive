import Foundation

/// Formats file URLs dropped onto the terminal into a shell-paste string —
/// the path(s) typed at the prompt, NOT the file opened in a tab (TSK-920:
/// "drag a file to the Terminal → print its path; capture/open everywhere
/// else"). Pure + host-testable; the AppKit drop wiring is the VM tail.
public enum TerminalDropFormatter {

    /// Space-separated, POSIX-quoted paths with a trailing space (so the user
    /// can keep typing after the drop). Non-file URLs are dropped; an empty or
    /// all-non-file list yields "".
    public static func shellPaste(for urls: [URL]) -> String {
        let paths = urls.filter(\.isFileURL).map { quote($0.path) }
        guard !paths.isEmpty else { return "" }
        return paths.joined(separator: " ") + " "
    }

    /// POSIX shell quoting. A path made only of safe chars is left bare for
    /// readability; otherwise it's single-quoted with embedded `'` escaped as
    /// `'\''` (the only metachar single-quotes don't neutralise).
    static func quote(_ s: String) -> String {
        guard !s.isEmpty else { return "''" }
        let safe = s.unicodeScalars.allSatisfy { u in
            (u >= "a" && u <= "z") || (u >= "A" && u <= "Z")
                || (u >= "0" && u <= "9") || "._-/".unicodeScalars.contains(u)
        }
        if safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
