import Foundation

/// TSK-1129 (security, slice 1) — the decision core for confirming a
/// WORKSPACE-LOCAL language-server binary before spawning it. A hostile repo can
/// ship a fake LSP server (e.g. `node_modules/.bin/<server>`, or a workspace
/// `lsp.json` overriding `command` to a repo-local path); auto-spawning it on
/// browse is arbitrary code execution. This module decides whether a resolved
/// server binary needs a one-time trust confirmation.
///
/// PURE (no I/O) so it is fully host-testable. The persistence store, the confirm
/// prompt, and the `LSPPool` spawn-gate that consult it are the integration tail
/// (slices 2+); this is the hard-to-get-right path-confinement primitive.
public enum LSPBinaryTrust {

    /// Whether `binary` resolves to a location INSIDE `workspaceRoot`. Compared on
    /// standardized, symlink-resolved absolute paths with a trailing-separator
    /// boundary (so `/ws` does not match a sibling `/ws-evil`), mirroring
    /// `HTMLDocumentPolicy.isWithinDocumentTree`. Resolving symlinks means a binary
    /// that symlinks OUT of the tree is judged by where it ACTUALLY runs from — a
    /// repo can't dodge the check via a symlink, and a workspace symlink pointing at
    /// a real system binary is correctly treated as external (safe).
    public static func isWorkspaceLocal(binary: URL, workspaceRoot: URL) -> Bool {
        guard binary.isFileURL, workspaceRoot.isFileURL else { return false }
        let rootStd = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let binStd = binary.standardizedFileURL.resolvingSymlinksInPath()
        var root = rootStd.path
        if !root.hasSuffix("/") { root += "/" }
        return binStd.path.hasPrefix(root)
    }

    public enum Decision: Equatable {
        /// Safe to spawn now — a system/PATH/Homebrew binary, or already trusted.
        case allow
        /// A workspace-local binary the user hasn't trusted: require a one-time
        /// confirm before spawning.
        case needsTrust
    }

    /// The spawn decision for a resolved server `binary` under `workspaceRoot`,
    /// given the set of already-trusted (canonical, symlink-resolved) absolute
    /// paths. Only a workspace-local, not-yet-trusted binary needs confirmation;
    /// binaries outside the workspace (the common case — sourcekit-lsp /
    /// rust-analyzer on PATH) are allowed without friction.
    public static func decision(
        binary: URL,
        workspaceRoot: URL,
        trustedPaths: Set<String>
    ) -> Decision {
        guard isWorkspaceLocal(binary: binary, workspaceRoot: workspaceRoot) else {
            return .allow
        }
        let canonical = binary.standardizedFileURL.resolvingSymlinksInPath().path
        return trustedPaths.contains(canonical) ? .allow : .needsTrust
    }

    /// The canonical (standardized, symlink-resolved) path to record when the user
    /// trusts a binary — so the trust survives a symlink alias and matches
    /// `decision`'s lookup.
    public static func canonicalPath(for binary: URL) -> String {
        binary.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
