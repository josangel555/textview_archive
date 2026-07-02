import Foundation

/// One inline Markdown link or image. `target` is the URL/path inside `(...)`
/// (title + surrounding whitespace stripped); `line` is 1-based.
public struct MarkdownLink: Equatable, Sendable {
    public let target: String
    public let line: Int
    public let isImage: Bool
    /// The `[...]` label (link text / image alt). Defaulted so existing call
    /// sites that don't need it stay source-compatible.
    public let text: String
    public init(target: String, line: Int, isImage: Bool, text: String = "") {
        self.target = target
        self.line = line
        self.isImage = isImage
        self.text = text
    }
}

public enum MarkdownLinkKind: Equatable, Sendable {
    case external   // has a URL scheme (http:, mailto:, …) or is protocol-relative (//)
    case anchor     // in-page fragment (#section)
    case relative   // a local file path
}

/// Extracts inline Markdown links `[text](target)` and images `![alt](target)`
/// and finds broken LOCAL ones (TSK — "Check Links", a docs-maintenance feature).
/// A focused parser like `MarkdownOutline` (not the Rust-ported markdown→HTML
/// engine), so it's migration-safe. Pure; the filesystem existence check is
/// INJECTED, so the whole thing is host-testable.
///
/// v1 scope: inline links + images, fenced code (``` / ~~~) skipped, nested
/// brackets/parens + backslash escapes handled, optional `"title"` dropped.
/// NOT handled (documented): reference-style links, links inside inline-code
/// spans, indented code blocks.
public enum MarkdownLinks {

    public static func extract(_ text: String) -> [MarkdownLink] {
        var out: [MarkdownLink] = []
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0

        var lineNo = 0
        for rawLine in splitLinesPreservingCount(text) {
            lineNo += 1
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }

            if let (marker, count) = fenceRun(trimmed) {
                if inFence { if marker == fenceChar, count >= fenceLen { inFence = false } }
                else { inFence = true; fenceChar = marker; fenceLen = count }
                continue
            }
            if inFence { continue }

            out.append(contentsOf: linksInLine(line, lineNo: lineNo))
        }
        return out
    }

    /// Classify a link target.
    public static func kind(of target: String) -> MarkdownLinkKind {
        if target.hasPrefix("#") { return .anchor }
        if target.hasPrefix("//") { return .external }
        if let colon = target.firstIndex(of: ":") {
            let scheme = target[target.startIndex..<colon]
            if !scheme.isEmpty,
               scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
               !scheme.contains("/") {
                return .external   // http:, https:, mailto:, ftp:, …
            }
        }
        return .relative
    }

    /// The relative links/images whose resolved local path does NOT satisfy
    /// `exists`. External links and pure in-page anchors are skipped. `exists`
    /// receives the path with any trailing `#fragment` stripped (callers resolve
    /// it against the document's directory + check the filesystem).
    public static func brokenLocalLinks(in text: String, exists: (String) -> Bool) -> [MarkdownLink] {
        extract(text).filter { link in
            guard kind(of: link.target) == .relative else { return false }
            let path = String(link.target.prefix { $0 != "#" })
            guard !path.isEmpty else { return false }   // e.g. "(#)" — in-page only
            return !exists(path)
        }
    }

    // MARK: - helpers

    private static func splitLinesPreservingCount(_ text: String) -> [String] {
        var lines: [String] = []
        var cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == "\n" { lines.append(String(cur)); cur = String.UnicodeScalarView() }
            else { cur.append(u) }
        }
        lines.append(String(cur))
        return lines
    }

    private static func fenceRun(_ trimmed: Substring) -> (Character, Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count)
    }

    private static func linksInLine(_ line: String, lineNo: Int) -> [MarkdownLink] {
        var out: [MarkdownLink] = []
        let chars = Array(line)
        let n = chars.count
        var i = 0
        while i < n {
            // Skip inline code spans: a run of N backticks is closed by a run of
            // exactly N backticks; `[text](url)` inside one is code, not a link.
            if chars[i] == "`" {
                var run = 0
                while i + run < n, chars[i + run] == "`" { run += 1 }
                var k = i + run
                while k < n {
                    if chars[k] == "`" {
                        var r2 = 0
                        while k + r2 < n, chars[k + r2] == "`" { r2 += 1 }
                        if r2 == run { i = k + r2; break }   // matched close → skip span
                        k += r2
                    } else { k += 1 }
                }
                if k >= n { i += run }   // no matching close → backticks are literal
                continue
            }
            guard chars[i] == "[" else { i += 1; continue }
            let isImage = i > 0 && chars[i - 1] == "!"

            // closing ] for the link text (bracket-depth aware, escapes skipped)
            var j = i + 1
            var depth = 1
            while j < n {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "[" { depth += 1 }
                else if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j < n, depth == 0, j + 1 < n, chars[j + 1] == "(" else { i += 1; continue }

            // target up to the matching ) (paren-depth aware, escapes unescaped)
            var k = j + 2
            var pdepth = 1
            var target = ""
            while k < n {
                let c = chars[k]
                if c == "\\", k + 1 < n { target.append(chars[k + 1]); k += 2; continue }
                if c == "(" { pdepth += 1; target.append(c) }
                else if c == ")" { pdepth -= 1; if pdepth == 0 { break }; target.append(c) }
                else { target.append(c) }
                k += 1
            }
            guard k < n, pdepth == 0 else { i += 1; continue }

            let cleaned = dropTitle(target.trimmingCharacters(in: .whitespaces))
            if !cleaned.isEmpty {
                let label = String(chars[(i + 1)..<j])   // the [...] text / image alt
                out.append(MarkdownLink(target: cleaned, line: lineNo, isImage: isImage, text: label))
            }
            i = k + 1
        }
        return out
    }

    /// `url` or `url "title"` → `url` (a Markdown URL has no raw space; a space
    /// begins the optional title).
    private static func dropTitle(_ s: String) -> String {
        if let sp = s.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return String(s[s.startIndex..<sp])
        }
        return s
    }
}
