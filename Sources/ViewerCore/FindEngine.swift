import Foundation

public struct FindQuery: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case literal
        case regex
    }

    public let pattern: String
    public let kind: Kind
    public let caseSensitive: Bool
    public let wholeWord: Bool

    public init(
        pattern: String,
        kind: Kind = .literal,
        caseSensitive: Bool = false,
        wholeWord: Bool = false
    ) {
        self.pattern = pattern
        self.kind = kind
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    public var isEmpty: Bool { pattern.isEmpty }
}

public struct FindMatch: Equatable, Sendable {
    public let range: NSRange
    public let line: Int      // 1-based
    public let column: Int    // 1-based, UTF-16 columns

    public init(range: NSRange, line: Int, column: Int) {
        self.range = range
        self.line = line
        self.column = column
    }
}

public enum FindError: Error, Equatable {
    case invalidRegex(String)
    /// Pattern rejected at compile time by `RegexComplexityGuard` —
    /// nested quantifiers, exponential alternation, or other
    /// `NSRegularExpression` ReDoS-class shapes. The string is the
    /// human-facing reason; UI surfaces it as a find-bar status.
    case unsafeRegex(String)
}

/// Pure search engine. No UI imports.
public struct FindEngine: Sendable {
    public init() {}

    public func search(
        in text: String,
        query: FindQuery
    ) throws -> [FindMatch] {
        try searchBounded(in: text, query: query).matches
    }

    /// Same as `search`, but also reports whether match-time enumeration
    /// was cut short by the `RegexComplexityGuard.boundedMatches`
    /// (SEC-006) wall-clock deadline. A regex passing the compile-time
    /// `reject` guard can still backtrack polynomially (the guard models
    /// only *exponential* shapes — see its docstring), so the
    /// highest-risk channel, the MCP `find` tool with `regex:true`
    /// against a multi-MB document, must be wall-clock-bounded too.
    /// `timedOut == true` means the returned matches are a *prefix* of
    /// the full set: callers (e.g. the MCP find result) should surface
    /// that distinctly from a genuine end-of-matches so a consumer
    /// doesn't treat a truncated result as exhaustive.
    public func searchBounded(
        in text: String,
        query: FindQuery,
        deadline: TimeInterval = RegexComplexityGuard.defaultMatchDeadline
    ) throws -> (matches: [FindMatch], timedOut: Bool) {
        guard !query.isEmpty else { return ([], false) }

        let regex = try makeRegex(for: query)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // SEC-006: route enumeration through the shared wall-clock-bounded
        // matcher instead of calling `enumerateMatches` directly. The
        // compile-time `reject` guard in `makeRegex` only catches the
        // exponential ReDoS shapes; polynomial backtracking slips past it
        // and would otherwise peg a core on the MCP `find` path. The
        // closure caps inter-match time and stops once the budget is spent.
        let (results, timedOut) = RegexComplexityGuard.boundedMatches(
            regex, in: text, range: fullRange, deadline: deadline
        )

        // P11: compute line/col in a single sweep across matches instead of
        // walking from 0 to each match's location independently. That was
        // O(M·N) for M matches in an N-char text (catastrophic for a regex
        // with thousands of hits in a megabyte log). Now O(N): we advance a
        // cursor monotonically alongside the (already-sorted) match list.
        var matches: [FindMatch] = results.map { r in
            FindMatch(range: r.range, line: 0, column: 0)  // line/col filled below
        }
        guard !matches.isEmpty else { return (matches, timedOut) }

        // Line/column accounting handles LF, CR, and CRLF consistently
        // (S2-E). Previously only `\n` advanced the line counter, so:
        //   * Classic-Mac / CR-only files reported every match as line 1.
        //   * CRLF files had columns off by one (the `\r` was counted
        //     into `column = target - lineStart + 1`).
        // Now: bare `\r` advances line. `\r\n` advances once. `lineStart`
        // is set to the offset AFTER the terminator(s), so columns
        // count from the first character of the new line.
        var line = 1
        var lineStart = 0
        var cursor = 0
        for i in 0..<matches.count {
            let target = matches[i].range.location
            while cursor < target && cursor < nsText.length {
                let ch = nsText.character(at: cursor)
                if ch == 0x0D {  // CR
                    line += 1
                    if cursor + 1 < nsText.length
                       && nsText.character(at: cursor + 1) == 0x0A {
                        cursor += 2  // CRLF
                    } else {
                        cursor += 1
                    }
                    lineStart = cursor
                } else if ch == 0x0A {  // bare LF
                    line += 1
                    cursor += 1
                    lineStart = cursor
                } else {
                    cursor += 1
                }
            }
            // CORR-6: clamp to a 1-based minimum. When a match starts
            // exactly on the LF of a `\r\n` pair, the CRLF-skip above
            // advances `cursor`/`lineStart` to AFTER the LF — past
            // `target` — so the raw `target - lineStart + 1` underflows
            // to 0 (or negative). Columns are documented 1-based, so a
            // match sitting on the line terminator reports column 1 of
            // the line it terminates rather than a nonsensical 0.
            matches[i] = FindMatch(
                range: matches[i].range,
                line: line,
                column: max(1, target - lineStart + 1)
            )
        }
        return (matches, timedOut)
    }

    /// Indexes `matches` so that the next match at-or-after `cursor` is returned
    /// alongside its index. Wraps around to the first match if needed.
    public static func nextMatch(
        in matches: [FindMatch],
        after cursor: Int
    ) -> (FindMatch, Int)? {
        guard !matches.isEmpty else { return nil }
        if let i = matches.firstIndex(where: { $0.range.location >= cursor }) {
            return (matches[i], i)
        }
        return (matches[0], 0)  // wrap
    }

    // MARK: - Private

    /// Single-slot cache. `findAll`/`findNext` against the same query
    /// (which is the common case while iterating matches) previously
    /// recompiled `NSRegularExpression` per call. Matches the shape
    /// of `TextDisplayView.cachedRegex` — find queries are sticky,
    /// one slot is enough.
    private static let regexCacheLock = NSLock()
    nonisolated(unsafe) private static var lastRegexKey: String?
    nonisolated(unsafe) private static var lastRegex: NSRegularExpression?

    private func makeRegex(for query: FindQuery) throws -> NSRegularExpression {
        var pattern: String
        switch query.kind {
        case .literal:
            pattern = NSRegularExpression.escapedPattern(for: query.pattern)
        case .regex:
            // S6.1 — ReDoS guard. Only applied to user-typed regex
            // patterns; the literal branch escapes everything so it's
            // ReDoS-immune by construction.
            if let reason = RegexComplexityGuard.reject(query.pattern) {
                throw FindError.unsafeRegex(reason)
            }
            pattern = query.pattern
        }
        if query.wholeWord {
            pattern = "\\b" + pattern + "\\b"
        }
        var options: NSRegularExpression.Options = []
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        let key = "\(query.caseSensitive ? "S" : "i")\(query.wholeWord ? "W" : "")\(query.kind == .regex ? "R" : "L"):\(pattern)"
        Self.regexCacheLock.lock()
        if Self.lastRegexKey == key, let re = Self.lastRegex {
            Self.regexCacheLock.unlock()
            return re
        }
        Self.regexCacheLock.unlock()
        do {
            let re = try NSRegularExpression(pattern: pattern, options: options)
            Self.regexCacheLock.lock()
            Self.lastRegexKey = key
            Self.lastRegex = re
            Self.regexCacheLock.unlock()
            return re
        } catch {
            throw FindError.invalidRegex(query.pattern)
        }
    }

}
