import Testing
@testable import ViewerCore

/// TSK-1572 — the new-tab launchpad's pure model cores: git-clone plan, keyboard
/// selection state machine, and section splitting.
struct LaunchpadModelTests {

    // MARK: - GitClonePlan

    @Test func clonePlan_bareForgePath_synthesizesHttps() {
        let p = GitClonePlan.make(fromRemote: "github.com/owner/repo", into: "/tmp/ws")
        #expect(p == GitClonePlan(cloneURL: "https://github.com/owner/repo",
                                  repoName: "repo", targetDirectory: "/tmp/ws/repo"))
    }

    @Test func clonePlan_httpsDotGit_stripsGitFromName() {
        let p = GitClonePlan.make(fromRemote: "https://gitlab.com/o/proj.git", into: "/tmp/ws/")
        #expect(p?.repoName == "proj")
        #expect(p?.cloneURL == "https://gitlab.com/o/proj.git")   // scheme passed through
        #expect(p?.targetDirectory == "/tmp/ws/proj")             // trailing slash normalized
    }

    @Test func clonePlan_scpStyle_passesThrough_andDerivesName() {
        let p = GitClonePlan.make(fromRemote: "git@github.com:o/thing.git", into: "/w")
        #expect(p?.cloneURL == "git@github.com:o/thing.git")
        #expect(p?.repoName == "thing")
        #expect(p?.targetDirectory == "/w/thing")
    }

    @Test func clonePlan_nilWhenNoRepoName() {
        #expect(GitClonePlan.make(fromRemote: "   ", into: "/w") == nil)
        #expect(GitClonePlan.make(fromRemote: "github.com/", into: "/w") == nil)
    }

    // MARK: - LaunchpadSelection (keyboard nav)

    @Test func selection_downFromOmni_landsOnFirstRow_thenClamps() {
        var s = LaunchpadSelection(rowCount: 2)
        #expect(s.isOmniFocused)
        s.moveDown(); #expect(s.selectedRow == 0)
        s.moveDown(); #expect(s.selectedRow == 1)
        s.moveDown(); #expect(s.selectedRow == 1)   // clamp at last
    }

    @Test func selection_upFromFirstRow_returnsToOmni_thenStays() {
        var s = LaunchpadSelection(rowCount: 3, selectedRow: 1)
        s.moveUp(); #expect(s.selectedRow == 0)
        s.moveUp(); #expect(s.isOmniFocused)        // row 0 → omni
        s.moveUp(); #expect(s.isOmniFocused)        // stays at the top
    }

    @Test func selection_noRows_downIsNoOp() {
        var s = LaunchpadSelection(rowCount: 0)
        s.moveDown(); #expect(s.isOmniFocused)
    }

    @Test func selection_reclamp_afterListShrinks() {
        let s = LaunchpadSelection(rowCount: 5, selectedRow: 4)
        #expect(s.reclamped(toRowCount: 2).selectedRow == 1)   // clamp into new range
        #expect(s.reclamped(toRowCount: 0).isOmniFocused)      // list emptied → omni
    }

    // MARK: - LaunchpadSections

    private func item(_ name: String, dir: Bool = false) -> LaunchpadSections.Item {
        LaunchpadSections.Item(title: name, path: "/p/\(name)", isDirectory: dir)
    }

    @Test func sections_splitRecentsIntoFilesAndFolders_plusBookmarks() {
        let recents = [item("a.md"), item("proj", dir: true), item("b.txt"), item("docs", dir: true)]
        let bookmarks = [item("fav.md")]
        let out = LaunchpadSections.build(recents: recents, bookmarks: bookmarks)
        #expect(out.map(\.title) == ["Recent Files", "Recent Folders", "Bookmarks"])
        #expect(out[0].items.map(\.title) == ["a.md", "b.txt"])
        #expect(out[1].items.map(\.title) == ["proj", "docs"])
        #expect(out[2].items.map(\.title) == ["fav.md"])
    }

    @Test func sections_omitEmpty_dedupByPath_capAtLimit() {
        let recents = [item("a.md"), item("a.md"), item("b.md"), item("c.md")]   // dupe a.md
        let out = LaunchpadSections.build(recents: recents, bookmarks: [], limit: 2)
        #expect(out.map(\.title) == ["Recent Files"])          // no folders / bookmarks → omitted
        #expect(out[0].items.map(\.title) == ["a.md", "b.md"]) // deduped + capped at 2
    }

    @Test func sections_flatItems_concatenatesInOrder() {
        let out = LaunchpadSections.build(
            recents: [item("a.md"), item("d", dir: true)], bookmarks: [item("bm.md")])
        #expect(LaunchpadSections.flatItems(out).map(\.title) == ["a.md", "d", "bm.md"])
    }
}
