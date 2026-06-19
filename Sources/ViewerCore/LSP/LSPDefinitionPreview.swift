import Foundation

/// Pure-model layer for the **Preview Definition** command (Quick
/// Definition / Cmd+Y, TSK-708).
///
/// "Preview Definition" issues a `textDocument/definition` request for
/// the symbol under the caret and shows the *target's* source — a few
/// lines of context around the definition line — in a transient popover
/// WITHOUT navigating away (mirror of how hover renders its tooltip,
/// TSK-710). The popover render + the real keystroke are the VM tail;
/// this type is the host-testable core:
///
///   1. `snippet(fromContents:target:contextLines:)` — given the target
///      file's full contents and the definition `LSPLocation`, returns
///      the N-line context window (clamped at file start/end) plus which
///      window-relative line is the definition's target line. This is
///      the thing the popover renders.
///   2. `availability(...)` — whether the command is enabled, given
///      whether an LSP server is attached for the active document and
///      whether the active doc supports definition requests. The menu
///      item / command-palette row gates on this; a disabled state never
///      issues a request.
///
/// All offsets in `Window` are 0-indexed (matching LSP); the UI adds 1
/// for display. Line splitting tolerates `\n`, `\r\n`, and a trailing
/// newline (which does NOT create a spurious final empty line).
public enum LSPDefinitionPreview {

    // MARK: - Snippet window

    /// A clamped slice of a file, ready to render in the preview popover.
    public struct Window: Equatable, Sendable {
        /// The snippet lines, in document order (no trailing newline per line).
        public let lines: [String]
        /// 0-indexed document line of `lines[0]` (the first rendered line).
        public let startLine: Int
        /// 0-indexed document line of `lines.last` (the last rendered line).
        public let endLine: Int
        /// Index INTO `lines` of the definition's target line — the line to
        /// visually highlight. Always within `0..<lines.count`. Equal to
        /// `targetDocumentLine - startLine`.
        public let highlightIndex: Int
        /// 0-indexed document line of the definition target (the line the
        /// LSP `range.start` points at), clamped into the file's bounds.
        public let targetDocumentLine: Int

        public init(
            lines: [String], startLine: Int, endLine: Int,
            highlightIndex: Int, targetDocumentLine: Int
        ) {
            self.lines = lines
            self.startLine = startLine
            self.endLine = endLine
            self.highlightIndex = highlightIndex
            self.targetDocumentLine = targetDocumentLine
        }

        /// Convenience: the highlighted source line itself.
        public var highlightedLine: String { lines[highlightIndex] }
    }

    /// Build the preview window for a definition `target` against the
    /// target file's `contents`.
    ///
    /// - Parameters:
    ///   - contents: the FULL text of the file the definition lives in.
    ///   - target: the LSP location returned by `textDocument/definition`
    ///     (only `range.start.line` matters for windowing).
    ///   - contextLines: how many lines of context to show ABOVE and
    ///     BELOW the target line. `2` ⇒ up to 5 lines total (2 + target +
    ///     2). Negative values are treated as `0`.
    /// - Returns: a clamped `Window`, or `nil` if the file is empty.
    public static func snippet(
        fromContents contents: String,
        target: LSPLocation,
        contextLines: Int
    ) -> Window? {
        snippet(
            fromContents: contents,
            targetLine: target.range.start.line,
            contextLines: contextLines)
    }

    /// Lower-level entry: window around an explicit 0-indexed
    /// `targetLine`. Used directly by tests; the `LSPLocation` overload
    /// delegates here.
    public static func snippet(
        fromContents contents: String,
        targetLine: Int,
        contextLines: Int
    ) -> Window? {
        let allLines = splitLines(contents)
        guard !allLines.isEmpty else { return nil }

        let maxLine = allLines.count - 1
        // Clamp the target line into the file's real bounds. A server can
        // return a line past EOF after an edit race; we degrade to the
        // last line rather than crash.
        let target = min(max(targetLine, 0), maxLine)
        let context = max(contextLines, 0)

        let start = max(target - context, 0)
        let end = min(target + context, maxLine)

        let slice = Array(allLines[start...end])
        return Window(
            lines: slice,
            startLine: start,
            endLine: end,
            highlightIndex: target - start,
            targetDocumentLine: target)
    }

    /// Split into lines tolerating `\n`, `\r\n`, and a lone trailing
    /// newline. `"a\nb\n"` ⇒ `["a", "b"]` (NOT `["a","b",""]`); `""` ⇒
    /// `[]`. We do this by hand rather than `components(separatedBy:)`
    /// so a `\r\n` document doesn't leave `\r` tails on every line.
    static func splitLines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var out: [String] = []
        out.reserveCapacity(64)
        var current = String.UnicodeScalarView()
        var iter = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while true {
            let scalar: Unicode.Scalar?
            if let p = pending { scalar = p; pending = nil }
            else { scalar = iter.next() }
            guard let c = scalar else { break }
            if c == "\n" {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else if c == "\r" {
                // Peek for the LF half of a CRLF.
                let next = iter.next()
                out.append(String(current))
                current = String.UnicodeScalarView()
                if let n = next, n != "\n" {
                    // Bare CR line break — re-feed the consumed scalar.
                    pending = n
                }
            } else {
                current.append(c)
            }
        }
        // Trailing partial line: only emit if non-empty (so a trailing
        // newline doesn't produce a phantom blank last line).
        if !current.isEmpty {
            out.append(String(current))
        }
        return out
    }

    // MARK: - Command availability (gating)

    /// Why the Preview Definition command is in its current enabled /
    /// disabled state — surfaced so the menu can show a precise reason
    /// (and so tests pin the exact gate that fired).
    public enum AvailabilityReason: Equatable, Sendable {
        /// Enabled: an LSP server is attached and supports definition.
        case available
        /// No document / editor is active.
        case noActiveDocument
        /// The active document has no LSP server attached (unsupported
        /// language, server crashed, or LSP disabled).
        case noLanguageServer
        /// A server is attached but did not advertise definition support
        /// in its `ServerCapabilities`.
        case definitionUnsupported
    }

    /// Resolved gate state for the command. `isEnabled` drives the
    /// menu-item / palette-row enablement; `reason` is the human-facing
    /// explanation.
    public struct Availability: Equatable, Sendable {
        public let isEnabled: Bool
        public let reason: AvailabilityReason
        public init(isEnabled: Bool, reason: AvailabilityReason) {
            self.isEnabled = isEnabled
            self.reason = reason
        }
    }

    /// Compute whether the Preview Definition command should be enabled.
    ///
    /// - Parameters:
    ///   - hasActiveDocument: is there a focused editor at all?
    ///   - hasLanguageServer: is an LSP client attached for the active doc?
    ///   - definitionProviderAdvertised: did that server advertise
    ///     `definitionProvider` in its capabilities? Pass `true` when the
    ///     capability is unknown-but-assumed (most servers support it);
    ///     pass `false` only when the server explicitly omitted it.
    /// - Returns: the gate state — disabled when any precondition fails.
    public static func availability(
        hasActiveDocument: Bool,
        hasLanguageServer: Bool,
        definitionProviderAdvertised: Bool
    ) -> Availability {
        guard hasActiveDocument else {
            return Availability(isEnabled: false, reason: .noActiveDocument)
        }
        guard hasLanguageServer else {
            return Availability(isEnabled: false, reason: .noLanguageServer)
        }
        guard definitionProviderAdvertised else {
            return Availability(
                isEnabled: false, reason: .definitionUnsupported)
        }
        return Availability(isEnabled: true, reason: .available)
    }
}
