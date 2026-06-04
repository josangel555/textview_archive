import XCTest
@testable import ViewerCore

/// Host-safe (T1m) tests for `GitBranchSwitch.decide` — the pure dirty-gate
/// in front of the footer chip's branch checkout (UX-C, #225).
///
/// We NEVER spawn `git` or run a real `git checkout` here: the decision is a
/// pure transform over `git status --porcelain=v1` text, so every case is a
/// hand-built porcelain string. This pins the hard-gate contract — a dirty
/// tree must REFUSE, a clean tree may proceed — independent of any live repo.
final class GitBranchSwitchTests: XCTestCase {

    // MARK: - clean tree → allow

    func test_cleanTree_allows() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature", porcelainStatus: "")
        XCTAssertEqual(d, .allow)
        XCTAssertTrue(d.isSafeToCheckout)
    }

    func test_whitespaceOnlyStatus_isClean_allows() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature", porcelainStatus: "  \n\n \t\n")
        XCTAssertEqual(d, .allow)
    }

    // MARK: - dirty tree → refuse

    func test_modifiedFile_refuses() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature",
            porcelainStatus: " M Sources/Foo.swift\n")
        guard case let .refuse(_, count) = d else {
            return XCTFail("expected refuse, got \(d)")
        }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(d.isSafeToCheckout)
    }

    func test_multipleDirtyEntries_refuses_withCount() {
        let status = """
         M Sources/Foo.swift
        A  Sources/Bar.swift
        D  Sources/Baz.swift
        """
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature", porcelainStatus: status)
        guard case let .refuse(reason, count) = d else {
            return XCTFail("expected refuse, got \(d)")
        }
        XCTAssertEqual(count, 3)
        // The user-facing reason pluralizes + names the target.
        XCTAssertTrue(reason.contains("3 uncommitted changes"), reason)
        XCTAssertTrue(reason.contains("feature"), reason)
    }

    func test_singleDirty_usesSingularNoun() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature",
            porcelainStatus: " M one.txt\n")
        guard case let .refuse(reason, _) = d else {
            return XCTFail("expected refuse")
        }
        XCTAssertTrue(reason.contains("1 uncommitted change"), reason)
        XCTAssertFalse(reason.contains("changes"), reason)
    }

    /// Untracked files (`??`) make a checkout unsafe — the target branch may
    /// track a same-named file that git would clobber. They MUST count.
    func test_untrackedFile_countsAsDirty_refuses() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature",
            porcelainStatus: "?? scratch.tmp\n")
        guard case let .refuse(_, count) = d else {
            return XCTFail("expected refuse, got \(d)")
        }
        XCTAssertEqual(count, 1)
    }

    /// Ignored entries (`!!`) NEVER block a checkout — git leaves them be.
    func test_ignoredEntries_doNotBlock_allows() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "feature",
            porcelainStatus: "!! .build/\n!! node_modules/\n")
        XCTAssertEqual(d, .allow)
        XCTAssertEqual(
            GitBranchSwitch.dirtyEntryCount("!! .build/\n!! node_modules/\n"), 0)
    }

    func test_mixedIgnoredAndModified_countsOnlyTheModified() {
        let status = """
        !! .build/
         M src/app.swift
        !! node_modules/
        """
        XCTAssertEqual(GitBranchSwitch.dirtyEntryCount(status), 1)
    }

    // MARK: - no-op (already on branch)

    func test_alreadyOnTarget_isNoop_evenIfDirty() {
        // No-op short-circuits BEFORE the dirty check — staying put never
        // touches the tree, so a dirty tree is irrelevant.
        let d = GitBranchSwitch.decide(
            current: "main", target: "main",
            porcelainStatus: " M dirty.swift\n")
        XCTAssertEqual(d, .noop)
        XCTAssertTrue(d.isSafeToCheckout)
    }

    func test_detachedHead_neverNoop_dirtyStillRefuses() {
        let d = GitBranchSwitch.decide(
            current: nil, target: "main",
            porcelainStatus: " M dirty.swift\n")
        guard case .refuse = d else { return XCTFail("expected refuse") }
    }

    func test_detachedHead_cleanTree_allows() {
        let d = GitBranchSwitch.decide(
            current: nil, target: "main", porcelainStatus: "")
        XCTAssertEqual(d, .allow)
    }

    // MARK: - target validation (option-injection guard)

    func test_emptyTarget_refuses() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "   ", porcelainStatus: "")
        guard case let .refuse(_, count) = d else {
            return XCTFail("expected refuse")
        }
        XCTAssertEqual(count, 0)
    }

    func test_optionShapedTarget_refuses() {
        // A target starting with `-` would be parsed as a git flag.
        let d = GitBranchSwitch.decide(
            current: "main", target: "--force", porcelainStatus: "")
        guard case .refuse = d else {
            return XCTFail("expected refuse for option-shaped target")
        }
    }

    func test_targetTrimmed_matchesCurrent_isNoop() {
        let d = GitBranchSwitch.decide(
            current: "main", target: "  main  ", porcelainStatus: "")
        XCTAssertEqual(d, .noop)
    }

    // MARK: - dirtyEntryCount edge cases

    func test_dirtyEntryCount_skipsTooShortRows() {
        // A malformed 2-char row is skipped, not counted.
        XCTAssertEqual(GitBranchSwitch.dirtyEntryCount("M\n M ok.txt\n"), 1)
    }

    func test_dirtyEntryCount_renameRow_countsOnce() {
        XCTAssertEqual(
            GitBranchSwitch.dirtyEntryCount("R  old.txt -> new.txt\n"), 1)
    }
}
