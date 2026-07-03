import XCTest
@testable import ViewerCore

/// TSK-705 — host coverage for the snippet management model (the create / edit /
/// delete / override BEHAVIOUR behind the management UI). The SwiftUI sheet is a
/// thin shell over this, so a logic regression fails here on the host gate even
/// though the rendering check is VM-only.
@MainActor
final class SnippetManagerModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetMgrTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeModel() -> SnippetManagerModel {
        let store = SnippetStore(storeURL: tmpDir.appendingPathComponent("snippets.json"))
        return SnippetManagerModel(store: store)
    }

    // MARK: - Reads

    func test_allSnippets_includesBuiltIns() {
        let m = makeModel()
        XCTAssertEqual(m.allSnippets.count, SnippetLibrary.builtIns.count)
        XCTAssertTrue(m.userSnippets.isEmpty)
        XCTAssertTrue(m.isBuiltIn("md.table"))
        XCTAssertFalse(m.isBuiltIn("no.such.id"))
    }

    // MARK: - Validation

    func test_validate_emptyName() {
        XCTAssertEqual(makeModel().validate(id: "x", name: "  ", body: "b"), .emptyName)
    }

    func test_validate_emptyBody() {
        XCTAssertEqual(makeModel().validate(id: "x", name: "n", body: ""), .emptyBody)
    }

    func test_validate_ok() {
        XCTAssertEqual(makeModel().validate(id: "x", name: "n", body: "b"), .ok)
        XCTAssertTrue(makeModel().validate(id: "x", name: "n", body: "b").isValid)
    }

    func test_validate_duplicateUserID() {
        let m = makeModel()
        XCTAssertEqual(m.save(id: "u.one", name: "One", body: "a"), .ok)
        // A *new* snippet on the same id collides.
        XCTAssertEqual(m.validate(id: "u.one", name: "Two", body: "b"),
                       .duplicateUserID("u.one"))
        // Editing that same id in place is NOT a duplicate.
        XCTAssertEqual(m.validate(id: "u.one", name: "Two", body: "b", editingID: "u.one"), .ok)
    }

    func test_validate_overridingBuiltInIsAllowed() {
        // Using a built-in id is an intentional override, not a duplicate.
        let m = makeModel()
        XCTAssertEqual(m.validate(id: "md.table", name: "My Table", body: "x"), .ok)
    }

    // MARK: - Add / edit / delete

    func test_save_addsUserSnippet_andPersists() {
        let m = makeModel()
        XCTAssertEqual(m.save(id: "  u.note ", name: " Note ", body: "<!-- $0 -->"), .ok)
        XCTAssertEqual(m.userSnippets.count, 1)
        let s = m.userSnippets[0]
        XCTAssertEqual(s.id, "u.note", "id is trimmed")
        XCTAssertEqual(s.name, "Note", "name is trimmed")
        XCTAssertEqual(s.body, "<!-- $0 -->", "body kept verbatim")
        // Appears in the merged set after the built-ins.
        XCTAssertEqual(m.allSnippets.count, SnippetLibrary.builtIns.count + 1)
    }

    func test_save_overrideBuiltIn_replacesInPlace() {
        let m = makeModel()
        XCTAssertEqual(m.save(id: "md.codeFence", name: "Code", body: "```$0```"), .ok)
        // Total count unchanged — the user snippet OVERRODE the built-in.
        XCTAssertEqual(m.allSnippets.count, SnippetLibrary.builtIns.count)
        let merged = m.allSnippets.first { $0.id == "md.codeFence" }
        XCTAssertEqual(merged?.body, "```$0```", "user override wins")
    }

    func test_save_renameID_dropsOldEntry() {
        let m = makeModel()
        XCTAssertEqual(m.save(id: "u.old", name: "Old", body: "a"), .ok)
        // Edit it, renaming the id.
        XCTAssertEqual(m.save(id: "u.new", name: "New", body: "a", editingID: "u.old"), .ok)
        XCTAssertEqual(m.userSnippets.count, 1, "renamed, not duplicated")
        XCTAssertEqual(m.userSnippets[0].id, "u.new")
    }

    func test_save_invalid_doesNotPersist() {
        let m = makeModel()
        XCTAssertEqual(m.save(id: "u.x", name: "", body: "b"), .emptyName)
        XCTAssertTrue(m.userSnippets.isEmpty)
    }

    func test_delete_removesUserSnippet() {
        let m = makeModel()
        _ = m.save(id: "u.del", name: "Del", body: "a")
        XCTAssertTrue(m.delete(id: "u.del"))
        XCTAssertTrue(m.userSnippets.isEmpty)
    }

    func test_delete_builtIn_isNoOp() {
        let m = makeModel()
        XCTAssertFalse(m.delete(id: "md.table"), "no user entry to remove")
        XCTAssertEqual(m.allSnippets.count, SnippetLibrary.builtIns.count,
                       "built-in stays")
    }

    // MARK: - Search / preview / insert candidate (TSK-1461)

    func test_filtered_emptyQuery_returnsAllInMergedOrder() {
        let m = makeModel()
        XCTAssertEqual(m.filtered(query: "").map(\.id), m.allSnippets.map(\.id))
        XCTAssertEqual(m.filtered(query: "   ").map(\.id), m.allSnippets.map(\.id),
                       "whitespace-only query is an empty query")
    }

    func test_filtered_matchesName_caseInsensitively() {
        let m = makeModel()
        _ = m.save(id: "u.greet", name: "Greeting Block", body: "hello $0")
        let hits = m.filtered(query: "greeting")
        XCTAssertEqual(hits.map(\.id), ["u.greet"])
    }

    func test_filtered_matchesID() {
        let m = makeModel()
        _ = m.save(id: "u.zzz.unique", name: "Something", body: "x")
        XCTAssertEqual(m.filtered(query: "ZZZ.UNI").map(\.id), ["u.zzz.unique"])
    }

    func test_filtered_matchesBody() {
        let m = makeModel()
        _ = m.save(id: "u.fm", name: "Front Matter", body: "---\ntitle: $1\n---\n$0")
        // Find by remembered CONTENT, not name.
        XCTAssertTrue(m.filtered(query: "title:").map(\.id).contains("u.fm"))
    }

    func test_filtered_noMatch_returnsEmpty() {
        XCTAssertTrue(makeModel().filtered(query: "no-such-snippet-xyzzy").isEmpty)
    }

    func test_insertCandidate_selectedRowWins_whenItSurvivesFilter() {
        let m = makeModel()
        _ = m.save(id: "u.a", name: "Alpha note", body: "a")
        _ = m.save(id: "u.b", name: "Beta note", body: "b")
        // Both match "note"; the explicitly selected row is the candidate.
        XCTAssertEqual(m.insertCandidate(query: "note", selectedID: "u.b")?.id, "u.b")
    }

    func test_insertCandidate_fallsBackToFirstMatch_whenSelectionFilteredOut() {
        let m = makeModel()
        _ = m.save(id: "u.a", name: "Alpha note", body: "a")
        _ = m.save(id: "u.b", name: "Beta note", body: "b")
        // Selection doesn't match the query → first filtered match wins
        // (the type-to-filter → Return flow).
        XCTAssertEqual(m.insertCandidate(query: "alpha", selectedID: "u.b")?.id, "u.a")
    }

    func test_insertCandidate_nilWhenNothingMatches() {
        XCTAssertNil(makeModel().insertCandidate(query: "xyzzy-no-match", selectedID: nil))
    }

    func test_insertCandidate_emptyQuery_noSelection_isFirstSnippet() {
        let m = makeModel()
        XCTAssertEqual(m.insertCandidate(query: "", selectedID: nil)?.id,
                       m.allSnippets.first?.id)
    }

    func test_previewText_stripsPlaceholderMarkup_keepsDefaults() {
        XCTAssertEqual(
            SnippetManagerModel.previewText(body: "Hello ${1:World}$0!"),
            "Hello World!")
        XCTAssertEqual(
            SnippetManagerModel.previewText(body: "plain text"), "plain text")
    }

    func test_previewText_matchesRealInsertPath() {
        // The preview MUST be the same text the insert path produces —
        // preview/insert drift is the bug this pins.
        for snip in SnippetLibrary.builtIns {
            XCTAssertEqual(SnippetManagerModel.previewText(body: snip.body),
                           snip.parsed.plainText, snip.id)
        }
    }

    func test_tabStopSummary_wording() {
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "plain"), "No tab stops")
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "x$0"), "Final caret only")
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "$1"), "1 tab stop")
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "$1 and $0"),
                       "1 tab stop + final caret")
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "${1:a} $2"), "2 tab stops")
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "${1:a} $2 $0"),
                       "2 tab stops + final caret")
        // Repeated occurrences of the same stop count once.
        XCTAssertEqual(SnippetManagerModel.tabStopSummary(body: "$1 $1 $1"), "1 tab stop")
    }

    func test_persistence_roundTrips() {
        let url = tmpDir.appendingPathComponent("rt.json")
        let store1 = SnippetStore(storeURL: url)
        let m1 = SnippetManagerModel(store: store1)
        _ = m1.save(id: "u.persist", name: "Persist", body: "hi $0")
        store1.flush()
        // A fresh store over the same file sees the user snippet.
        let m2 = SnippetManagerModel(store: SnippetStore(storeURL: url))
        XCTAssertEqual(m2.userSnippets.map(\.id), ["u.persist"])
    }
}
