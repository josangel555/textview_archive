import XCTest
@testable import ViewerCore

/// Correctness pins for `TextTools` (TSK-292/294/295). SHA-256 + Base64
/// use published test vectors so an algorithm/encoding regression fails
/// loudly.
final class TextToolsTests: XCTestCase {

    // MARK: UUID

    func testUUID_isLowercasedV4Shape() {
        let u = TextTools.uuid()
        // 8-4-4-4-12 hex, lowercase, version nibble 4, variant nibble 8/9/a/b.
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        XCTAssertNotNil(u.range(of: pattern, options: .regularExpression),
                        "unexpected UUID shape: \(u)")
    }

    func testUUID_isFreshEachCall() {
        XCTAssertNotEqual(TextTools.uuid(), TextTools.uuid())
    }

    // MARK: Base64

    func testBase64Encode_knownVector() {
        XCTAssertEqual(TextTools.base64Encode("hello"), "aGVsbG8=")
        XCTAssertEqual(TextTools.base64Encode(""), "")
    }

    func testBase64Decode_knownVector() {
        XCTAssertEqual(TextTools.base64Decode("aGVsbG8="), "hello")
    }

    func testBase64_roundTripsUnicode() {
        let s = "héllo 世界 — 🌍"
        XCTAssertEqual(TextTools.base64Decode(TextTools.base64Encode(s)), s)
    }

    func testBase64Decode_toleratesWrappingWhitespace() {
        // MIME-style wrapped / pasted-with-newlines input still decodes.
        XCTAssertEqual(TextTools.base64Decode("aGVs\nbG8 ="), "hello")
    }

    func testBase64Decode_invalidReturnsNil() {
        // Length not a valid base64 quantum after ignoring junk.
        XCTAssertNil(TextTools.base64Decode("!!!"))
        // Valid base64 bytes that aren't valid UTF-8 → nil.
        XCTAssertNil(TextTools.base64Decode("/w=="))   // 0xFF, not UTF-8
    }

    /// TSK-503: invalid input must decode to `nil` DETERMINISTICALLY across
    /// Foundation versions. The bug was that `.ignoreUnknownCharacters`
    /// returned `""` on macOS 15+ for all-junk input (`"!!!"`) and silently
    /// dropped junk mid-string (`"ab@cd"` → `"abcd"`); strict decode rejects
    /// any non-alphabet char on every OS. Empty / whitespace-only stays `""`
    /// so the `base64Decode(base64Encode("")) == ""` round-trip identity holds.
    func testBase64Decode_rejectsNonAlphabetDeterministically() {
        XCTAssertNil(TextTools.base64Decode("!!!"))
        XCTAssertNil(TextTools.base64Decode("@@@@"))
        XCTAssertNil(TextTools.base64Decode("ab@cd"))   // no silent junk-strip
        XCTAssertNil(TextTools.base64Decode("a-_b"))    // URL-safe is not standard
        XCTAssertEqual(TextTools.base64Decode(""), "")  // empty round-trips
        XCTAssertEqual(TextTools.base64Decode("   \n "), "")  // whitespace-only
    }

    // MARK: SHA-256 (NIST/standard test vectors)

    func testSHA256_emptyString() {
        XCTAssertEqual(
            TextTools.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256_abc() {
        XCTAssertEqual(
            TextTools.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256_is64LowercaseHexChars() {
        let h = TextTools.sha256Hex("any input")
        XCTAssertEqual(h.count, 64)
        XCTAssertNotNil(h.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    // MARK: File checksums (TSK-347)

    func testSHA256_dataOverload_matchesTextAndVector() {
        XCTAssertEqual(
            TextTools.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            TextTools.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // The text overload is exactly the data overload over UTF-8 bytes.
        XCTAssertEqual(TextTools.sha256Hex("abc"), TextTools.sha256Hex(Data("abc".utf8)))
    }

    func testFileChecksum_knownVectors() throws {
        let dir = FileManager.default.temporaryDirectory
        let abc = dir.appendingPathComponent("mdv-sha-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: abc)
        defer { try? FileManager.default.removeItem(at: abc) }
        XCTAssertEqual(try FileChecksum.sha256Hex(ofFileAt: abc),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let empty = dir.appendingPathComponent("mdv-sha-\(UUID().uuidString).bin")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertEqual(try FileChecksum.sha256Hex(ofFileAt: empty),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// Chunked streaming must produce the SAME digest as one-shot hashing —
    /// proves the incremental fold is correct across read boundaries. A tiny
    /// `chunkSize` forces many iterations over a multi-KB file.
    func testFileChecksum_streamsAcrossChunksIdenticalToOneShot() throws {
        let bytes = Data((0..<5000).map { UInt8($0 % 256) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sha-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FileChecksum.sha256Hex(ofFileAt: url, chunkSize: 7),
                       TextTools.sha256Hex(bytes))
    }

    /// File hashing handles raw non-UTF-8 bytes the text API can't represent.
    func testFileChecksum_hashesNonUTF8Bytes() throws {
        let bytes = Data([0xFF, 0x00, 0xFE, 0x80, 0x01])
        XCTAssertNil(String(data: bytes, encoding: .utf8))   // not valid UTF-8
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sha-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FileChecksum.sha256Hex(ofFileAt: url),
                       TextTools.sha256Hex(bytes))
    }

    func testFileChecksum_missingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-sha-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try FileChecksum.sha256Hex(ofFileAt: missing))
    }

    // MARK: Verb dispatcher (surface-agnostic)

    func testApply_dispatchesEachVerb() {
        XCTAssertEqual(TextTools.apply(.sha256, to: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(TextTools.apply(.base64Encode, to: "hello"), "aGVsbG8=")
        XCTAssertEqual(TextTools.apply(.base64Decode, to: "aGVsbG8="), "hello")
        // generator ignores input
        XCTAssertNotNil(TextTools.apply(.generateUUID, to: nil))
        XCTAssertNotNil(TextTools.apply(.generateUUID, to: "ignored"))
    }

    func testApply_base64DecodeFailureIsNil() {
        XCTAssertNil(TextTools.apply(.base64Decode, to: "!!!"))
    }

    func testVerb_metadata() {
        XCTAssertEqual(TextToolVerb.allCases.count, 4)
        // rawValues are unique, non-empty, and "tools."-namespaced (used as scriptVerb).
        let raws = TextToolVerb.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for v in TextToolVerb.allCases {
            XCTAssertTrue(v.rawValue.hasPrefix("tools."), v.rawValue)
            XCTAssertFalse(v.title.isEmpty)
        }
        XCTAssertFalse(TextToolVerb.generateUUID.transformsInput)
        XCTAssertTrue(TextToolVerb.sha256.transformsInput)
    }
}
