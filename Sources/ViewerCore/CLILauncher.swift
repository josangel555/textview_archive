import Foundation

/// `textview` command-line launcher (TSK-696) — the `code`-style shim that opens
/// files in the app from a terminal (`textview file.md`). The wrapper just calls
/// `open -a <AppBundle> "$@"`, so files route through the app's existing
/// `application(_:open:)` handler — no launch-arg parsing needed.
///
/// Pure logic (script generation + install into a directory) lives here so it's
/// host-testable; the menu action + the writable-dir choice + user alerts are
/// the thin AppKit shell.
public enum CLILauncher {
    /// The command name installed on PATH.
    public static let commandName = "textview"

    /// Conventional install dir — in the default macOS `PATH` and usually
    /// user-writable on dev machines (Homebrew owns it). The caller falls back
    /// to `fallbackBinDir()` when this isn't writable.
    public static let preferredBinDir = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    /// Per-user fallback when `/usr/local/bin` isn't writable (no admin needed).
    /// The user adds it to `PATH` (the install alert says so).
    public static func fallbackBinDir() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// The wrapper script that opens file arguments in the app bundle at
    /// `appPath`. `open(1)` resolves relative paths against the caller's cwd and
    /// hands files to `application(_:open:)`. No args ⇒ just launch the app.
    public static func wrapperScript(appPath: String) -> String {
        """
        #!/bin/sh
        # TextView command-line launcher (managed by TextView — TSK-696).
        # Regenerate via Help ▸ Install '\(commandName)' Command.
        APP=\(shellSingleQuoted(appPath))
        if [ "$#" -eq 0 ]; then
          exec /usr/bin/open -a "$APP"
        fi
        exec /usr/bin/open -a "$APP" "$@"
        """
    }

    /// Write the wrapper into `binDir` (which must already exist) and mark it
    /// executable (0755). Throws if the directory isn't writable — the caller
    /// catches that to fall back / surface guidance. Returns the installed path.
    @discardableResult
    public static func install(
        appPath: String, into binDir: URL, name: String = commandName
    ) throws -> URL {
        let dest = binDir.appendingPathComponent(name)
        try wrapperScript(appPath: appPath).write(to: dest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dest.path)
        return dest
    }

    /// Ensure `binDir` exists (creating intermediate dirs) then install. Used
    /// for the per-user fallback dir, which won't exist on first install.
    @discardableResult
    public static func installCreatingDir(
        appPath: String, into binDir: URL, name: String = commandName
    ) throws -> URL {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        return try install(appPath: appPath, into: binDir, name: name)
    }

    /// True when an executable command of `name` already exists in `binDir`.
    public static func isInstalled(in binDir: URL, name: String = commandName) -> Bool {
        FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent(name).path)
    }

    /// Single-quote a string for safe embedding in `/bin/sh` (handles spaces and
    /// embedded apostrophes), so an app path like `/Users/x/My Apps/TextView.app`
    /// survives intact.
    static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
