import XCTest
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-282 (mode A) — the headless half of the sidebar fuzzy filter:
/// ranking through the ROUTED engine, match-index → glyph mapping, the
/// result cap, empty-query passthrough, and the §2.5 routing pin. The
/// typed-latency / highlight pixels are the live half (the ticket's
/// long-standing live-validation flag).
@MainActor
final class SidebarFilterTests: HeadlessUITestCase {

    private func row(_ name: String, dir: Bool = false) -> SidebarModel.VisibleRow {
        SidebarModel.VisibleRow(
            node: FileNode(
                url: URL(fileURLWithPath: "/tmp/fixture/\(name)"),
                name: name, isDirectory: dir),
            depth: 1)
    }

    func test_ranksAndMapsMatchedIndices() throws {
        let rows = [row("CHANGELOG.md"), row("main.rs"), row("README.md")]
        let out = SidebarFilter.filter(rows, query: "rs")
        // "main.rs" must rank first ('.rs' is a word-boundary suffix hit);
        // its matched indices must point at the 'r' and 's' glyphs.
        let top = try XCTUnwrap(out.first)
        XCTAssertEqual(top.display, "main.rs")
        let chars = Array(top.display)
        XCTAssertEqual(top.matchedIndices.map { String(chars[$0]) }, ["r", "s"],
                       "matched indices must address the matched glyphs")
        // Non-matching rows are dropped entirely.
        XCTAssertFalse(out.contains { $0.display == "CHANGELOG.md" }
                        && out.count == rows.count)
    }

    func test_emptyAndWhitespaceQueries_returnEmpty_treePassthrough() {
        let rows = [row("a.txt"), row("b.txt")]
        XCTAssertEqual(SidebarFilter.filter(rows, query: ""), [])
        XCTAssertEqual(SidebarFilter.filter(rows, query: "   "), [])
    }

    func test_resultCap_bounds_the_list() {
        let rows = (0..<(SidebarFilter.resultCap + 100)).map { row("match-\($0).txt") }
        let out = SidebarFilter.filter(rows, query: "match")
        XCTAssertEqual(out.count, SidebarFilter.resultCap,
                       "the match list must never exceed the render cap")
    }

    func test_directoriesKeepTheirFlag_forActivationSemantics() {
        let rows = [row("src", dir: true), row("src.txt")]
        let out = SidebarFilter.filter(rows, query: "src")
        XCTAssertEqual(out.first { $0.display == "src" }?.isDirectory, true)
        XCTAssertEqual(out.first { $0.display == "src.txt" }?.isDirectory, false)
    }

    // MARK: - Mode B (TSK-666): global find + descendant cache + reveal

    private func fixtureTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarFilterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("deep/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("top.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("deep/nested/treasure.rs"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("node_modules/pkg/index.js"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden/secret.txt"))
        return dir
    }

    func test_walkDescendants_skipsHeavyDirs_honorsHidden_buildsRelPaths() throws {
        let dir = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let visible = SidebarModel.walkDescendants(root: dir, includeHidden: false)
        let rels = Set(visible.map(\.relPath))
        XCTAssertTrue(rels.contains("top.txt"))
        XCTAssertTrue(rels.contains("deep/nested/treasure.rs"),
                      "collapsed-depth files must be in the global set")
        XCTAssertFalse(rels.contains { $0.hasPrefix("node_modules") },
                       "skip-set prunes machine-managed trees")
        XCTAssertFalse(rels.contains { $0.hasPrefix(".hidden") },
                       "hidden honored when includeHidden=false")
        let withHidden = SidebarModel.walkDescendants(root: dir, includeHidden: true)
        XCTAssertTrue(Set(withHidden.map(\.relPath)).contains(".hidden/secret.txt"),
                      "hidden included when includeHidden=true")
    }

    func test_filterGlobal_findsFilesInCollapsedBranches_rankedByRelPath() throws {
        let dir = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = SidebarModel.walkDescendants(root: dir, includeHidden: false)
        let out = SidebarFilter.filterGlobal(entries, query: "treasure")
        let top = try XCTUnwrap(out.first)
        XCTAssertEqual(top.display, "deep/nested/treasure.rs",
                       "mode B displays + ranks by the root-relative path")
        XCTAssertTrue(top.secondary.isEmpty, "relPath already carries the location")
    }

    func test_descendantsCache_buildsOffMain_andInvalidatesOnRootChange() async throws {
        let dir = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SidebarModel()
        model.setRoot(dir)
        XCTAssertNil(model.globalFindCandidates(), "unbuilt until demanded")
        model.ensureDescendantsCache()
        // Await the off-main build via the published version bump.
        for _ in 0..<200 where model.globalFindCandidates() == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entries = try XCTUnwrap(model.globalFindCandidates(),
                                    "build must complete and land on main")
        XCTAssertTrue(entries.contains { $0.relPath == "deep/nested/treasure.rs" })
        let version = model.descendantsVersion
        XCTAssertGreaterThan(version, 0, "completion bumps the published version")
        // Root change must drop the cache (the candidate set changed).
        model.setRoot(nil)
        XCTAssertNil(model.globalFindCandidates(),
                     "root change must invalidate the global-find cache")
    }

    func test_revealAncestors_expandsTheChain_soTheTreeShowsTheHit() throws {
        let dir = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SidebarModel()
        model.setRoot(dir)
        let target = dir.appendingPathComponent("deep/nested/treasure.rs")
        XCTAssertFalse(
            model.flatVisibleRows().contains { $0.node.name == "treasure.rs" },
            "collapsed by default")
        model.revealAncestors(of: target)
        XCTAssertTrue(
            model.flatVisibleRows().contains { $0.node.name == "treasure.rs" },
            "revealing the ancestors must surface the hit in the visible tree")
    }

    /// §2.5 routing pin: fuzzy is a PORTED engine — the filter must go
    /// through the adapter (rust by default), never grow a new direct
    /// consumer of the Swift twin. Source audit, the TSK-561 idiom.
    func test_filterRoutesTheAdapter_notTheSwiftTwin() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewerUI/SidebarFilter.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("RustFuzzyAdapter.filterWithMatches"),
                      "SidebarFilter must route the ported engine (TSK-633)")
        XCTAssertFalse(src.contains("FuzzyMatcher.filterWithMatches"),
                       "new feature code must not consume the Swift twin (§2.5)")
    }

    func test_fuzzyHighlight_boldsExactlyTheMatchedGlyphs() {
        let attr = FuzzyHighlight.attributed(
            "main.rs", matchedIndices: [5, 6], size: 12,
            regular: .primary, highlight: .accentColor)
        // Walk the runs: characters 5,6 ('r','s') carry the accent color.
        var idx = 0
        var highlighted: [Int] = []
        var cur = attr.startIndex
        while cur < attr.endIndex {
            let next = attr.characters.index(after: cur)
            if attr[cur..<next].foregroundColor == .accentColor {
                highlighted.append(idx)
            }
            cur = next
            idx += 1
        }
        XCTAssertEqual(highlighted, [5, 6],
                       "exactly the matched glyphs are accent-highlighted")
    }
}
