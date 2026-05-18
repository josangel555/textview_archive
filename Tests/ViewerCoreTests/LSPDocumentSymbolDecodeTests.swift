import XCTest
@testable import ViewerCore

/// Decode-side tests for `textDocument/documentSymbol`. Covers both the
/// modern `DocumentSymbol[]` shape and the legacy `SymbolInformation[]`
/// shape. Servers in the wild emit either; the client normalizes.
final class LSPDocumentSymbolDecodeTests: XCTestCase {

    func test_null_result() {
        let syms = LSPClient.decodeDocumentSymbol(Data("null".utf8))
        XCTAssertEqual(syms.count, 0)
    }

    func test_empty_array() {
        let syms = LSPClient.decodeDocumentSymbol(Data("[]".utf8))
        XCTAssertEqual(syms.count, 0)
    }

    func test_modern_documentSymbol_shape() {
        let data = Data(#"""
        [{
            "name":"Foo",
            "detail":"struct Foo",
            "kind":23,
            "range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}},
            "selectionRange":{"start":{"line":0,"character":7},"end":{"line":0,"character":10}},
            "children":[
                {"name":"bar","kind":6,
                 "range":{"start":{"line":2,"character":0},"end":{"line":4,"character":0}},
                 "selectionRange":{"start":{"line":2,"character":9},"end":{"line":2,"character":12}}
                }
            ]
        }]
        """#.utf8)
        let syms = LSPClient.decodeDocumentSymbol(data)
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms[0].name, "Foo")
        XCTAssertEqual(syms[0].kind, .struct)
        XCTAssertEqual(syms[0].detail, "struct Foo")
        XCTAssertEqual(syms[0].children.count, 1)
        XCTAssertEqual(syms[0].children[0].name, "bar")
        XCTAssertEqual(syms[0].children[0].kind, .method)
        XCTAssertNil(syms[0].uri) // modern shape — no uri
    }

    func test_legacy_symbolInformation_shape() {
        let data = Data(#"""
        [{
            "name":"foo",
            "kind":12,
            "location":{
                "uri":"file:///a.swift",
                "range":{"start":{"line":3,"character":0},"end":{"line":3,"character":5}}
            }
        }]
        """#.utf8)
        let syms = LSPClient.decodeDocumentSymbol(data)
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms[0].name, "foo")
        XCTAssertEqual(syms[0].kind, .function)
        XCTAssertEqual(syms[0].uri, "file:///a.swift")
        XCTAssertEqual(syms[0].children.count, 0)
    }

    func test_unknown_kind_maps_to_other() {
        let data = Data(#"""
        [{
            "name":"WeirdThing",
            "kind":999,
            "range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}},
            "selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":10}}
        }]
        """#.utf8)
        let syms = LSPClient.decodeDocumentSymbol(data)
        XCTAssertEqual(syms[0].kind, .other)
    }

    func test_garbage_input_returns_empty() {
        XCTAssertEqual(LSPClient.decodeDocumentSymbol(Data("not json".utf8)).count, 0)
        XCTAssertEqual(LSPClient.decodeDocumentSymbol(Data(#""string""#.utf8)).count, 0)
        XCTAssertEqual(LSPClient.decodeDocumentSymbol(Data("42".utf8)).count, 0)
    }
}
