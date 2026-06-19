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
