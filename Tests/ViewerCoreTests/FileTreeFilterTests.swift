import XCTest
@testable import ViewerCore

/// Teeth for `FileTreeFilter` (TSK-310) — the ancestor/subtree-preserving
/// narrowing behind the Files-pane inline filter row. Pure traversal; matching
/// is injected, so these tests pin the visibility rule (matches + subtree of a
/// match + ancestor chain to a match) independent of any fuzzy scorer or UI.
final class FileTreeFilterTests: XCTestCase {

    /// Minimal value tree for the model tests — id is the path, name is the leaf.
    private struct Node {
        let name: String
        let children: [Node]
        init(_ name: String, _ children: [Node] = []) {
            self.name = name
            self.children = children
        }
    }

    /// src/{app/{main.swift, util.swift}, README.md}, docs/{guide.md}
    private func sampleTree() -> [Node] {
        [
            Node("src", [
                Node("app", [Node("main.swift"), Node("util.swift")]),
                Node("README.md"),
            ]),
            Node("docs", [Node("guide.md")]),
        ]
    }

    /// ids must be unique across the tree, but a node only knows its own leaf
    /// name — so build a path-tagged mirror (id = full slash-path) and filter
    /// that. This keeps the model under test pure while giving collision-free ids.
    private struct Tagged { let id: String; let name: String; let children: [Tagged] }
    private func tag(_ n: Node, _ prefix: String) -> Tagged {
        let p = prefix.isEmpty ? n.name : prefix + "/" + n.name
        return Tagged(id: p, name: n.name, children: n.children.map { tag($0, p) })
    }

    private func visibleTagged(_ needle: String) -> Set<String> {
        let roots = sampleTree().map { tag($0, "") }
        return FileTreeFilter.visibleIDs(
            roots: roots,
            id: { $0.id },
            children: { $0.children },
            isMatch: { $0.name.lowercased().contains(needle.lowercased()) }
        )
    }

    func test_leafMatch_keepsLeafAndAncestorChainOnly() {
        // "util" matches only src/app/util.swift → keep it + app + src.
        let v = visibleTagged("util")
        XCTAssertEqual(v, ["src", "src/app", "src/app/util.swift"])
        // siblings of the match are NOT kept.
        XCTAssertFalse(v.contains("src/app/main.swift"))
        XCTAssertFalse(v.contains("docs"))
    }

    func test_folderMatch_keepsWholeSubtree() {
        // "app" matches the src/app folder → keep app AND its whole subtree,
        // plus the ancestor src.
        let v = visibleTagged("app")
        XCTAssertTrue(v.isSuperset(of: [
            "src", "src/app", "src/app/main.swift", "src/app/util.swift",
        ]), "matched folder reveals its full subtree: \(v)")
        // README.md (sibling under src, no match, not under app) is excluded.
        XCTAssertFalse(v.contains("src/README.md"))
        XCTAssertFalse(v.contains("docs"))
    }

    func test_extensionMatch_acrossBranches() {
        // ".md" matches README.md and guide.md in different branches.
        let v = visibleTagged(".md")
        XCTAssertEqual(v, [
            "src", "src/README.md",
            "docs", "docs/guide.md",
        ])
    }

    func test_noMatch_isEmpty() {
        XCTAssertTrue(visibleTagged("zzzz").isEmpty)
    }

    func test_rootMatch_keepsEverythingUnderIt() {
        // "src" matches the root folder → its entire subtree is visible; docs is not.
        let v = visibleTagged("src")
        XCTAssertEqual(v, [
            "src", "src/app", "src/app/main.swift", "src/app/util.swift", "src/README.md",
        ])
    }

    func test_emptyRoots_isEmpty() {
        let empty: [Tagged] = []
        let v = FileTreeFilter.visibleIDs(
            roots: empty, id: { $0.id }, children: { $0.children }, isMatch: { _ in true }
        )
        XCTAssertTrue(v.isEmpty)
    }

    func test_matchEverything_keepsAllIDs() {
        // Explicit match-all predicate (Swift's `"x".contains("")` is false, so an
        // empty needle is NOT match-all — the caller treats empty query as "no
        // filter" upstream and never calls this).
        let roots = sampleTree().map { tag($0, "") }
        let v = FileTreeFilter.visibleIDs(
            roots: roots, id: { $0.id }, children: { $0.children }, isMatch: { _ in true }
        )
        XCTAssertEqual(v.count, 7, "all 7 nodes kept when every node matches: \(v)")
    }
}
