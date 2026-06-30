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
}
