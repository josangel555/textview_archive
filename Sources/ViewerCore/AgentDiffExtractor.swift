import Foundation

/// Turns an agent (Claude Code) file-mutating tool call into a reviewable
/// unified diff (TSK-940 — "Review agent-written diffs in-app").
///
/// The Claude transcript parser (`ClaudeLogParser`) already decodes
/// `tool_use` blocks into `ClaudeEvent.toolUse(id:name:input:)`, where the
/// `input` dictionary carries the literal edit payload:
///
///   - `Edit`      → `file_path`, `old_string`, `new_string`
///   - `Write`     → `file_path`, `content`            (whole-file create/replace)
///   - `MultiEdit` → `file_path`, `edits` (a JSON array of
///                    `{old_string,new_string,replace_all?}` objects, stringified
///                    by `ClaudeLogParser.stringifyInput` into a compact JSON string)
///
/// Previously the monitor's detail card dumped these as a raw key/value text
/// blob — so an agent edit read as a wall of `old_string: …` / `new_string: …`
/// text, never as a diff. This extractor maps the tool input into standard
/// unified-diff TEXT (`--- / +++ / @@ … @@` with `+`/`-`/` ` line prefixes),
/// which flows straight into the existing render path
/// (`RustDiffAdapter.parse` → `UnifiedDiff` → `DiffView`).
///
/// Faithful, not clever: Claude's `Edit` is a literal string substitution, so
/// the honest diff is "the matched old block removed, the new block added" in a
/// single hunk. We do NOT run a token/line LCS to minimise the hunk — that would
/// misrepresent what the agent actually did (an exact string swap) and risks
/// showing a "smaller" diff than the real mutation. `Write` is rendered as a
/// new-file diff (every line added). Pure, deterministic, host-testable; no Rust
/// or FileManager dependency.
public enum AgentDiffExtractor {

    /// The set of tool names this extractor can turn into a diff.
    public static let diffableToolNames: Set<String> = ["Edit", "Write", "MultiEdit"]

    /// True when `name` is a file-mutating tool we can render as a diff.
    public static func isDiffable(toolName name: String) -> Bool {
        diffableToolNames.contains(name)
    }

    /// Convenience over a `ClaudeEvent`: returns the unified-diff text for a
    /// diffable `toolUse` event, or `nil` for any other event kind / non-diffable
    /// tool / empty payload.
    public static func unifiedDiffText(for event: ClaudeEvent) -> String? {
        guard case let .toolUse(_, name, input) = event.kind else { return nil }
        return unifiedDiffText(toolName: name, input: input)
    }

    /// Returns the unified-diff text for a tool call, or `nil` when the tool is
    /// not a diffable mutation or the payload is missing/empty (e.g. an `Edit`
    /// whose `old_string == new_string` is a no-op and yields `nil`).
    public static func unifiedDiffText(toolName: String, input: [String: String]) -> String? {
        let path = input["file_path"] ?? input["path"] ?? ""
        switch toolName {
        case "Edit":
            guard let oldStr = input["old_string"], let newStr = input["new_string"] else {
                return nil
            }
            return editFileText(path: path, edits: [(oldStr, newStr)])
        case "Write":
            guard let content = input["content"] else { return nil }
            return writeFileText(path: path, content: content)
        case "MultiEdit":
            guard let edits = parseMultiEdits(input["edits"]), !edits.isEmpty else {
                return nil
            }
            return editFileText(path: path, edits: edits)
        default:
            return nil
        }
    }

    // MARK: - Write (whole-file create/replace)

    /// A `Write` renders as a new-file diff: every content line is added.
    /// (We can't know whether the file pre-existed from the tool input alone, so
    /// we present it as a create — the honest "here is the full content the agent
    /// wrote" view.) Emits the full git-diff preamble (`diff --git`, `new file
    /// mode`) that `RustDiffAdapter.parse` requires to recognise the file.
    private static func writeFileText(path: String, content: String) -> String {
        let p = gitPath(path)
        let lines = splitKeepingTrailingEmpty(content)
        var out = "diff --git a/\(p) b/\(p)\n"
        out += "new file mode 100644\n"
        out += "--- /dev/null\n"
        out += "+++ b/\(p)\n"
        out += "@@ -0,0 +1,\(lines.count) @@\n"
        for line in lines {
            out += "+" + line + "\n"
        }
        return out
    }

    // MARK: - Edit / MultiEdit

    /// Builds an edit diff for one file from an ordered list of
    /// `(old_string, new_string)` replacements — one hunk per replacement.
    /// Returns `nil` if every edit is a no-op (old == new).
    private static func editFileText(path: String, edits: [(old: String, new: String)]) -> String? {
        let p = gitPath(path)
        var hunks = ""
        // Track a running line cursor so successive hunks carry monotonically
        // increasing, plausible line numbers (the exact source offset is unknown
        // from the tool input — Edit matches by string, not by line — so we
        // synthesise a sequential layout that reads correctly in the diff view).
        var oldCursor = 1
        var newCursor = 1
        var emittedAny = false
        for edit in edits {
            if edit.old == edit.new { continue }  // no-op, skip
            let oldLines = edit.old.isEmpty ? [] : splitKeepingTrailingEmpty(edit.old)
            let newLines = edit.new.isEmpty ? [] : splitKeepingTrailingEmpty(edit.new)
            let oldCount = oldLines.count
            let newCount = newLines.count
            // Git convention: a side with zero lines reports its start as the
            // line BEFORE the change (`start-1`), not the running cursor — e.g.
            // a pure deletion is `@@ -1,2 +0,0 @@`. Honour that so the output is
            // a faithful, `git apply`-shaped hunk header.
            let oldStart = oldCount == 0 ? max(oldCursor - 1, 0) : oldCursor
            let newStart = newCount == 0 ? max(newCursor - 1, 0) : newCursor
            hunks += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for line in oldLines { hunks += "-" + line + "\n" }
            for line in newLines { hunks += "+" + line + "\n" }
            oldCursor += oldCount
            newCursor += newCount
            emittedAny = true
        }
        guard emittedAny else { return nil }
        var out = "diff --git a/\(p) b/\(p)\n"
        out += "--- a/\(p)\n"
        out += "+++ b/\(p)\n"
        out += hunks
        return out
    }

    /// Decodes a `MultiEdit` `edits` payload. `ClaudeLogParser.stringifyInput`
    /// serialises the nested array into a compact JSON string, so we re-parse it
    /// here. Tolerant of malformed entries (skips them) — never throws.
    static func parseMultiEdits(_ raw: String?) -> [(old: String, new: String)]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var out: [(old: String, new: String)] = []
        for entry in arr {
            guard let oldStr = entry["old_string"] as? String,
                  let newStr = entry["new_string"] as? String else { continue }
            out.append((oldStr, newStr))
        }
        return out
    }

    // MARK: - Helpers

    /// Normalises a tool `file_path` into the path component used after the
    /// `a/` / `b/` prefix in a git-diff header. Strips a single leading slash
    /// (so an absolute `/repo/x.swift` doesn't produce a malformed `a//repo/…`)
    /// and substitutes a placeholder when the agent omitted the path.
    static func gitPath(_ path: String) -> String {
        if path.isEmpty { return "file" }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// Splits text into lines for diff rendering. Unlike
    /// `String.components(separatedBy:)` we drop a single trailing newline's
    /// empty fragment (so `"a\n"` is one line `"a"`, matching how a diff shows a
    /// single-line file) but PRESERVE genuine interior/leading blank lines.
    static func splitKeepingTrailingEmpty(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var lines = s.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
