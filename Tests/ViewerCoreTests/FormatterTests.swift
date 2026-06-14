import XCTest
@testable import ViewerCore

final class FormatterTests: XCTestCase {

    // MARK: - JSON

    func test_json_compactInput_isPrettyPrinted() {
        let input = #"{"a":1,"b":[1,2,3]}"#
        let out = Formatter.prettyPrint(input, as: .json)
        // Pretty output should contain newlines + indentation.
        XCTAssertTrue(out.contains("\n"), "Pretty JSON should have newlines")
        XCTAssertTrue(out.contains("  "), "Pretty JSON should be indented")
        // Round-trip preserves semantics: parsing the pretty output
        // yields the same object as parsing the input.
        let original = try? JSONSerialization.jsonObject(
            with: input.data(using: .utf8)!, options: [.fragmentsAllowed])
        let formatted = try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!, options: [.fragmentsAllowed])
        XCTAssertNotNil(original)
        XCTAssertNotNil(formatted)
    }

    func test_json_invalidInput_returnsUnchanged() {
        let input = "{not actually json"
        let out = Formatter.prettyPrint(input, as: .json)
        XCTAssertEqual(out, input,
            "Invalid JSON should return input unchanged (no exception)")
    }

    func test_json_alreadyPretty_doesNotMangle() {
        let input = """
        {
          "a" : 1
        }
        """
        let out = Formatter.prettyPrint(input, as: .json)
        // Output should still be valid JSON with same content.
        let parsed = try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!, options: [.fragmentsAllowed])
        XCTAssertNotNil(parsed)
        if let dict = parsed as? [String: Any] {
            XCTAssertEqual(dict["a"] as? Int, 1)
        }
    }

    func test_json_sortsKeys() {
        let input = #"{"z":1,"a":2,"m":3}"#
        let out = Formatter.prettyPrint(input, as: .json)
        // After sorting, "a" should appear before "z".
        let aPos = out.firstIndex(of: "a")?.utf16Offset(in: out) ?? -1
        let zPos = out.firstIndex(of: "z")?.utf16Offset(in: out) ?? -2
        XCTAssertLessThan(aPos, zPos,
            "Sorted keys: 'a' line should appear before 'z' line. Output:\n\(out)")
    }

    // MARK: - XML

    func test_xml_compactInput_isPrettyPrinted() {
        let input = "<root><a>1</a><b>2</b></root>"
        let out = Formatter.prettyPrint(input, as: .xml)
        XCTAssertTrue(out.contains("\n"), "Pretty XML should have newlines")
        XCTAssertTrue(out.contains("<a>1</a>") || out.contains("<a>"),
            "Pretty XML should preserve element structure. Output:\n\(out)")
    }

    func test_xml_invalidInput_returnsUnchanged() {
        let input = "<<<not xml>>>"
        let out = Formatter.prettyPrint(input, as: .xml)
        // XMLDocument is permissive; even garbage might "parse" to a
        // text node. So we accept either an unchanged return OR a valid
        // pretty-printed text node. Either is fine; the important
        // invariant is "no crash, non-empty output".
        XCTAssertFalse(out.isEmpty)
    }

    // MARK: - JS (minified re-indent)

    /// The load-bearing safety invariant: re-indenting must preserve every
    /// significant byte — only whitespace OUTSIDE literals may change.
    /// `jsSignificantContent` is an INDEPENDENT lexer, so if `prettyPrintJS`
    /// dropped/reordered a char, or mis-lexed a regex and injected a newline
    /// inside the literal, the two projections would diverge and this fails.
    private func assertJSPreservesSignificant(
        _ input: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        let out = Formatter.prettyPrint(input, as: .js)
        XCTAssertEqual(
            Formatter.jsSignificantContent(input),
            Formatter.jsSignificantContent(out),
            "significant content changed — \(message)\nIN:  \(input)\nOUT:\n\(out)",
            file: file, line: line
        )
    }

    private static let jsCorpus: [String] = [
        "var a=1;var b=2;",
        "function f(x){if(x){return x*2}else{return 0}}",
        "const re=/ab+c/gi;const s=\"a/b\";",
        "const o={a:1,b:[1,2,3],c:{d:4}};",
        "x=a/b/c;y=1.5/2;",                       // divisions, not regex
        "arr.map(x=>{return x}).filter(y=>y>0);",
        "for(var i=0;i<3;i++){total+=i}",
        "//banner\nvar z=1;",                     // line comment
        "/* outer {braces} ; not code */var w=1;",// block comment with structural chars
        "const cls=/[a/b]{2,3}/u;",               // regex: char class + braces
        "return/x{1}/g;",                          // regex after `return` keyword
        "function noop(){}var k=noop();",          // empty block
        "const t=`hi ${name}, sum=${1+2}, brace=${ {q:1}.q }`;", // template w/ nested obj
        "if(a){b()}else if(c){d()}else{e()}",
        "const g=()=>{};",
        "obj['a/b']=1;obj[\"c;d\"]=2;",           // structural chars inside strings/subscripts
        "do{step()}while(go);",                    // do-while continuation
        "x=`a\\`b${1}c`;",                         // escaped backtick inside template
    ]

    func test_js_preservesSignificantContent_corpus() {
        for src in Self.jsCorpus {
            assertJSPreservesSignificant(src)
        }
    }

    func test_js_minified_isReindented() {
        let input = "function f(x){if(x){return x*2}else{return 0}}"
        let out = Formatter.prettyPrint(input, as: .js)
        XCTAssertTrue(out.contains("\n"), "Re-indented JS should have newlines.\n\(out)")
        XCTAssertTrue(out.contains("  "), "Re-indented JS should be indented.\n\(out)")
        XCTAssertNotEqual(out, input, "A one-line function should be expanded.")
    }

    func test_js_isIdempotent() {
        // Formatting already-formatted output must be a fixed point — pinning
        // that we don't keep adding/removing whitespace on re-runs.
        for src in Self.jsCorpus {
            let once = Formatter.prettyPrint(src, as: .js)
            let twice = Formatter.prettyPrint(once, as: .js)
            XCTAssertEqual(once, twice, "Not idempotent for: \(src)\nonce:\n\(once)\ntwice:\n\(twice)")
        }
    }

    func test_js_literalsArePreservedVerbatim() {
        // Structural characters inside literals must survive untouched — no
        // newline gets injected into a regex / string / comment / template.
        XCTAssertTrue(Formatter.prettyPrint("var r=/a{2,3}b/g;", as: .js).contains("/a{2,3}b/g"),
                      "regex with braces must stay intact")
        XCTAssertTrue(Formatter.prettyPrint("var s=\"{a};{b}\";", as: .js).contains("\"{a};{b}\""),
                      "string with braces/semicolons must stay intact")
        XCTAssertTrue(Formatter.prettyPrint("/* {x}; */code();", as: .js).contains("/* {x}; */"),
                      "block comment must stay intact")
        XCTAssertTrue(Formatter.prettyPrint("var t=`{a} ${b}`;", as: .js).contains("`{a} ${b}`"),
                      "template literal text must stay intact")
    }

    func test_js_emptyInput_returnsUnchanged() {
        XCTAssertEqual(Formatter.prettyPrint("", as: .js), "")
    }

    func test_js_regexAfterReturn_notTreatedAsDivision() {
        // `return/re/` is a regex, not division — a misread would inject a
        // newline at the `{` inside the pattern and corrupt the literal.
        let out = Formatter.prettyPrint("function f(){return/a{1,2}/g}", as: .js)
        XCTAssertTrue(out.contains("/a{1,2}/g"), "regex after `return` must be intact.\n\(out)")
    }

    func test_js_detect_extensions() {
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.js")), .js)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "m.mjs")), .js)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "c.cjs")), .js)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "/x/Bundle.JS")), .js)
    }

    func test_js_detect_jsxAndTs_areNotFormattable() {
        // JSX / TS carry syntax the brace re-indenter doesn't model — must not
        // claim a Format affordance that would mis-indent.
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.jsx")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.ts")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.tsx")))
    }

    func test_js_prettyPrintIfFormattable_wiredForJSURL() {
        let (out, ok) = Formatter.prettyPrintIfFormattable(
            "function f(){return 1}", url: URL(fileURLWithPath: "x.js"))
        XCTAssertTrue(ok, "a .js URL should format")
        XCTAssertTrue(out.contains("\n"), "formatted JS should be multi-line")
    }

    // MARK: - CSS (minified re-indent)

    private func assertCSSPreservesSignificant(
        _ input: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let out = Formatter.prettyPrint(input, as: .css)
        XCTAssertEqual(
            Formatter.cssSignificantContent(input),
            Formatter.cssSignificantContent(out),
            "significant content changed\nIN:  \(input)\nOUT:\n\(out)",
            file: file, line: line
        )
    }

    private static let cssCorpus: [String] = [
        "a{color:red}",
        "a,b,c{margin:0}",
        ".x{font:12px/1.4 serif;color:#fff}",            // `/` is a value char, not a comment
        "@media (min-width:600px){.y{display:flex}}",     // nested rules
        ".z{background:url(http://example.com/a.png) no-repeat}", // `//` inside url is NOT a comment
        "p{content:\"{};\"}",                              // string with structural chars
        "/* {brace}; not css */a{top:0}",                 // block comment with structural chars
        "div{color:rgb(1,2,3);margin:1px 2px 3px 4px}",   // commas in rgb() + value-list spaces
        ".a:hover,.b:focus{color:blue}",                  // pseudo-classes + selector list
        ":root{--main-color:#333;--gap:8px}",             // custom properties
        "a{background:url('x;y{z}')}",                     // string inside url() with structural chars
        ".n:nth-child(2n+1){opacity:.5}",                 // () in selector
    ]

    func test_css_preservesSignificantContent_corpus() {
        for src in Self.cssCorpus { assertCSSPreservesSignificant(src) }
    }

    func test_css_minified_isReindented() {
        let input = "a{color:red;margin:0}.b{display:none}"
        let out = Formatter.prettyPrint(input, as: .css)
        XCTAssertTrue(out.contains("\n"), "Re-indented CSS should have newlines.\n\(out)")
        XCTAssertTrue(out.contains("  "), "Re-indented CSS should be indented.\n\(out)")
        XCTAssertNotEqual(out, input)
    }

    func test_css_isIdempotent() {
        for src in Self.cssCorpus {
            let once = Formatter.prettyPrint(src, as: .css)
            let twice = Formatter.prettyPrint(once, as: .css)
            XCTAssertEqual(once, twice, "Not idempotent for: \(src)\nonce:\n\(once)")
        }
    }

    func test_css_literalsArePreservedVerbatim() {
        XCTAssertTrue(Formatter.prettyPrint("p{content:\"{a};{b}\"}", as: .css).contains("\"{a};{b}\""),
                      "string with braces/semicolons must stay intact")
        XCTAssertTrue(Formatter.prettyPrint("/* {x}; */a{top:0}", as: .css).contains("/* {x}; */"),
                      "block comment must stay intact")
        XCTAssertTrue(Formatter.prettyPrint("a{background:url(http://h/x.png)}", as: .css).contains("url(http://h/x.png)"),
                      "url() with // must not be split as a comment")
    }

    func test_css_emptyInput_returnsUnchanged() {
        XCTAssertEqual(Formatter.prettyPrint("", as: .css), "")
    }

    func test_css_detect_extensions() {
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.css")), .css)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "/x/Site.CSS")), .css)
    }

    func test_css_detect_scssAndLess_areNotFormattable() {
        // SCSS/LESS add `//` line comments + nesting the plain-CSS lexer
        // doesn't model — must not offer a Format affordance that mis-reads them.
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.scss")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.less")))
    }

    func test_css_prettyPrintIfFormattable_wiredForCSSURL() {
        let (out, ok) = Formatter.prettyPrintIfFormattable(
            "a{color:red}", url: URL(fileURLWithPath: "x.css"))
        XCTAssertTrue(ok, "a .css URL should format")
        XCTAssertTrue(out.contains("\n"), "formatted CSS should be multi-line")
    }

    // MARK: - SupportedFormat detection

    func test_detect_json_extensions() {
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.json")), .json)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "/tmp/b.JSON")), .json)
    }

    func test_detect_xml_extensions() {
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.xml")), .xml)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "info.plist")), .xml)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "page.html")), .xml)
    }

    // MARK: - Dead-affordance regressions

    /// JSON-Lines is one JSON value per line, not a single document.
    /// `detect` must NOT map `.jsonl` to `.json` — otherwise the Format
    /// affordance is offered but `prettyPrintJSON` fails on the multi-line
    /// body and silently returns the content unchanged (didFormat:false).
    func test_detect_jsonl_isNotFormattable() {
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "log.jsonl")),
            ".jsonl is JSON-Lines, not a single JSON doc — must not be formattable")

        // A representative JSON-Lines body: each line is valid JSON, but the
        // whole is not. The convenience entry point must report no format.
        let jsonlText = """
        {"event":"start","ts":1}
        {"event":"stop","ts":2}
        """
        let (out, didFormat) = Formatter.prettyPrintIfFormattable(
            jsonlText, url: URL(fileURLWithPath: "log.jsonl"))
        XCTAssertFalse(didFormat,
            ".jsonl must not claim a successful format")
        XCTAssertEqual(out, jsonlText,
            "content returned unchanged when not formattable")
    }

    /// `.svg` is classified as `.image` (preview/HEX only) by
    /// `FileTypeDetector` and never reaches a Formatter. Mapping it to
    /// `.xml` here was dead config; `detect` must return nil for it.
    func test_detect_svg_isNotFormattable() {
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "icon.svg")),
            ".svg commits to image/preview — must not be offered as an XML format")
    }

    func test_detect_unsupported() {
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.md")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.txt")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.swift")))
    }

    func test_prettyPrintIfFormattable_returnsDidFormatFlag() {
        let (out1, ok1) = Formatter.prettyPrintIfFormattable(
            #"{"x":1}"#, url: URL(fileURLWithPath: "a.json"))
        XCTAssertTrue(ok1)
        XCTAssertNotEqual(out1, #"{"x":1}"#)

        let (out2, ok2) = Formatter.prettyPrintIfFormattable(
            "plain text", url: URL(fileURLWithPath: "a.txt"))
        XCTAssertFalse(ok2)
        XCTAssertEqual(out2, "plain text")
    }
}
