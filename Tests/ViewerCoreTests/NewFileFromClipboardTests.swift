import XCTest
@testable import ViewerCore

/// TSK-935 — new scratch tab from clipboard: content-type detection + seeded
/// file creation.
final class NewFileFromClipboardTests: XCTestCase {

    // MARK: detect

    func test_detect_jsonObject() {
        XCTAssertEqual(NewFileType.detect(#"{"a":1}"#), .json)
    }
    func test_detect_jsonArray_withWhitespace() {
        XCTAssertEqual(NewFileType.detect("\n  [1, 2, 3]\n"), .json)
    }
    func test_detect_plainText() {
        XCTAssertEqual(NewFileType.detect("just some notes"), .text)
    }
    func test_detect_prose_withBraces_isNotJSON() {
        // Starts with text, not a JSON token → text (no false positive).
        XCTAssertEqual(NewFileType.detect("see {this}"), .text)
    }
    func test_detect_malformedJSON_isText() {
        XCTAssertEqual(NewFileType.detect("{not valid json"), .text)
    }
    func test_pastedBaseName_keepsExtension() {
        XCTAssertEqual(NewFileType.json.pastedBaseName, "Pasted.json")
        XCTAssertEqual(NewFileType.text.pastedBaseName, "Pasted.txt")
    }

    // MARK: create-with-contents

    func test_create_writesContents() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-clip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try NewFileCreator.create(in: dir, baseName: "Pasted.txt", contents: "hello\nworld")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello\nworld")
    }

    func test_create_emptyContents_stillEmptyFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-clip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try NewFileCreator.create(in: dir, baseName: "Untitled.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
    }

    func test_create_secondCall_doesNotClobber_andKeepsContents() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-clip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try NewFileCreator.create(in: dir, baseName: "Pasted.txt", contents: "first")
        let b = try NewFileCreator.create(in: dir, baseName: "Pasted.txt", contents: "second")
        XCTAssertNotEqual(a, b, "second create must pick a non-colliding name")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "second")
    }
}
