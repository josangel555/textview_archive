import Foundation

/// TSK-1129 — the one-time confirm hook for untrusted workspace-local LSP
/// server binaries (owner-resolved 2026-07-07: prompt-first-then-block).
///
/// The app shell installs an NSAlert-backed handler at launch; test hosts
/// install a canned one. With NO handler installed the guard FAILS CLOSED
/// (headless / automation contexts never silently run a repo-shipped
/// binary). The handler runs synchronously — the LSP pool's spawn waits on
/// the user's answer, which is the point of a confirm gate.
public enum LSPTrustPrompt {

    /// (binary, workspaceRoot) → user confirmed. Installed once by the app
    /// shell; `nonisolated(unsafe)` — written at launch before any LSP
    /// spawn, read from the pool's executor thereafter.
    nonisolated(unsafe) public static var confirmHandler: ((URL, URL) -> Bool)?

    /// Ask, failing closed when no handler is installed.
    public static func confirm(binary: URL, workspace: URL) -> Bool {
        confirmHandler?(binary, workspace) ?? false
    }
}
