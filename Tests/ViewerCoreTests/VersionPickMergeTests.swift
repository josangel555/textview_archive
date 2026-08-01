import Testing
@testable import ViewerCore

/// I-08 — `VersionPickMerge`: synthesizes a pickable region set from a 2-way
/// diff of (current, version) so the 3-pane picker offers per-hunk
/// keep-current vs take-version. Pins the region shapes and the resolution
/// round-trips (all-theirs == version, all-ours == current, mixed picks).
struct VersionPickMergeTests {

    @Test func identicalTexts_yieldNil() {
        #expect(VersionPickMerge.regions(current: "a\nb\n", version: "a\nb\n") == nil)
        #expect(VersionPickMerge.regions(current: "", version: "") == nil)
    }

    @Test func changedRun_becomesAPickableConflict_withCurrentAsOursAndBase() throws {
        let cur = "keep\nold-1\nold-2\ntail\n"
        let ver = "keep\nnew-1\ntail\n"
        let result = try #require(VersionPickMerge.regions(current: cur, version: ver))
        #expect(result.conflictCount == 1)
        let c = try #require(result.conflicts.first)
        #expect(c.ours == ["old-1", "old-2"], "ours = the CURRENT run")
        #expect(c.base == c.ours, "base mirrors current so 'base' never invents text")
        #expect(c.theirs == ["new-1"], "theirs = the VERSION's run")
    }

    @Test func allTheirs_reconstructsTheVersion_exactly() throws {
        let cur = "a\nb\nc\nd\n"
        let ver = "a\nB\nc\nD-1\nD-2\n"
        let result = try #require(VersionPickMerge.regions(current: cur, version: ver))
        let picks = Array(repeating: ThreeWayMerge.Resolution.theirs,
                          count: result.conflictCount)
        #expect(result.resolvedText(picks) == ver,
                "taking every version hunk must reproduce the version byte-for-byte")
    }

    @Test func allOurs_keepsTheCurrentText_exactly() throws {
        let cur = "a\nb\nc\n"
        let ver = "a\nX\nc\nY\n"
        let result = try #require(VersionPickMerge.regions(current: cur, version: ver))
        let picks = Array(repeating: ThreeWayMerge.Resolution.ours,
                          count: result.conflictCount)
        #expect(result.resolvedText(picks) == cur,
                "keeping every current hunk must leave the text untouched")
    }

    @Test func mixedPicks_takeOnlyTheChosenHunks() throws {
        // Two independent hunks: line 2 changed, and a trailing block added.
        let cur = "head\nmine\ntail\n"
        let ver = "head\ntheirs\ntail\nrecovered-1\nrecovered-2\n"
        let result = try #require(VersionPickMerge.regions(current: cur, version: ver))
        #expect(result.conflictCount == 2)
        // Keep MY middle line, take THEIR recovered trailing block — the exact
        // live-incident shape (bring back lost lines, keep newer edits).
        #expect(result.resolvedText([.ours, .theirs])
                == "head\nmine\ntail\nrecovered-1\nrecovered-2\n")
    }

    @Test func insertionOnlyHunk_hasEmptyOursSide() throws {
        let cur = "a\nb\n"
        let ver = "a\ninserted\nb\n"
        let result = try #require(VersionPickMerge.regions(current: cur, version: ver))
        let c = try #require(result.conflicts.first)
        #expect(c.ours.isEmpty, "pure insertion: current contributes nothing")
        #expect(c.theirs == ["inserted"])
        #expect(result.resolvedText([.theirs]) == ver)
        #expect(result.resolvedText([.ours]) == cur)
    }
}
