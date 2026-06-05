import Foundation

/// Containment policy for paths arriving via the `markdownviewer://`
/// custom URL scheme (`Info.plist` `CFBundleURLTypes`).
///
/// **Threat model:** custom URL schemes are invokable from any local
/// process and from any web page via `<a href="...">`. Without
/// containment, `markdownviewer://open?path=/etc/passwd` becomes a
/// one-click "read arbitrary file" primitive — the user sees a single
/// macOS prompt the first time per source app and is habituated to
/// accept it. The viewer then surfaces the file's contents on screen
/// and (worse) into in-memory buffers reachable via subsequent MCP
/// tool calls.
///
/// **Policy:** mirror `MCPToolCatalog.validatedExistingURL` — the path
/// must resolve, after `~` expansion and standardization, into either:
///   * the user's `$HOME` (or a descendant), or
///   * the per-user temp dir (`/var/folders/.../T/`, where stdin-pipe
///     scratch + tests land).
///
/// Anything else returns nil so the caller drops the request silently.
/// We deliberately do **not** propagate a granular error — the URL
/// scheme is a fire-and-forget channel and a noisy "blocked!" toast
/// would only teach an attacker the boundary.
///
/// **Existence is NOT required here.** The MCP `validatedExistingURL`
/// asserts existence because tools operate on real files; the URL
/// scheme just hands the path off to `model.openPath`, which already
/// handles "file vanished" gracefully. Requiring existence here would
/// also let an attacker probe "does `~/.ssh/id_rsa` exist?" by
/// observing whether the open succeeds. Keep the boundary purely
/// path-shape, not state-disclosing.
public enum URLSchemePolicy {

    /// Returns a `file://` URL iff `raw` (after `~` expansion +
    /// `standardizedFileURL`) is contained in the user's home or
    /// per-user temp dir. Otherwise nil.
    public static func containedPath(_ raw: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        // Reject obviously bogus inputs early.
        guard !expanded.isEmpty else { return nil }
        // URL path must be absolute for the containment comparison to
        // be meaningful. A relative path like `foo/bar` would resolve
        // against the current working dir (usually `/` for GUI apps),
        // which is *not* what the caller meant.
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL.path
        let temp = fm.temporaryDirectory.standardizedFileURL.path
        let p = url.path
        if p == home { return url }
        if p.hasPrefix(home + "/") { return url }
        // ANCHORED prefix only. `temp` does NOT end in `/`
        // (`temporaryDirectory.path` = `/var/folders/<rand>/T`), so a bare
        // `hasPrefix(temp)` would also admit a user-writable SIBLING like
        // `/var/folders/<rand>/T-attacker/loot` — outside the intended jail
        // (AUDIT S2). `== temp || hasPrefix(temp + "/")` is exhaustive + safe.
        if p == temp || p.hasPrefix(temp + "/") {
            return url
        }
        return nil
    }
}
