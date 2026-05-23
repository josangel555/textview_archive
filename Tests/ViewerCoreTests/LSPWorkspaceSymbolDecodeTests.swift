import XCTest
@testable import ViewerCore

/// Decoder coverage for `workspace/symbol` and `publishDiagnostics`.
/// Both share `parseRange` / `parseLocation` with the existing
/// definition / documentSymbol decoders; these tests pin the shapes
/// unique to the new endpoints.
final class LSPWorkspaceSymbolDecodeTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - workspace/symbol

    func test_decodeWorkspaceSymbol_emptyArray() {
        XCTAssertEqual(LSPClient.decodeWorkspaceSymbol(data("[]")).count, 0)
    }

    func test_decodeWorkspaceSymbol_null() {
        XCTAssertEqual(LSPClient.decodeWorkspaceSymbol(data("null")).count, 0)
    }

    func test_decodeWorkspaceSymbol_symbolInformation() {
        // Legacy SymbolInformation: full location, optional container.
        let json = #"""
        [
          {
            "name": "doStuff",
            "kind": 12,
            "containerName": "Foo",
            "location": {
              "uri": "file:///tmp/Foo.swift",
              "range": {
                "start": {"line": 4, "character": 8},
                "end": {"line": 4, "character": 14}
              }
            }
          }
        ]
        """#
        let syms = LSPClient.decodeWorkspaceSymbol(data(json))
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms.first?.name, "doStuff")
        XCTAssertEqual(syms.first?.kind, .function)
        XCTAssertEqual(syms.first?.containerName, "Foo")
        XCTAssertEqual(syms.first?.location.range.start.line, 4)
        XCTAssertEqual(syms.first?.location.range.start.character, 8)
    }

    func test_decodeWorkspaceSymbol_skipsURIOnlyStubs() {
        // Modern WorkspaceSymbol with `location: {uri: ...}` (no
        // range) requires `workspaceSymbol/resolve` to fetch the
        // range — v1 punts on resolve and silently drops these.
        let json = #"""
        [
          {
            "name": "lazyResolve",
            "kind": 12,
            "location": {"uri": "file:///x.swift"}
          }
        ]
        """#
        XCTAssertEqual(LSPClient.decodeWorkspaceSymbol(data(json)).count, 0)
    }

    func test_decodeWorkspaceSymbol_unknownKindFallsBackToOther() {
        let json = #"""
        [
          {
            "name": "weird",
            "kind": 9999,
            "location": {
              "uri": "file:///x.swift",
              "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}
            }
          }
        ]
        """#
        let syms = LSPClient.decodeWorkspaceSymbol(data(json))
        XCTAssertEqual(syms.first?.kind, .other)
    }

    // MARK: - publishDiagnostics

    func test_parseDiagnostic_minimal() {
        let dict: [String: Any] = [
            "range": [
                "start": ["line": 3, "character": 5],
                "end":   ["line": 3, "character": 12],
            ],
            "message": "cannot find 'foo'",
        ]
        let d = LSPClient.parseDiagnostic(dict)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.message, "cannot find 'foo'")
        // Spec: severity defaults to .error when absent.
        XCTAssertEqual(d?.severity, .error)
        XCTAssertNil(d?.source)
    }

    func test_parseDiagnostic_severityIsParsed() {
        let dict: [String: Any] = [
            "range": [
                "start": ["line": 0, "character": 0],
                "end":   ["line": 0, "character": 1],
            ],
            "severity": 2,
            "message": "unused variable",
            "source": "swiftc",
        ]
        let d = LSPClient.parseDiagnostic(dict)
        XCTAssertEqual(d?.severity, .warning)
        XCTAssertEqual(d?.source, "swiftc")
    }

    func test_parseDiagnostic_codeBothStringAndInt() {
        let stringCode: [String: Any] = [
            "range": ["start": ["line": 0, "character": 0],
                      "end":   ["line": 0, "character": 1]],
            "message": "x",
            "code": "E001",
        ]
        XCTAssertEqual(LSPClient.parseDiagnostic(stringCode)?.code, "E001")
        let intCode: [String: Any] = [
            "range": ["start": ["line": 0, "character": 0],
                      "end":   ["line": 0, "character": 1]],
            "message": "x",
            "code": 42,
        ]
        XCTAssertEqual(LSPClient.parseDiagnostic(intCode)?.code, "42")
    }

    func test_parseDiagnostic_dropsMalformed() {
        // No range — invalid; should drop.
        let badDict: [String: Any] = ["message": "x"]
        XCTAssertNil(LSPClient.parseDiagnostic(badDict))
        // No message — invalid; should drop.
        let noMessage: [String: Any] = [
            "range": ["start": ["line": 0, "character": 0],
                      "end":   ["line": 0, "character": 1]],
        ]
        XCTAssertNil(LSPClient.parseDiagnostic(noMessage))
    }
}
