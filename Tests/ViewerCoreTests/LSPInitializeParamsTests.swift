import XCTest
@testable import ViewerCore

/// Pure coverage for `LSPClient.makeInitializeParams` — the `initialize`
/// request builder. Focus: the per-server `initializationOptions` wiring
/// (§11 / TSK-465) that was previously parsed from `lsp.json` but dropped
/// before the request. No server is spawned.
final class LSPInitializeParamsTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/ws-fixture")

    func test_baseParams_haveExpectedShape_andNoInitOptionsByDefault() {
        let p = LSPClient.makeInitializeParams(
            workspaceRoot: root, processId: 123, initializationOptions: nil)
        XCTAssertEqual(p["processId"] as? Int32, 123)
        XCTAssertEqual(p["rootUri"] as? String, root.absoluteString)
        XCTAssertNotNil(p["capabilities"])
        XCTAssertNil(p["initializationOptions"],
                     "no override ⇒ no initializationOptions field")
    }

    func test_validInitOptions_areForwardedVerbatim() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["maxItems": 50, "experimental": ["x": true]])
        let p = LSPClient.makeInitializeParams(
            workspaceRoot: root, processId: 1, initializationOptions: data)
        let opts = try XCTUnwrap(p["initializationOptions"] as? [String: Any])
        XCTAssertEqual(opts["maxItems"] as? Int, 50)
        XCTAssertEqual((opts["experimental"] as? [String: Any])?["x"] as? Bool, true)
    }

    func test_malformedInitOptions_areSkipped_notCrash() {
        // A truncated/garbage blob must never abort startup — the field is
        // simply omitted.
        let bad = Data([0x7B, 0x22, 0x61])   // `{"a` — invalid JSON
        let p = LSPClient.makeInitializeParams(
            workspaceRoot: root, processId: 1, initializationOptions: bad)
        XCTAssertNil(p["initializationOptions"],
                     "unparseable override ⇒ omitted, base params intact")
        XCTAssertNotNil(p["capabilities"])
    }

    func test_initOptions_canBeAJSONArray() throws {
        // initializationOptions is `any` per LSP; an array is legal.
        let data = try JSONSerialization.data(withJSONObject: [1, 2, 3])
        let p = LSPClient.makeInitializeParams(
            workspaceRoot: root, processId: 1, initializationOptions: data)
        XCTAssertEqual(p["initializationOptions"] as? [Int], [1, 2, 3])
    }
}
