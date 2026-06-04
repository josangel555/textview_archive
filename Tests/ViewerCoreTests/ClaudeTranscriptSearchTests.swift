import XCTest
@testable import ViewerCore

/// Coverage for `ClaudeTranscriptSearch`. Synthetic transcripts (matching
/// `ClaudeLogParser`'s record shape) under a per-test temp dir — never reads
/// the real `~/.claude`.
final class ClaudeTranscriptSearchTests: XCTestCase {

    private var root: URL!          // stands in for ~/.claude
    private var projectDir: URL!    // <root>/projects/<encoded>
    private let searcher = ClaudeTranscriptSearch()

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSearch-\(UUID().uuidString)", isDirectory: true)
        projectDir = root.appendingPathComponent("projects/-repo", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func writeTranscript(_ stem: String, _ records: [String]) -> URL {
        let url = projectDir.appendingPathComponent("\(stem).jsonl")
        try? (records.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    // Record builders (ClaudeLogParser shape).
    private func userMsg(_ text: String, uuid: String = "u") -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-06-04T07:00:00Z","message":{"role":"user","content":"\#(text)"}}"#
    }
    private func assistantWithTool(text: String, tool: String, path: String) -> String {
        #"{"type":"assistant","uuid":"a","timestamp":"2026-06-04T07:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"},{"type":"tool_use","id":"t1","name":"\#(tool)","input":{"file_path":"\#(path)"}}]}}"#
    }

    // MARK: Single-file search

    func test_substring_matchesUserMessage() throws {
        let url = writeTranscript("s1", [userMsg("please refactor the sidebar widget")])
        let hits = try searcher.search("refactor", in: url)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].role, "user")
        XCTAssertEqual(hits[0].sessionKey, "s1")
        XCTAssertTrue(hits[0].snippet.contains("refactor"))
    }

    func test_caseInsensitive_byDefault() throws {
        let url = writeTranscript("s1", [userMsg("Refactor the Sidebar")])
        XCTAssertEqual(try searcher.search("refactor", in: url).count, 1)
    }

    /// Security barrier: search runs over REDACTED events, so a secret carried
    /// in a redacted key (`headers`/`signature`) of a tool-call input must NOT
    /// be findable or appear in a surfaced snippet — while the tool call itself
    /// stays searchable by its benign fields. Guards against the monitor's
    /// content-search leaking what its transcript-detail view already redacts.
    func test_redactsSecretsBeforeSurfacing() throws {
        let toolWithSecret = #"{"type":"assistant","uuid":"a","timestamp":"2026-06-04T07:01:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{"url":"http://example.com","headers":"SECRETTOKEN123"}}]}}"#
        let url = writeTranscript("s1", [toolWithSecret])

        // The secret is gone — redacted to [REDACTED] before the parser saw it.
        XCTAssertEqual(try searcher.search("SECRETTOKEN123", in: url).count, 0,
                       "a redacted-key secret must never surface in search results")
        // The tool call is still findable by its benign fields.
        let hits = try searcher.search("example.com", in: url)
        XCTAssertEqual(hits.count, 1)
        XCTAssertFalse(hits[0].snippet.contains("SECRETTOKEN123"),
                       "snippet must not contain the redacted secret")
        XCTAssertTrue(hits[0].snippet.contains("[REDACTED]"),
                      "the redacted key should show the token in the snippet")
    }

    func test_caseSensitive_option_respectsCase() throws {
        let url = writeTranscript("s1", [userMsg("Refactor the Sidebar")])
        let opts = ClaudeTranscriptSearch.Options(caseSensitive: true)
        XCTAssertEqual(try searcher.search("refactor", in: url, options: opts).count, 0)
        XCTAssertEqual(try searcher.search("Refactor", in: url, options: opts).count, 1)
    }

    func test_matchesToolUseInputPath() throws {
        let url = writeTranscript("s1", [
            assistantWithTool(text: "editing now", tool: "Edit", path: "/repo/Sidebar.swift"),
        ])
        // The path lives in the tool_use input — search must find it.
        let hits = try searcher.search("Sidebar.swift", in: url)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].role, "tool")
        XCTAssertTrue(hits[0].snippet.contains("Sidebar.swift"))
    }

    func test_regex_matches() throws {
        let url = writeTranscript("s1", [userMsg("refactor or rewrite the parser")])
        let opts = ClaudeTranscriptSearch.Options(regex: true)
        XCTAssertEqual(try searcher.search(#"refactor|rewrite"#, in: url, options: opts).count, 1)
    }

    func test_invalidRegex_throws() {
        let url = writeTranscript("s1", [userMsg("anything")])
        let opts = ClaudeTranscriptSearch.Options(regex: true)
        XCTAssertThrowsError(try searcher.search("(unclosed", in: url, options: opts)) { err in
            XCTAssertEqual(err as? ClaudeTranscriptSearch.SearchError, .invalidRegex)
        }
    }

    func test_redosRegex_rejected_notRun() {
        // Catastrophic-backtracking shapes must be rejected at compile (reusing
        // RegexComplexityGuard) rather than handed to NSRegularExpression.
        let url = writeTranscript("s1", [userMsg(String(repeating: "a", count: 60))])
        let opts = ClaudeTranscriptSearch.Options(regex: true)
        for evil in ["(a+)+$", "(a|a)+$", "(.*)*x"] {
            XCTAssertThrowsError(try searcher.search(evil, in: url, options: opts),
                                 "ReDoS pattern \(evil) must be rejected") { err in
                XCTAssertEqual(err as? ClaudeTranscriptSearch.SearchError, .invalidRegex)
            }
        }
    }

    func test_negativeOptions_clamped_noCrash() throws {
        // A negative cap would trip prefix()'s precondition (fatalError). Options
        // clamps to ≥0, so search degrades to "find nothing" rather than crash.
        let url = writeTranscript("s1", [userMsg("match me")])
        let opts = ClaudeTranscriptSearch.Options(maxMatchesPerFile: -5, maxTotalMatches: -1, snippetContext: -3)
        XCTAssertEqual(try searcher.search("match", in: url, options: opts).count, 0)
        XCTAssertEqual(try searcher.search("match", root: root, options: opts).count, 0)
    }

    func test_emptyQuery_returnsNothing() throws {
        let url = writeTranscript("s1", [userMsg("content here")])
        XCTAssertEqual(try searcher.search("", in: url).count, 0)
    }

    func test_noMatch_returnsEmpty() throws {
        let url = writeTranscript("s1", [userMsg("hello world")])
        XCTAssertEqual(try searcher.search("zzzznotpresent", in: url).count, 0)
    }

    // MARK: Snippet shape

    func test_snippet_isSingleLine_andBounded() throws {
        // `\\n` here is an ESCAPED newline in the JSON string value (valid
        // JSONL), which the parser decodes to a real newline adjacent to the
        // match — so the snippet's newline-collapse is genuinely exercised.
        let long = String(repeating: "x", count: 200) + #"\nNEEDLE\n"# + String(repeating: "y", count: 200)
        let url = writeTranscript("s1", [userMsg(long)])
        let opts = ClaudeTranscriptSearch.Options(snippetContext: 20)
        let hits = try searcher.search("NEEDLE", in: url, options: opts)
        XCTAssertEqual(hits.count, 1)
        let snip = hits[0].snippet
        XCTAssertFalse(snip.contains("\n"), "snippet must be single-line (newlines collapsed)")
        XCTAssertTrue(snip.contains("NEEDLE"))
        XCTAssertTrue(snip.hasPrefix("…") && snip.hasSuffix("…"), "bounded both sides → ellipses")
        XCTAssertLessThan(snip.count, 60, "≈ NEEDLE + 2×20 context + ellipses")
    }

    // MARK: Caps

    func test_maxMatchesPerFile_caps() throws {
        let recs = (0..<10).map { userMsg("match number \($0)", uuid: "u\($0)") }
        let url = writeTranscript("s1", recs)
        let opts = ClaudeTranscriptSearch.Options(maxMatchesPerFile: 3)
        XCTAssertEqual(try searcher.search("match", in: url, options: opts).count, 3)
    }

    // MARK: Whole-root search

    func test_search_acrossRoot_findsAllTranscripts() throws {
        writeTranscript("sessA", [userMsg("the quick brown fox")])
        writeTranscript("sessB", [userMsg("the lazy brown dog")])
        let hits = try searcher.search("brown", root: root)
        XCTAssertEqual(Set(hits.map { $0.sessionKey }), ["sessA", "sessB"])
        XCTAssertEqual(hits.count, 2)
    }

    func test_search_acrossRoot_capsTotal() throws {
        for s in 0..<5 {
            writeTranscript("sess\(s)", (0..<10).map { userMsg("hit \($0)", uuid: "u\(s)-\($0)") })
        }
        let opts = ClaudeTranscriptSearch.Options(maxTotalMatches: 12)
        XCTAssertEqual(try searcher.search("hit", root: root, options: opts).count, 12)
    }

    func test_search_emptyRoot_returnsEmpty() throws {
        // projects dir exists but has no transcripts.
        XCTAssertEqual(try searcher.search("anything", root: root).count, 0)
    }
}
