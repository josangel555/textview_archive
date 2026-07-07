import Foundation

/// TSK-1249 — the terminal pane's header string: "Terminal — <name>
/// [<cwd>, pid <n>]". Pure formatter so the composition (home-abbreviation,
/// missing-field handling, path shortening) is host-tested; the SwiftUI
/// header row that renders it (bound to the live OSC-7 cwd + childPID) is
/// the render tail.
public enum TerminalHeader {

    /// Compose the header. `name` is the tab title; `cwd` the live working
    /// directory (nil until OSC-7 reports one); `pid` the child process id
    /// (nil before spawn / after exit). `home` is injectable for testing;
    /// production passes the real home.
    public static func format(
        name: String,
        cwd: String?,
        pid: Int32?,
        home: String = NSHomeDirectory()
    ) -> String {
        var head = "Terminal"
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            head += " — \(trimmedName)"
        }
        var bracket: [String] = []
        if let cwd, !cwd.isEmpty {
            bracket.append(abbreviateHome(cwd, home: home))
        }
        if let pid {
            bracket.append("pid \(pid)")
        }
        if bracket.isEmpty { return head }
        return "\(head) [\(bracket.joined(separator: ", "))]"
    }

    /// Replace a leading `home` path with `~` (exact home → `~`; a child →
    /// `~/rest`). Non-home paths pass through unchanged.
    static func abbreviateHome(_ path: String, home: String) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}
