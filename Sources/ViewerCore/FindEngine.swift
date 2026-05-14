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
}

/// Pure search engine. No UI imports.
public struct FindEngine: Sendable {
    public init() {}

    public func search(
        in text: String,
        query: FindQuery
    ) throws -> [FindMatch] {
        guard !query.isEmpty else { return [] }

        let regex = try makeRegex(for: query)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var matches: [FindMatch] = []
        regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let r = result, r.range.location != NSNotFound else { return }
            let (line, column) = Self.lineColumn(in: nsText, location: r.range.location)
            matches.append(FindMatch(range: r.range, line: line, column: column))
        }
        return matches
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

    private func makeRegex(for query: FindQuery) throws -> NSRegularExpression {
        var pattern: String
        switch query.kind {
        case .literal:
            pattern = NSRegularExpression.escapedPattern(for: query.pattern)
        case .regex:
            pattern = query.pattern
        }
        if query.wholeWord {
            pattern = "\\b" + pattern + "\\b"
        }
        var options: NSRegularExpression.Options = []
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FindError.invalidRegex(query.pattern)
        }
    }

    private static func lineColumn(in nsText: NSString, location: Int) -> (Int, Int) {
        var line = 1
        var lineStart = 0
        var i = 0
        let end = min(location, nsText.length)
        while i < end {
            let ch = nsText.character(at: i)
            if ch == 0x0A { // \n
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        let column = location - lineStart + 1
        return (line, column)
    }
}
