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
        // The multi-algo entry point must throw on a missing file too.
        XCTAssertThrowsError(try FileChecksum.hex(ofFileAt: missing, algorithm: .crc32))
    }

    // MARK: Multi-algorithm file checksums (TSK-748)

    /// Canonical published digests of the bytes "abc" across every offered
    /// algorithm — pins each hasher against the standard test vectors, not just
    /// against itself. (NIST/RFC for the crypto hashes; CRC-32 IEEE for "abc".)
    func testFileChecksum_allAlgorithms_knownVectors_forABC() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-csum-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected: [ChecksumAlgorithm: String] = [
            .crc32:  "352441c2",
            .md5:    "900150983cd24fb0d6963f7d28e17f72",
            .sha1:   "a9993e364706816aba3e25717850c26c9cd0d89d",
            .sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            .sha512: "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                   + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        ]
        for algo in ChecksumAlgorithm.allCases {
            XCTAssertEqual(try FileChecksum.hex(ofFileAt: url, algorithm: algo),
                           expected[algo], "\(algo.label) digest of \"abc\"")
        }
    }

    /// CRC-32 against the de-facto standard check value: the IEEE/zlib CRC-32 of
    /// the ASCII string "123456789" is `0xcbf43926`. Also covers the empty-input
    /// identity (`0x00000000`) — guards the init/final XOR bookkeeping.
    func testFileChecksum_crc32_standardCheckVectors() throws {
        let dir = FileManager.default.temporaryDirectory
        let check = dir.appendingPathComponent("mdv-crc-\(UUID().uuidString).txt")
        try Data("123456789".utf8).write(to: check)
        defer { try? FileManager.default.removeItem(at: check) }
        XCTAssertEqual(try FileChecksum.hex(ofFileAt: check, algorithm: .crc32), "cbf43926")

        let empty = dir.appendingPathComponent("mdv-crc-\(UUID().uuidString).bin")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertEqual(try FileChecksum.hex(ofFileAt: empty, algorithm: .crc32), "00000000")
    }

    /// Every algorithm must stream identically to a one-shot hash — proves the
    /// incremental fold (and the CRC table walk) is correct across read
    /// boundaries when a tiny `chunkSize` forces many iterations.
    func testFileChecksum_allAlgorithms_streamIdenticalToOneShot() throws {
        let bytes = Data((0..<5000).map { UInt8($0 % 256) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-csum-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        for algo in ChecksumAlgorithm.allCases {
            XCTAssertEqual(try FileChecksum.hex(ofFileAt: url, algorithm: algo, chunkSize: 7),
                           try FileChecksum.hex(ofFileAt: url, algorithm: algo, chunkSize: 1 << 20),
                           "\(algo.label) chunked == one-shot")
        }
    }

    /// `.sha256` via the multi-algo entry point and the `sha256Hex` convenience
    /// must agree — the convenience is meant to be a thin delegate.
    func testFileChecksum_sha256ConvenienceMatchesGenericEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-csum-\(UUID().uuidString).bin")
        try Data((0..<300).map { UInt8($0 % 256) }).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FileChecksum.sha256Hex(ofFileAt: url),
                       try FileChecksum.hex(ofFileAt: url, algorithm: .sha256))
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
        XCTAssertEqual(TextToolVerb.allCases.count, 10)
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

    // MARK: Line / case transforms (TSK-352)

    func testSortLines_ascendingAndDescending() {
        XCTAssertEqual(TextTools.sortLines("banana\napple\ncherry"), "apple\nbanana\ncherry")
        XCTAssertEqual(TextTools.sortLines("banana\napple\ncherry", ascending: false),
                       "cherry\nbanana\napple")
    }

    func testUniqueLines_keepsFirstOccurrence_preservesOrder() {
        XCTAssertEqual(TextTools.uniqueLines("a\nb\na\nc\nb\na"), "a\nb\nc")
    }

    func testReverseLines() {
        XCTAssertEqual(TextTools.reverseLines("one\ntwo\nthree"), "three\ntwo\none")
    }

    /// `\r\n` is ONE separator; empty lines survive; output normalises to `\n`.
    func testLineTransforms_handleCRLF_andKeepEmptyLines() {
        XCTAssertEqual(TextTools.reverseLines("a\r\n\r\nb"), "b\n\na")
        XCTAssertEqual(TextTools.uniqueLines("x\r\nx\r\ny"), "x\ny")
    }

    func testApply_lineAndCaseTransforms() {
        XCTAssertEqual(TextTools.apply(.sortLinesAsc, to: "b\na"), "a\nb")
        XCTAssertEqual(TextTools.apply(.sortLinesDesc, to: "a\nb"), "b\na")
        XCTAssertEqual(TextTools.apply(.uniqueLines, to: "a\na\nb"), "a\nb")
        XCTAssertEqual(TextTools.apply(.reverseLines, to: "a\nb"), "b\na")
        XCTAssertEqual(TextTools.apply(.upperCase, to: "aBc"), "ABC")
        XCTAssertEqual(TextTools.apply(.lowerCase, to: "aBc"), "abc")
        // A transform with nil input degrades to "" (never crashes).
        XCTAssertEqual(TextTools.apply(.sortLinesAsc, to: nil), "")
    }
}
