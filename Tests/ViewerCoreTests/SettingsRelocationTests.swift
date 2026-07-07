import XCTest
@testable import ViewerCore

/// TSK-1169 — the settings-relocation migration plan + backward-read.
final class SettingsRelocationTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")

    private func newFile(_ f: String) -> URL {
        SettingsRelocation.newRoot(home: home).appendingPathComponent(f)
    }
    private func oldFile(_ f: String) -> URL {
        SettingsRelocation.legacyRoot(home: home).appendingPathComponent(f)
    }

    func test_roots() {
        XCTAssertEqual(SettingsRelocation.newRoot(home: home).path, "/Users/tester/.textview")
        XCTAssertEqual(SettingsRelocation.legacyRoot(home: home).path,
                       "/Users/tester/Library/Application Support/MarkdownViewer")
    }

    func test_plan_movesLegacyOnlyFiles() {
        // bookmarks exists in legacy only → move; history exists in BOTH →
        // skip (never clobber the new one); recent-paths in neither → skip.
        let present: Set<String> = [
            oldFile("bookmarks.json").path,
            oldFile("history.json").path,
            newFile("history.json").path,
        ]
        let plan = SettingsRelocation.migrationPlan(home: home) { present.contains($0.path) }
        XCTAssertEqual(plan.map(\.file), ["bookmarks.json"])
        XCTAssertEqual(plan[0].from, oldFile("bookmarks.json"))
        XCTAssertEqual(plan[0].to, newFile("bookmarks.json"))
    }

    func test_plan_emptyWhenNothingLegacy() {
        XCTAssertTrue(SettingsRelocation.migrationPlan(home: home) { _ in false }.isEmpty)
        // All already in new → nothing to move.
        let allNew = Set(SettingsRelocation.relocatableFiles.map { newFile($0).path })
        XCTAssertTrue(SettingsRelocation.migrationPlan(home: home) { allNew.contains($0.path) }.isEmpty)
    }

    func test_readPath_prefersNew_thenLegacy_thenNewForFreshWrite() {
        // New present → read new.
        let newPresent: Set<String> = [newFile("bookmarks.json").path]
        XCTAssertEqual(
            SettingsRelocation.readPath(for: "bookmarks.json", home: home) { newPresent.contains($0.path) },
            newFile("bookmarks.json"))
        // Only legacy present → backward read from legacy.
        let oldPresent: Set<String> = [oldFile("bookmarks.json").path]
        XCTAssertEqual(
            SettingsRelocation.readPath(for: "bookmarks.json", home: home) { oldPresent.contains($0.path) },
            oldFile("bookmarks.json"))
        // Neither → default to the new location (a fresh write target).
        XCTAssertEqual(
            SettingsRelocation.readPath(for: "bookmarks.json", home: home) { _ in false },
            newFile("bookmarks.json"))
    }

    func test_relocatableFiles_areTheJSONStateFiles() {
        // UserDefaults prefs are NOT in the set (they stay in the defaults DB).
        XCTAssertTrue(SettingsRelocation.relocatableFiles.contains("bookmarks.json"))
        XCTAssertTrue(SettingsRelocation.relocatableFiles.allSatisfy { $0.hasSuffix(".json") })
    }
}
