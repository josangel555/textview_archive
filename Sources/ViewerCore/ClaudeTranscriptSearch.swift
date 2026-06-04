import Foundation

// Transcript search for the agent-monitor (owner ask: "search transcripts").
//
// Composes the two existing pieces — `ClaudeSessionIndex.transcriptURLs(root:)`
// to enumerate `~/.claude/projects/*/*.jsonl`, and `ClaudeLogParser` to turn
// each transcript into typed `ClaudeEvent`s — and matches a query against the
// searchable text of every event (user/assistant/thinking message, tool name +
// inputs, tool-result summary). Returns bounded, single-line snippets so a hit
// inside a huge blob never dumps the blob.
//
// Foundation-only, read-only, and bounded at every level (per-file + total
// match caps, plus the parser's own line/event caps) so a 100 MB transcript or
// a pathological query can't blow up memory or wall-clock.

public struct ClaudeTranscriptSearch: Sendable {

    public struct Options: Sendable {
        /// Case-sensitive matching (default: insensitive).
        public var caseSensitive: Bool
        /// Treat the query as an ICU regular expression (default: substring).
        public var regex: Bool
        /// Cap on matches retained per transcript file.
        public var maxMatchesPerFile: Int
        /// Cap on matches retained across a whole-root search.
        public var maxTotalMatches: Int
        /// Characters of context kept on each side of the match in the snippet.
        public var snippetContext: Int

        public init(caseSensitive: Bool = false,
                    regex: Bool = false,
                    maxMatchesPerFile: Int = 200,
                    maxTotalMatches: Int = 2000,
                    snippetContext: Int = 48) {
            self.caseSensitive = caseSensitive
            self.regex = regex
            // Clamp non-negative — a negative cap would trip `prefix()`'s
            // precondition (fatalError) downstream. 0 is a valid "find nothing".
            self.maxMatchesPerFile = max(0, maxMatchesPerFile)
            self.maxTotalMatches = max(0, maxTotalMatches)
            self.snippetContext = max(0, snippetContext)
        }
    }

    public struct Match: Equatable, Sendable, Identifiable {
        /// Filename stem of the transcript (the canonical session key).
        public let sessionKey: String
        public let path: String
        /// Index of the matching event within the parsed transcript.
        public let eventIndex: Int
        /// Coarse record role: `user` / `assistant` / `thinking` / `tool` /
        /// `tool_result`.
        public let role: String
        /// Single-line, bounded snippet with the match in context.
        public let snippet: String
        public let timestamp: Date?

        public var id: String { "\(path)#\(eventIndex)" }

        public init(sessionKey: String, path: String, eventIndex: Int,
                    role: String, snippet: String, timestamp: Date?) {
            self.sessionKey = sessionKey
            self.path = path
            self.eventIndex = eventIndex
            self.role = role
            self.snippet = snippet
            self.timestamp = timestamp
        }
    }

    public enum SearchError: Error, Equatable { case invalidRegex }

    private let parser: ClaudeLogParser
    private let index: ClaudeSessionIndex

    public init(maxLineBytes: Int = 4 * 1024 * 1024, maxEvents: Int = 200_000) {
        self.parser = ClaudeLogParser(maxLineBytes: maxLineBytes, maxEvents: maxEvents)
        self.index = ClaudeSessionIndex(maxLineBytes: maxLineBytes)
    }

    // MARK: Public search

    /// Search a single transcript file. Throws `SearchError.invalidRegex` if
    /// `options.regex` is set and `query` doesn't compile. An empty query
    /// matches nothing (returns `[]`).
    public func search(_ query: String, in url: URL, options: Options = .init()) throws -> [Match] {
        guard !query.isEmpty else { return [] }
        let matcher = try Matcher(query: query, options: options)
        return matches(query, in: url, matcher: matcher, options: options)
    }

    /// Search every top-level transcript under `root` (e.g. `~/.claude`).
    /// Validates the regex once up front. Stops at `options.maxTotalMatches`.
    public func search(_ query: String, root: URL, options: Options = .init()) throws -> [Match] {
        guard !query.isEmpty, options.maxTotalMatches > 0 else { return [] }
        let matcher = try Matcher(query: query, options: options)
        var out: [Match] = []
        for url in index.transcriptURLs(root: root) {
            // Append eagerly with an in-loop cap so we never hold more than
            // `maxTotalMatches` Match structs at once (no per-file overshoot
            // before trimming), and never call prefix() with a stale total.
            for m in matches(query, in: url, matcher: matcher, options: options) {
                out.append(m)
                if out.count >= options.maxTotalMatches { return out }
            }
        }
        return out
    }

    // MARK: Internals

    private func matches(_ query: String, in url: URL,
                         matcher: Matcher, options: Options) -> [Match] {
        // REDACTED events only — a surfaced snippet must never carry a
        // `signature`/`headers` value or a raw inline image blob (the same
        // barrier the monitor's transcript detail applies). See
        // `ClaudeLogParser.parseRedacted`.
        let events = (try? parser.redactedEvents(from: url)) ?? []
        let key = url.deletingPathExtension().lastPathComponent
        var out: [Match] = []
        for (i, event) in events.enumerated() {
            // Check the cap BEFORE matching/appending so a cap of 0 yields 0
            // (an append-then-check would always emit the first match).
            if out.count >= options.maxMatchesPerFile { break }
            let (text, role) = Self.searchable(event)
            guard !text.isEmpty, let range = matcher.firstMatch(in: text) else { continue }
            out.append(Match(
                sessionKey: key, path: url.path, eventIndex: i, role: role,
                snippet: Self.snippet(text, around: range, context: options.snippetContext),
                timestamp: event.timestamp))
        }
        return out
    }

    /// The searchable text + coarse role for an event.
    static func searchable(_ event: ClaudeEvent) -> (text: String, role: String) {
        switch event.kind {
        case .userMessage(let t):      return (t, "user")
        case .assistantMessage(let t): return (t, "assistant")
        case .thinking(let t):         return (t, "thinking")
        case .toolUse(_, let name, let input):
            // name + the input values (file paths, commands, args) so a search
            // for a path or a command finds the tool call that used it.
            let vals = input.values.joined(separator: " ")
            return (vals.isEmpty ? name : "\(name) \(vals)", "tool")
        case .toolResult(_, let summary): return (summary, "tool_result")
        }
    }

    /// A single-line snippet around `range` in `text`, with `context` chars on
    /// each side and ellipses where truncated. Newlines/tabs collapse to spaces
    /// so the result stays one line for a results list.
    static func snippet(_ text: String, around range: Range<String.Index>, context: Int) -> String {
        let lower = text.index(range.lowerBound,
                               offsetBy: -context,
                               limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound,
                               offsetBy: context,
                               limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lower..<upper])
        s = s.replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\t", with: " ")
        let prefix = lower > text.startIndex ? "…" : ""
        let suffix = upper < text.endIndex ? "…" : ""
        return prefix + s + suffix
    }

    /// Compiled query — substring or regex — built once per search call.
    struct Matcher {
        private let query: String
        private let caseSensitive: Bool
        private let regex: NSRegularExpression?

        init(query: String, options: Options) throws {
            self.query = query
            self.caseSensitive = options.caseSensitive
            if options.regex {
                // Reject known-ReDoS shapes (nested quantifiers, overlapping
                // alternation under a quantifier) BEFORE NSRegularExpression
                // sees them — reusing the same guard FindEngine/CrossFileSearch
                // use. Per-event text is already bounded (one message), which
                // covers the polynomial case `reject` deliberately doesn't model.
                if RegexComplexityGuard.reject(query) != nil {
                    throw SearchError.invalidRegex
                }
                var opts: NSRegularExpression.Options = []
                if !options.caseSensitive { opts.insert(.caseInsensitive) }
                guard let re = try? NSRegularExpression(pattern: query, options: opts) else {
                    throw SearchError.invalidRegex
                }
                self.regex = re
            } else {
                self.regex = nil
            }
        }

        func firstMatch(in text: String) -> Range<String.Index>? {
            if let regex {
                let ns = text as NSString
                guard let m = regex.firstMatch(in: text, options: [],
                                               range: NSRange(location: 0, length: ns.length)),
                      m.range.location != NSNotFound else { return nil }
                return Range(m.range, in: text)
            }
            return text.range(of: query,
                              options: caseSensitive ? [] : .caseInsensitive)
        }
    }
}
