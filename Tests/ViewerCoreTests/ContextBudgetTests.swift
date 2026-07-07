import XCTest

/// Context-budget guard (2026-07-03). These files are loaded into EVERY agent
/// session's context (CLAUDE.md always; HANDOFF.md re-injected wholesale by the
/// post-compaction hook). Unbounded growth is a permanent per-session token tax
/// — a 76 KB HANDOFF cost ~19k tokens per compaction before this guard.
/// HANDOFF.md is CURRENT STATE, not a session log: history belongs in git log,
/// the board, and the docs. If this test is red, PRUNE the file — do not bump
/// the budget without an owner decision (same rule as the bundle-size cap).
final class ContextBudgetTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/ViewerCoreTests/ContextBudgetTests.swift
            .deletingLastPathComponent()          // …/Tests/ViewerCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // repo root
    }

    private func byteSize(_ name: String) throws -> Int {
        let url = repoRoot.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return data.count
    }

    func test_handoff_isStateNotLog_underBudget() throws {
        // Mirrors the hook's truncation budget (handoff-reinject.sh budget_bytes).
        let size = try byteSize("HANDOFF.md")
        XCTAssertLessThanOrEqual(size, 12_000,
            "HANDOFF.md is \(size) B (> 12 KB). It is re-injected into context after every "
            + "compaction — keep it CURRENT STATE ONLY and move history to git/board/docs.")
    }

    func test_handoff_carriesTheManagedMarker() throws {
        let url = repoRoot.appendingPathComponent("HANDOFF.md")
        let firstLine = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "<!-- CLAUDE-HANDOFF v1 -->",
            "the re-inject hook only recognizes the managed marker; without it the "
            + "post-compaction restore silently stops working")
    }

    func test_projectClaudeMd_underBudget() throws {
        // Loaded into EVERY session. Current ~36 KB; cap at 40 KB pending the
        // planned rules-vs-history restructure (then ratchet DOWN, never up).
        let size = try byteSize("CLAUDE.md")
        XCTAssertLessThanOrEqual(size, 40_000,
            "CLAUDE.md is \(size) B (> 40 KB). Keep rules crisp; move narrative/rationale "
            + "to docs/ (LESSONS.md / DIRECTIVES_HISTORY).")
    }

    func test_autonomousProgress_rotated_underBudget() throws {
        // TSK-1548: the progress log hit 15k lines (1.46 MB) — 17% of ALL
        // commits were appends to it, and every autonomous firing re-reads it.
        // Rotation policy: a red here means MOVE the older LOG entries to
        // archive/AUTONOMOUS_PROGRESS_<range>.md (keep DECISIONS + the recent
        // entries) — never bump the budget.
        let size = try byteSize("docs/AUTONOMOUS_PROGRESS.md")
        XCTAssertLessThanOrEqual(size, 64_000,
            "docs/AUTONOMOUS_PROGRESS.md is \(size) B (> 64 KB) — ROTATE it "
            + "(see the file's rotation note; history goes to archive/).")
    }
}
