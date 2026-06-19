import XCTest
@testable import ViewerCore

/// Tests for the URL-template expansion engine (TSK-782) — the pure,
/// host-testable core of office/web integrations (Docs, Wiki, Code
/// Review, CodeSearch). These pin substitution, percent-encoding, the
/// scheme-allowlist perimeter, and the injection/edge-case matrix, so
/// any regression of the security boundary fails on the host gate.
final class PluginURLTemplateTests: XCTestCase {

    // MARK: - Happy-path substitution

    func test_substitutes_query_placeholder() {
        let r = PluginURLTemplate.expand(
            template: "https://codesearch.example.com/search?q={query}",
            context: .init(query: "fooBar")
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "https://codesearch.example.com/search?q=fooBar")
    }

    func test_substitutes_multiple_placeholders() {
        let r = PluginURLTemplate.expand(
            template: "https://cr.example.com/c?path={path}&line={line}",
            context: .init(path: "/repo/src/main.swift", line: 42)
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "https://cr.example.com/c?path=%2Frepo%2Fsrc%2Fmain.swift&line=42")
    }

    func test_filename_derived_from_path_when_absent() {
        // A template that wants only the filename works even if the
        // caller supplied only the full path (no redundant filename).
        let r = PluginURLTemplate.expand(
            template: "https://wiki.example.com/page?file={filename}",
            context: .init(path: "/a/b/Design Notes.md")
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "https://wiki.example.com/page?file=Design%20Notes.md")
    }

    func test_explicit_filename_wins_over_path_derivation() {
        let r = PluginURLTemplate.expand(
            template: "https://x.example.com/?f={filename}",
            context: .init(path: "/a/b/c.txt", filename: "override.md")
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "https://x.example.com/?f=override.md")
    }

    func test_template_without_placeholders_passes_through() {
        let r = PluginURLTemplate.expand(
            template: "https://docs.example.com/home",
            context: .init()
        )
        XCTAssertEqual(try r.get().absoluteString, "https://docs.example.com/home")
    }

    // MARK: - Percent-encoding / injection containment

    // A value containing query sub-delimiters must NOT be able to forge
    // extra params or fragments — they're percent-encoded into the slot.
    func test_value_cannot_inject_extra_query_params() throws {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?q={query}",
            context: .init(query: "a&admin=true#frag")
        )
        // `&`, `=`, `#` are all escaped — the whole thing stays one value.
        XCTAssertEqual(try r.get().absoluteString,
                       "https://s.example.com/?q=a%26admin%3Dtrue%23frag")
        // Sanity: the recombined URL has exactly the q param and no host
        // fragment was forged.
        let comps = URLComponents(url: try r.get(), resolvingAgainstBaseURL: false)
        XCTAssertNil(comps?.fragment)
        XCTAssertEqual(comps?.queryItems?.count, 1)
        XCTAssertEqual(comps?.queryItems?.first?.value, "a&admin=true#frag")
    }

    func test_spaces_and_slashes_in_value_are_encoded() {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?p={path}",
            context: .init(path: "/dir with spaces/sub")
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "https://s.example.com/?p=%2Fdir%20with%20spaces%2Fsub")
    }

    func test_plus_in_value_is_encoded_not_treated_as_space() {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?q={query}",
            context: .init(query: "c++")
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "https://s.example.com/?q=c%2B%2B")
    }

    // MARK: - Scheme allowlist (the perimeter)

    func test_rejects_file_scheme() {
        let r = PluginURLTemplate.expand(
            template: "file:///etc/passwd",
            context: .init()
        )
        // No host on a file URL → malformedURL is fine; the point is it
        // never succeeds.
        XCTAssertThrowsExpansion(r)
    }

    func test_rejects_javascript_scheme() {
        let r = PluginURLTemplate.expand(
            template: "javascript://alert.example.com/?x={query}",
            context: .init(query: "1")
        )
        guard case .failure(.disallowedScheme(let s)) = r else {
            return XCTFail("expected disallowedScheme, got \(r)")
        }
        XCTAssertEqual(s, "javascript")
    }

    func test_rejects_data_scheme() {
        let r = PluginURLTemplate.expand(
            template: "data://x.example.com/text/html,hi",
            context: .init()
        )
        guard case .failure(.disallowedScheme) = r else {
            return XCTFail("expected disallowedScheme, got \(r)")
        }
    }

    func test_rejects_custom_app_scheme() {
        let r = PluginURLTemplate.expand(
            template: "markdownviewer://open?path={path}",
            context: .init(path: "/etc/passwd")
        )
        guard case .failure(.disallowedScheme(let s)) = r else {
            return XCTFail("expected disallowedScheme, got \(r)")
        }
        XCTAssertEqual(s, "markdownviewer")
    }

    func test_accepts_http_for_intranet() {
        let r = PluginURLTemplate.expand(
            template: "http://internal.corp/wiki?file={filename}",
            context: .init(filename: "x.md")
        )
        XCTAssertEqual(try r.get().absoluteString,
                       "http://internal.corp/wiki?file=x.md")
    }

    // A substituted value cannot smuggle a different scheme in — even if
    // the value itself looks like a URL, it's encoded into a query slot.
    func test_value_cannot_override_scheme() throws {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?next={query}",
            context: .init(query: "javascript:alert(1)")
        )
        // Colon is encoded into the value; the URL's scheme is still https.
        XCTAssertEqual(try r.get().scheme, "https")
        XCTAssertEqual(URLComponents(url: try r.get(), resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value, "javascript:alert(1)")
    }

    // MARK: - Failure modes

    func test_missing_placeholder_fails() {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?q={query}",
            context: .init()  // no query
        )
        guard case .failure(.missingPlaceholder(let name)) = r else {
            return XCTFail("expected missingPlaceholder, got \(r)")
        }
        XCTAssertEqual(name, "query")
    }

    func test_unknown_placeholder_fails() {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?x={bogus}",
            context: .init()
        )
        guard case .failure(.unknownPlaceholder(let name)) = r else {
            return XCTFail("expected unknownPlaceholder, got \(r)")
        }
        XCTAssertEqual(name, "bogus")
    }

    func test_unbalanced_open_brace_fails() {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?q={query",
            context: .init(query: "x")
        )
        guard case .failure(.unbalancedBraces) = r else {
            return XCTFail("expected unbalancedBraces, got \(r)")
        }
    }

    func test_unbalanced_close_brace_fails() {
        let r = PluginURLTemplate.expand(
            template: "https://s.example.com/?q=x}",
            context: .init()
        )
        guard case .failure(.unbalancedBraces) = r else {
            return XCTFail("expected unbalancedBraces, got \(r)")
        }
    }

    func test_malformed_url_no_host_fails() {
        let r = PluginURLTemplate.expand(
            template: "https:///no-host?q={query}",
            context: .init(query: "x")
        )
        guard case .failure(.malformedURL) = r else {
            return XCTFail("expected malformedURL, got \(r)")
        }
    }

    func test_empty_template_is_malformed() {
        let r = PluginURLTemplate.expand(template: "", context: .init())
        guard case .failure(.malformedURL) = r else {
            return XCTFail("expected malformedURL, got \(r)")
        }
    }

    // MARK: - Helper

    private func XCTAssertThrowsExpansion(
        _ result: Result<URL, PluginURLTemplate.Failure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .success(let url) = result {
            XCTFail("expected failure, got success: \(url)", file: file, line: line)
        }
    }
}
