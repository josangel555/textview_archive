import XCTest
@testable import RustCore

/// Behaviour pins for the allocation-free `field(_:)` / `requireField(_:)`
/// accessors on `MsgPackValue` (TSK-798 throwaway-work slice). These replace the
/// per-row `el.mapValue().require(...)` dict round-trip in the FFI decode loops
/// (find / fuzzy / grep / transcript / markdown-chunk results), so the contract
/// they must uphold is "same observable result as the dict path, no behaviour
/// change" — otherwise the response decoders silently regress.
///
/// The invariant under test: for every key, `v.field(k)` and
/// `v.requireField(k)` return EXACTLY what `try v.mapValue()[k]` /
/// `try v.mapValue().require(k)` would, and throw the SAME error on the same
/// shape/absence failures.
final class MsgPackFieldAccessorTests: XCTestCase {

    // A representative response-row map: a few string-keyed fields of mixed type,
    // exactly the shape the core emits per find/fuzzy/transcript result element.
    private func row() -> MsgPackValue {
        .map([
            MsgPackPair(.string("location"), .uint(42)),
            MsgPackPair(.string("length"), .uint(7)),
            MsgPackPair(.string("line"), .uint(3)),
            MsgPackPair(.string("column"), .uint(11)),
            MsgPackPair(.string("kind"), .string("user")),
        ])
    }

    // MARK: - field(_:) parity with mapValue() subscript

    func test_field_returnsSameValueAsDictPath() throws {
        let v = row()
        let dict = try v.mapValue()
        for key in ["location", "length", "line", "column", "kind"] {
            XCTAssertEqual(try v.field(key), dict[key],
                           "field(\(key)) diverged from mapValue()[\(key)]")
        }
    }

    func test_field_absentKeyReturnsNil() throws {
        XCTAssertNil(try row().field("missing"))
        // And the dict path agrees it's absent.
        XCTAssertNil(try row().mapValue()["missing"])
    }

    func test_field_preservesValueType() throws {
        let v = row()
        XCTAssertEqual(try v.field("location")?.u64Value(), 42)
        XCTAssertEqual(try v.field("kind")?.stringValue(), "user")
    }

    func test_field_throwsTypeMismatchOnNonMap() {
        XCTAssertThrowsError(try MsgPackValue.array([.uint(1)]).field("x")) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("expected map"))
        }
        XCTAssertThrowsError(try MsgPackValue.string("nope").field("x")) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("expected map"))
        }
    }

    // MARK: - requireField(_:) parity with mapValue().require(_:)

    func test_requireField_returnsSameAsDictRequire() throws {
        let v = row()
        let dict = try v.mapValue()
        for key in ["location", "kind"] {
            XCTAssertEqual(try v.requireField(key), try dict.require(key))
        }
    }

    func test_requireField_throwsMissingKey_sameAsDictRequire() throws {
        // requireField throws .missingKey...
        XCTAssertThrowsError(try row().requireField("nope")) { err in
            XCTAssertEqual(err as? MsgPackError, .missingKey("nope"))
        }
        // ...exactly as the dict path does, so error handling is unchanged.
        let dict = try row().mapValue()
        XCTAssertThrowsError(try dict.require("nope")) { err in
            XCTAssertEqual(err as? MsgPackError, .missingKey("nope"))
        }
    }

    func test_requireField_throwsTypeMismatchOnNonMap() {
        XCTAssertThrowsError(try MsgPackValue.uint(1).requireField("x")) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("expected map"))
        }
    }

    // MARK: - first-match semantics on duplicate keys (matches mapValue()'s
    // last-writer-wins only differs on duplicates; the core never emits them,
    // but pin the documented behaviour so it can't silently drift).

    func test_field_returnsFirstMatchOnDuplicateKey() throws {
        let dup = MsgPackValue.map([
            MsgPackPair(.string("k"), .uint(1)),
            MsgPackPair(.string("k"), .uint(2)),
        ])
        // field(_:) returns the FIRST occurrence...
        XCTAssertEqual(try dup.field("k"), .uint(1))
        // ...whereas the dict path keeps the LAST (documented divergence, only
        // observable on malformed duplicate-key input the core never produces).
        XCTAssertEqual(try dup.mapValue()["k"], .uint(2))
    }

    // MARK: - non-string keys are skipped, just like mapValue()

    func test_field_skipsNonStringKeys() throws {
        let mixed = MsgPackValue.map([
            MsgPackPair(.uint(0), .string("int-keyed-ignored")),
            MsgPackPair(.string("real"), .string("kept")),
        ])
        XCTAssertEqual(try mixed.field("real"), .string("kept"))
        // An int key can't be looked up by string — nil, same as the dict path
        // which only ingests string keys.
        XCTAssertNil(try mixed.field("0"))
    }

    // MARK: - end-to-end: decode a real wire frame, then read it both ways

    func test_field_matchesDictPath_overDecodedWireFrame() throws {
        // Encode a row, decode it through the real reader, and confirm both
        // access paths agree on a value that actually round-tripped the wire.
        let encoded = row().encode()
        var reader = MsgPackReader(encoded)
        let decoded = try reader.decode()
        let dict = try decoded.mapValue()
        XCTAssertEqual(try decoded.field("line"), dict["line"])
        XCTAssertEqual(try decoded.requireField("kind").stringValue(), "user")
        XCTAssertNil(try decoded.field("absent"))
    }
}
