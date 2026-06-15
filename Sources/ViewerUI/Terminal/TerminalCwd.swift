import Foundation

/// Resolves the working directory a "new terminal here" should start in
/// (TSK-769 "Open Terminal Here"). Pure — no filesystem access — so it is
/// host-testable.
enum TerminalCwd {

    /// The directory to `cd` a new terminal into for the focused item:
    /// - a focused FILE → its containing folder,
    /// - a focused FOLDER (URL marked as a directory path) → the folder itself,
    /// - a non-file URL or `nil` → `nil` (the terminal then falls back to home).
    static func workingDirectory(forFocusedFile url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        return url.hasDirectoryPath ? url : url.deletingLastPathComponent()
    }

    /// Working directory for a sidebar node whose directory-ness is KNOWN from
    /// the file tree — don't trust `URL.hasDirectoryPath`, which keys off a
    /// trailing slash that sidebar URLs usually lack (TSK-914): a folder URL
    /// without the marker would otherwise resolve to its PARENT. A folder → the
    /// folder itself; a file → its containing folder; a non-file URL → nil.
    static func workingDirectory(for url: URL, isDirectory: Bool) -> URL? {
        guard url.isFileURL else { return nil }
        return isDirectory ? url : url.deletingLastPathComponent()
    }
}
