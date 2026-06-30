import XCTest
@testable import ViewerCore

/// TSK-698 slice 1 — the JS-over-JSON transform engine (sandboxed JSContext).
final class JSTransformTests: XCTestCase {

    private func ok(_ json: String, _ expr: String) -> String? {
        if case .success(let s) = JSTransform.run(json: json, expression: expr) { return s }
        return nil
    }
    private func err(_ json: String, _ expr: String) -> JSTransform.TransformError? {
        if case .failure(let e) = JSTransform.run(json: json, expression: expr) { return e }
        return nil
    }

    func test_propertyAccess() {
        XCTAssertEqual(ok(#"{"a":1}"#, "input.a"), "1")
    }

    func test_dollarAlias() {
        XCTAssertEqual(ok(#"{"a":1}"#, "$.a + 1"), "2")
    }

    func test_arrayMap_prettyPrinted() {
        XCTAssertEqual(ok("[1,2,3]", "input.map(x => x * 2)"), "[\n  2,\n  4,\n  6\n]")
    }

    func test_objectResult_prettyPrinted() {
        XCTAssertEqual(ok(#"{"a":{"b":2}}"#, "input.a"), "{\n  \"b\": 2\n}")
    }

    func test_stringResult() {
        XCTAssertEqual(ok(#"{"name":"jos"}"#, "input.name.toUpperCase()"), "\"JOS\"")
    }

    func test_filterAndReduce() {
        XCTAssertEqual(
            ok("[1,2,3,4]", "input.filter(x => x % 2 === 0).reduce((a,b) => a + b, 0)"),
            "6")
    }

    func test_invalidJSON() {
        XCTAssertEqual(err("not json", "input"), .invalidJSON)
    }

    func test_jsException_onBadAccess() {
        guard case .jsException = err(#"{"a":1}"#, "input.b.c") else {
            return XCTFail("accessing a property of undefined must surface a JS exception")
        }
    }

    func test_syntaxError_isJsException() {
        guard case .jsException = err("{}", "this is not valid js (((") else {
            return XCTFail("a syntax error must be a jsException, not a crash")
        }
    }

    func test_undefinedResult_isUnserializable() {
        XCTAssertEqual(err(#"{"a":1}"#, "undefined"), .unserializableResult)
    }

    // Sandbox teeth: the JSContext exposes no I/O — a transform can't reach out.
    func test_sandbox_noFetch() {
        XCTAssertEqual(ok("{}", "typeof fetch"), "\"undefined\"")
    }
    func test_sandbox_noRequire() {
        XCTAssertEqual(ok("{}", "typeof require"), "\"undefined\"")
    }
    func test_sandbox_noProcess() {
        XCTAssertEqual(ok("{}", "typeof process"), "\"undefined\"")
    }

    // TSK-698 slice 2 — off-main exec + soft timeout (owner-approved approach B).

    func test_runAsync_normalScript_returnsResult() async {
        let r = await JSTransform.runAsync(
            json: "[1,2,3]", expression: "input.map(x => x * 2)", timeout: 2.0)
        XCTAssertEqual(try? r.get(), "[\n  2,\n  4,\n  6\n]")
    }

    func test_runAsync_runawayScript_softTimesOut_withoutHanging() async {
        let start = Date()
        // A CPU-bound loop that far exceeds the 0.1s deadline (can't be dead-code-
        // eliminated — `s` is returned) but is BOUNDED, so the test leaks no permanent
        // thread (it ends in ~1s rather than spinning forever like `while(true){}`).
        let r = await JSTransform.runAsync(
            json: "0",
            expression: "(function(){ let s = 0; for (let i = 0; i < 5e8; i++) { s += i; } return s; })()",
            timeout: 0.1)
        let elapsed = Date().timeIntervalSince(start)
        guard case .failure(.timedOut) = r else {
            return XCTFail("a runaway script must soft-time-out, got \(r)")
        }
        XCTAssertLessThan(elapsed, 5.0,
            "the soft timeout must return promptly, not block on the full script")
    }

    // TSK-698 slice 4 — beyond-JSON input (.lines for logs).

    func test_linesInput_filtersLog() {
        let log = "INFO start\nERROR boom\nINFO ok\nERROR bad\n"
        let r = JSTransform.run(content: log, as: .lines,
                                expression: #"input.filter(l => l.startsWith("ERROR"))"#)
        XCTAssertEqual(try? r.get(), "[\n  \"ERROR boom\",\n  \"ERROR bad\"\n]")
    }

    func test_linesInput_dropsTrailingNewlineTerminator() {
        XCTAssertEqual(try? JSTransform.run(content: "a\nb\nc\n", as: .lines, expression: "input.length").get(), "3")
        XCTAssertEqual(try? JSTransform.run(content: "a\nb\nc", as: .lines, expression: "input.length").get(), "3")
    }

    func test_prepareInput_lines_preservesInteriorBlankLines() {
        XCTAssertEqual(JSTransform.prepareInput("a\n\nb", as: .lines), #"["a","","b"]"#)
    }

    func test_jsonInputFormat_isIdentity() {
        XCTAssertEqual(try? JSTransform.run(content: "[10,20,30]", as: .json, expression: "input[1]").get(), "20")
    }

    // TSK-698 slice 4b — CSV input (header-keyed row objects, via CSVParser).

    func test_csvInput_filtersRowsByColumn() {
        let csv = "name,status\nalice,OK\nbob,ERROR\ncarol,ERROR\n"
        let r = JSTransform.run(content: csv, as: .csv,
                                expression: #"input.filter(r => r.status === "ERROR").map(r => r.name)"#)
        XCTAssertEqual(try? r.get(), "[\n  \"bob\",\n  \"carol\"\n]")
    }

    func test_csvInput_rowCount_excludesHeader() {
        XCTAssertEqual(try? JSTransform.run(content: "a,b\n1,2\n3,4\n", as: .csv, expression: "input.length").get(), "2")
    }

    func test_csvInput_objectKeyedByHeader() {
        XCTAssertEqual(try? JSTransform.run(content: "x,y\n10,20", as: .csv, expression: "input[0].y").get(), "\"20\"")
    }
}
