import XCTest
@testable import ViewerCore

/// TSK-1596 — the web-diff route gate (ships ON; env/defaults kill-switch),
/// the Line|Word|Char granularity preference, and the Swift→page JSON wire.
final class WebDiffGateTests: XCTestCase {
    private let suite = "WebDiffGateTests-\(UUID().uuidString)"

    func test_shipsOn_envAndDefaultsKill() {
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(WebDiffGate.isEnabled(defaults: d, environment: [:]),
                      "web diff ships ON (owner 2026-07-24)")
        XCTAssertFalse(WebDiffGate.isEnabled(defaults: d, environment: ["MDV_WEB_DIFF": "0"]),
                       "env kill-switch")
        d.set(false, forKey: WebDiffGate.defaultsKey)
        XCTAssertFalse(WebDiffGate.isEnabled(defaults: d, environment: [:]),
                       "persisted opt-out")
        XCTAssertTrue(WebDiffGate.isEnabled(defaults: d, environment: ["MDV_WEB_DIFF": "1"]),
                      "env pin beats the persisted default")
    }

    func test_layoutPrefs_defaults() {
        // TSK-1598: wrap ships ON (the owner's complaint was the indefinite
        // horizontal extent); the changed-files nav ships ON.
        XCTAssertTrue(DiffViewPrefs.wrapDefault)
        XCTAssertTrue(DiffViewPrefs.fileNavDefault)
        XCTAssertEqual(DiffViewPrefs.wrapKey, "mdv.diffWrap")
        XCTAssertEqual(DiffViewPrefs.fileNavKey, "mdv.diffFileNav")
    }

    func test_granularity_defaultAndResolve() {
        XCTAssertEqual(DiffGranularity.default, .word)
        XCTAssertEqual(DiffGranularity.resolve(nil), .word)
        XCTAssertEqual(DiffGranularity.resolve("garbage"), .word)
        XCTAssertEqual(DiffGranularity.resolve("line"), .line)
        XCTAssertEqual(DiffGranularity.resolve("char"), .char)
        XCTAssertEqual(DiffGranularity.allCases.map(\.displayName), ["Line", "Word", "Char"])
    }

    func test_payload_wireShape() {
        // generate → rust parse → wire JSON: pins the page contract fields.
        let diffText = UnifiedDiffGenerator.generate(
            old: "alpha\nbeta\n", new: "alpha\nBETA\n", path: "t.txt")
        let files = RustDiffAdapter.parse(diffText)
        XCTAssertEqual(files.count, 1, "fixture must parse to one file")
        let json = DiffWebPayload.json(files)
        XCTAssertTrue(json.contains("\"np\":\"t.txt\""), "new-path field: \(json)")
        XCTAssertTrue(json.contains("\"k\":2") && json.contains("\"k\":1"),
                      "removed(2) + added(1) rows present: \(json)")
        XCTAssertTrue(json.contains("\"t\":\"BETA\""), "line text carried verbatim")
        XCTAssertTrue(json.contains("\"hunks\":["), "hunk array present")
    }

    func test_payload_kindCodes_andEmptyInput() {
        XCTAssertEqual(DiffWebPayload.kindCode(.context), 0)
        XCTAssertEqual(DiffWebPayload.kindCode(.added), 1)
        XCTAssertEqual(DiffWebPayload.kindCode(.removed), 2)
        XCTAssertEqual(DiffWebPayload.kindCode(.noNewline), 3)
        XCTAssertEqual(DiffWebPayload.json([]), "{\"files\":[]}",
                       "empty tree still yields the {pre, files} envelope shape")
    }

    func test_blobPairs_scansIndexLines_inFileOrder() {
        let text = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hi
        diff --git a/noindex.txt b/noindex.txt
        --- a/noindex.txt
        +++ b/noindex.txt
        @@ -1 +1 @@
        -p
        +q
        """
        let pairs = DiffWebPayload.blobPairs(text)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[0].old, "1111111"); XCTAssertEqual(pairs[0].new, "2222222")
        XCTAssertNil(pairs[1].old, "all-zero (added-side) sha normalizes to nil")
        XCTAssertEqual(pairs[1].new, "3333333")
        XCTAssertNil(pairs[2].old); XCTAssertNil(pairs[2].new)
    }

    func test_json_diffText_carriesPreambleAndBlobs() {
        // A git-show-shaped text: preamble before the first diff --git.
        let text = """
        abc1234def
        Tester <t@example.com>
        Mon Jul 20 12:00:00 2026

        fix: the thing

        diff --git a/f.txt b/f.txt
        index aaaa111..bbbb222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -old line
        +new line
        """
        let json = DiffWebPayload.json(diffText: text)
        XCTAssertTrue(json.hasPrefix("{"), "envelope, not bare array")
        XCTAssertTrue(json.contains("\"pre\":"), "commit preamble travels: \(json.prefix(200))")
        XCTAssertTrue(json.contains("fix: the thing"))
        XCTAssertTrue(json.contains("\"ob\":\"aaaa111\"") && json.contains("\"nb\":\"bbbb222\""),
                      "blob shas aligned onto the file entry: \(json)")
    }

    func test_payload_escapesHostileContent() {
        // Diff content with quotes/newlines/script tags must round-trip as
        // DATA (JSONEncoder escaping); the page inserts it via textContent.
        let diffText = UnifiedDiffGenerator.generate(
            old: "safe\n", new: "x\"</script><img onerror=alert(1)>\n", path: "evil.txt")
        let json = DiffWebPayload.json(RustDiffAdapter.parse(diffText))
        XCTAssertFalse(json.contains("</script>"),
                       "raw close-tag must not survive JSON escaping: \(json)")
        XCTAssertTrue(json.contains("\\\"") || json.contains("<\\/script>") || json.contains("\\u003C"),
                      "hostile content arrives escaped: \(json)")
    }
}
