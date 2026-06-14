import Foundation

/// Parsed form of a snippet body (TSK-705, slice 1). A snippet body uses the
/// familiar TextMate / LSP placeholder syntax:
///
///   - `$1`, `$2`, … — ordered tab stops (empty placeholders).
///   - `${1:default}` — a tab stop pre-filled with `default` text.
///   - `$0` / `${0:…}` — the FINAL cursor position (visited last).
///   - `\$`, `\\`, `\}` — escaped literals.
///
/// This is the pure, host-testable FOUNDATION of the snippets feature. The
/// store of snippets, the insert command, the tab-stop cursor navigation, and
/// the management UI are later slices (the navigation + UI are the editor/VM
/// render tail).
public struct ParsedSnippet: Equatable, Sendable {

    public enum Segment: Equatable, Sendable {
        case literal(String)
        /// A tab stop. `index` 0 is the final cursor position.
        case placeholder(index: Int, defaultText: String)
    }

    public let segments: [Segment]
    public init(segments: [Segment]) { self.segments = segments }

    /// The text actually inserted into the buffer: literals plus each
    /// placeholder's default (empty for a bare `$N`).
    public var plainText: String {
        var out = ""
        for seg in segments {
            switch seg {
            case .literal(let s): out += s
            case .placeholder(_, let d): out += d
            }
        }
        return out
    }

    /// Distinct tab-stop indices in the order the editor should visit them:
    /// ascending by number, with the final stop `0` always LAST (even if it
    /// appears earlier in the body). A snippet with no stops → empty.
    public var tabStopOrder: [Int] {
        var seen = Set<Int>()
        for case .placeholder(let i, _) in segments { seen.insert(i) }
        let positives = seen.filter { $0 != 0 }.sorted()
        return seen.contains(0) ? positives + [0] : positives
    }

    /// Each placeholder occurrence as (tab-stop index, UTF-16 offset into
    /// `plainText`, length of its default). The editor uses these to place the
    /// caret / select the default for each tab stop. UTF-16 because that's the
    /// coordinate space CM6 / NSTextView address with.
    public func stops() -> [(index: Int, offset: Int, length: Int)] {
        var out: [(index: Int, offset: Int, length: Int)] = []
        var offset = 0
        for seg in segments {
            switch seg {
            case .literal(let s): offset += s.utf16.count
            case .placeholder(let i, let d):
                out.append((index: i, offset: offset, length: d.utf16.count))
                offset += d.utf16.count
            }
        }
        return out
    }
}

public enum SnippetExpansion {

    /// Parse a snippet `body` into literals + tab stops. Unrecognized `$`
    /// sequences are kept literal (a lone `$` or `$foo` is just text), so the
    /// parser never loses input — `plainText` of the result always reconstructs
    /// the body minus the placeholder markup.
    public static func parse(_ body: String) -> ParsedSnippet {
        var segments: [ParsedSnippet.Segment] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
        }
        let c = Array(body)
        var i = 0
        while i < c.count {
            // Escapes: \$ \\ \}  → the literal char.
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "$" || c[i + 1] == "\\" || c[i + 1] == "}" {
                literal.append(c[i + 1]); i += 2; continue
            }
            if c[i] == "$", i + 1 < c.count {
                // $N
                if c[i + 1].isNumber {
                    var j = i + 1, num = ""
                    while j < c.count, c[j].isNumber { num.append(c[j]); j += 1 }
                    if let n = Int(num) {
                        flush(); segments.append(.placeholder(index: n, defaultText: ""))
                        i = j; continue
                    }
                }
                // ${N} or ${N:default}
                if c[i + 1] == "{" {
                    var j = i + 2, num = ""
                    while j < c.count, c[j].isNumber { num.append(c[j]); j += 1 }
                    if let n = Int(num), j < c.count {
                        if c[j] == "}" {
                            flush(); segments.append(.placeholder(index: n, defaultText: ""))
                            i = j + 1; continue
                        }
                        if c[j] == ":" {
                            j += 1
                            var def = ""
                            while j < c.count, c[j] != "}" {
                                if c[j] == "\\", j + 1 < c.count, c[j + 1] == "}" {
                                    def.append("}"); j += 2; continue
                                }
                                def.append(c[j]); j += 1
                            }
                            if j < c.count, c[j] == "}" {
                                flush(); segments.append(.placeholder(index: n, defaultText: def))
                                i = j + 1; continue
                            }
                            // Unterminated ${N:… → fall through to literal.
                        }
                    }
                }
            }
            literal.append(c[i]); i += 1
        }
        flush()
        return ParsedSnippet(segments: segments)
    }
}
