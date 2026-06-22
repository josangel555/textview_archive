import XCTest
import Foundation

/// TSK-1230 (TSK-1098 follow-up) — DRIFT GUARD for the bundle-cap figures.
///
/// `scripts/check-bundle-size.sh` is the single source of truth for the bundle
/// caps (its header even says the defaults "MUST match the numbers in" the docs),
/// but nothing ENFORCED that — so the doc-vs-script figures drifted TWICE
/// (TSK-194 synced them to 48/26, then the script was raised to 80/60 and the
/// docs lagged again = TSK-1098), each caught only by manual review. This test
/// parses the script's `BUDGET_MB` / `EXEC_BUDGET_MB` defaults and asserts the
/// policy docs (CLAUDE.md, README.md) state the same numbers, so the next drift
/// fails the headless gate instead of waiting for a human to notice. Pure file
/// read + regex — host-safe, no module dependency. (Pattern: InfoPlistTests'
/// `#filePath` repo-root walk.)
final class BundleCapDocSyncTests: XCTestCase {

    /// repo root = .../Tests/ViewerCoreTests/<thisFile> → up three.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    /// First capture group of `pattern` in `text`, or nil.
    private func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let g = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[g])
    }

    func test_docsBundleCapsMatchScriptDefaults() throws {
        let script = try read("scripts/check-bundle-size.sh")
        // BUDGET_MB="${BUDGET_MB:-${1:-80}}" — the inner ${1:-N} default.
        let budget = try XCTUnwrap(firstGroup(#"\$\{1:-(\d+)\}"#, in: script),
            "could not parse the BUDGET_MB default from scripts/check-bundle-size.sh")
        // EXEC_BUDGET_MB="${EXEC_BUDGET_MB:-60}"
        let exec = try XCTUnwrap(firstGroup(#"EXEC_BUDGET_MB:-(\d+)\}"#, in: script),
            "could not parse the EXEC_BUDGET_MB default from scripts/check-bundle-size.sh")

        // Sanity floor: these are the live values (a parse regression trips here too).
        XCTAssertEqual(budget, "80", "BUDGET_MB default changed — update the docs + this expectation")
        XCTAssertEqual(exec, "60", "EXEC_BUDGET_MB default changed — update the docs + this expectation")

        // The actual guard: every policy doc must state the enforced numbers.
        for doc in ["CLAUDE.md", "README.md"] {
            let text = try read(doc)
            XCTAssertTrue(text.contains("\(budget) MB total"),
                "\(doc) must state the total bundle cap as '\(budget) MB total' to match "
                + "check-bundle-size.sh (BUDGET_MB=\(budget)); doc-vs-script drift recurred twice — "
                + "sync the doc when the script default changes")
            XCTAssertTrue(text.contains("\(exec) MB"),
                "\(doc) must state the exec sub-cap '\(exec) MB' to match EXEC_BUDGET_MB=\(exec)")
        }
    }
}
