import XCTest
@testable import ViewerCore

/// `WalkthroughCatalog` is the read-side index behind a future
/// "Walkthroughs ▸" library/menu (TSK-316 catalog/management). These
/// tests pin the directory-scan + header-decode + sort behavior so a
/// library panel built on top can trust it.
final class WalkthroughCatalogTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func write(_ name: String, _ json: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func script(
        id: String,
        title: String,
        schema: String = "textview.walkthrough/v1",
        createdAt: String? = nil,
        steps: Int = 1
    ) -> String {
        let stepObjs = (0..<steps).map {
            "{ \"id\": \"s\($0)\", \"actions\": [{ \"kind\": \"narrateOnly\" }] }"
        }.joined(separator: ",\n")
        let created = createdAt.map { "\"createdAt\": \"\($0)\"," } ?? ""
        return """
        {
          "schema": "\(schema)",
          "id": "\(id)",
          "title": "\(title)",
          \(created)
          "steps": [\(stepObjs)]
        }
        """
    }

    // MARK: - Happy path

    func test_entries_summarizesEachJSONFile() throws {
        _ = try write("a.json", script(id: "a", title: "Alpha", steps: 3))
        _ = try write("b.json", script(id: "b", title: "Beta", steps: 1))

        let entries = WalkthroughCatalog.entries(in: tmp)
        XCTAssertEqual(entries.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.scriptID, $0) })
        XCTAssertEqual(byID["a"]?.title, "Alpha")
        XCTAssertEqual(byID["a"]?.stepCount, 3)
        XCTAssertEqual(byID["b"]?.stepCount, 1)
        XCTAssertEqual(byID["a"]?.schema, .v1)
    }

    // MARK: - Delete (TSK-1211)

    func test_delete_removesFileAndDropsFromCatalog() throws {
        let url = try write("gone.json", script(id: "g", title: "Gone"))
        let entry = try XCTUnwrap(WalkthroughCatalog.entries(in: tmp).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(WalkthroughCatalog.delete(entry), "delete succeeds")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "delete removes the on-disk file")
        XCTAssertTrue(WalkthroughCatalog.entries(in: tmp).isEmpty,
                      "deleted walkthrough no longer appears in the catalog")
    }

    func test_delete_missingFile_returnsFalse() throws {
        _ = try write("temp.json", script(id: "t", title: "T"))
        let entry = try XCTUnwrap(WalkthroughCatalog.entries(in: tmp).first)
        XCTAssertTrue(WalkthroughCatalog.delete(entry))
        XCTAssertFalse(WalkthroughCatalog.delete(entry),
                       "deleting an already-removed file returns false, no throw")
    }

    func test_entries_idIsURL_not_scriptID() throws {
        // Two files with the SAME script id (a repo-bound copy of a
        // user-global tour) must remain distinct rows — list identity is
        // the URL, not the script id.
        _ = try write("a.json", script(id: "dup", title: "A"))
        _ = try write("b.json", script(id: "dup", title: "B"))
        let entries = WalkthroughCatalog.entries(in: tmp)
        XCTAssertEqual(entries.count, 2)
        // List identity is the URL: distinct files survive even though the
        // script id collides. (Compare by filename — `contentsOfDirectory`
        // canonicalizes /var → /private/var, so full-path equality against
        // a caller-built URL is symlink-sensitive; `id` IS the url, and the
        // two ids being distinct is the property under test.)
        XCTAssertEqual(entries.map(\.id).count, Set(entries.map(\.id)).count,
                       "Each row must have a distinct URL id")
        XCTAssertEqual(Set(entries.map { $0.url.lastPathComponent }),
                       Set(["a.json", "b.json"]))
        XCTAssertEqual(Set(entries.map(\.scriptID)), Set(["dup"]))
    }

    // MARK: - Filtering / robustness

    func test_entries_ignoresNonJSONFiles() throws {
        _ = try write("a.json", script(id: "a", title: "Alpha"))
        try Data("not json".utf8).write(to: tmp.appendingPathComponent("readme.txt"))
        try Data("{}".utf8).write(to: tmp.appendingPathComponent("a.json.tmp"))
        let entries = WalkthroughCatalog.entries(in: tmp)
        XCTAssertEqual(entries.map(\.scriptID), ["a"])
    }

    func test_entries_skipsMalformedFile_keepsRest() throws {
        _ = try write("good.json", script(id: "good", title: "Good"))
        _ = try write("corrupt.json", "{ this is not valid json")
        _ = try write("unknownSchema.json",
                      script(id: "future", title: "Future",
                             schema: "textview.walkthrough/v999"))
        // One bad + one unknown-schema file must NOT blank the list.
        let entries = WalkthroughCatalog.entries(in: tmp)
        XCTAssertEqual(entries.map(\.scriptID), ["good"])
    }

    func test_entries_missingDirectory_returnsEmpty() {
        let gone = tmp.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(WalkthroughCatalog.entries(in: gone), [])
    }

    func test_entry_oversizeFile_skipped() throws {
        // A file larger than the header read cap is refused (tamper /
        // runaway guard) — entry() returns nil rather than inflating it.
        let big = tmp.appendingPathComponent("big.json")
        let padding = String(repeating: " ", count: WalkthroughCatalog.maxHeaderReadBytes + 1)
        try Data(("{}" + padding).utf8).write(to: big)
        XCTAssertNil(WalkthroughCatalog.entry(forFileAt: big))
    }

    // MARK: - Sort

    func test_entries_sortedNewestFirstByCreatedAt() throws {
        _ = try write("old.json",
                      script(id: "old", title: "Old", createdAt: "2026-01-01T00:00:00Z"))
        _ = try write("new.json",
                      script(id: "new", title: "New", createdAt: "2026-06-01T00:00:00Z"))
        _ = try write("mid.json",
                      script(id: "mid", title: "Mid", createdAt: "2026-03-01T00:00:00Z"))
        let entries = WalkthroughCatalog.entries(in: tmp)
        XCTAssertEqual(entries.map(\.scriptID), ["new", "mid", "old"])
    }

    func test_entries_unsorted_returnsRawOrder() throws {
        _ = try write("a.json", script(id: "a", title: "A", createdAt: "2026-01-01T00:00:00Z"))
        _ = try write("b.json", script(id: "b", title: "B", createdAt: "2026-06-01T00:00:00Z"))
        // sorted:false must NOT apply the newest-first reorder. We don't
        // assert a specific order (FS enumeration order is unspecified),
        // only that both survive and no sort was applied beyond the scan.
        let entries = WalkthroughCatalog.entries(in: tmp, sorted: false)
        XCTAssertEqual(Set(entries.map(\.scriptID)), Set(["a", "b"]))
    }

    func test_entry_decodesOptionalHeaderFields() throws {
        let json = """
        {
          "schema": "textview.walkthrough/v2",
          "id": "rich",
          "title": "Rich",
          "subtitle": "A subtitle",
          "author": "claude:opus",
          "createdAt": "2026-05-01T12:00:00Z",
          "estimatedDurationSec": 120,
          "steps": [{ "id": "s1", "actions": [{ "kind": "narrateOnly" }] }]
        }
        """
        let url = try write("rich.json", json)
        let e = try XCTUnwrap(WalkthroughCatalog.entry(forFileAt: url))
        XCTAssertEqual(e.schema, .v2)
        XCTAssertEqual(e.subtitle, "A subtitle")
        XCTAssertEqual(e.author, "claude:opus")
        XCTAssertEqual(e.estimatedDurationSec, 120)
        XCTAssertNotNil(e.createdAt)
        XCTAssertNotNil(e.modifiedAt)
    }
}
