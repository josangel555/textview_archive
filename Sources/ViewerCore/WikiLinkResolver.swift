import Foundation

/// Resolution policy for in-document file links — `[[wikilinks]]` and plain
/// relative markdown links — clicked in the rendered view (2026-08-01).
///
/// The rust core renders `[[page]]` as a RELATIVE anchor (marked
/// `mdv-wikilink`); WebKit resolves it against the page's base URL (the
/// file's directory) before the navigation reaches the host. Policy, in
/// order:
///
///   1. the clicked path as-is (covers `[[notes.md]]` and relative links);
///   2. the clicked path + `.md` when it has no extension (`[[Design]]` —
///      the Obsidian idiom);
///   3. for SINGLE-component targets only, the same two probes against the
///      workspace root — `[[Design]]` works from anywhere in the tree
///      without making deep relative paths (`../x/y`) jump surprisingly.
///
/// Pure and IO-injectable so the whole ladder is host-testable.
public enum WikiLinkResolver {

    /// The clicked file-URL resolved to an OPENABLE file, or nil (the
    /// caller says "no such note" out loud — never silently ignores).
    public static func resolve(
        clicked: URL,
        baseDir: URL?,
        workspaceRoot: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let direct = clicked.standardizedFileURL
        if fileExists(direct.path) { return direct }
        if direct.pathExtension.isEmpty {
            let withMD = direct.appendingPathExtension("md")
            if fileExists(withMD.path) { return withMD }
        }
        // Workspace-root fallback: only for a bare name (the wikilink
        // idiom), never for a path the author wrote with directories.
        guard let root = workspaceRoot,
              let base = baseDir,
              isSingleComponent(direct, relativeTo: base) else { return nil }
        let name = direct.lastPathComponent
        let atRoot = root.appendingPathComponent(name).standardizedFileURL
        if fileExists(atRoot.path) { return atRoot }
        if atRoot.pathExtension.isEmpty {
            let withMD = atRoot.appendingPathExtension("md")
            if fileExists(withMD.path) { return withMD }
        }
        return nil
    }

    /// True when `url` is directly inside `base` — i.e. the author's link
    /// had no directory components, so the root fallback can't hijack a
    /// deliberate `../elsewhere/name` path.
    static func isSingleComponent(_ url: URL, relativeTo base: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path
            == base.standardizedFileURL.path
    }
}
