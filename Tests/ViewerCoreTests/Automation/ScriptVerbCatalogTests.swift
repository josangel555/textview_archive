import XCTest
@testable import ViewerCore

/// Tests for `ScriptVerbCatalog` (TSK-799) — the programmatic inventory of
/// the `--script` / palette verb vocabulary.
///
/// The marquee test (`testCatalogMatchesDispatchSwitch`) is the teeth that
/// keeps the catalog (and therefore the scripting documentation it backs)
/// honest: it parses the actual `case "…":` labels out of
/// `ScriptVerbDispatch.swift` and asserts the catalog enumerates exactly
/// the same set. Add a verb to the switch without a catalog row → red. Add
/// a catalog row without a switch case → red.
final class ScriptVerbCatalogTests: XCTestCase {

    // MARK: - Self-consistency (pure, no source-file dependency)

    func testTokensAreUnique() {
        let tokens = ScriptVerbCatalog.all.map(\.token)
        XCTAssertEqual(tokens.count, Set(tokens).count,
                       "duplicate verb token(s) in ScriptVerbCatalog.all")
    }

    func testLookupRoundTrips() {
        for verb in ScriptVerbCatalog.all {
            XCTAssertEqual(ScriptVerbCatalog.verb(verb.token)?.token, verb.token)
        }
        XCTAssertNil(ScriptVerbCatalog.verb("definitely-not-a-verb"))
    }

    func testTokensSetMatchesAll() {
        XCTAssertEqual(ScriptVerbCatalog.tokens,
                       Set(ScriptVerbCatalog.all.map(\.token)))
    }

    func testGroupedCoversEveryVerbExactlyOnce() {
        let grouped = ScriptVerbCatalog.grouped()
        let flattened = grouped.flatMap { $0.verbs }
        XCTAssertEqual(flattened.count, ScriptVerbCatalog.all.count,
                       "grouped() dropped or duplicated verbs")
        XCTAssertEqual(Set(flattened.map(\.token)), ScriptVerbCatalog.tokens)
        // Surfaces are emitted in declaration order.
        let surfaces = grouped.map(\.surface)
        XCTAssertEqual(surfaces, surfaces.sorted())
    }

    func testEverySummaryIsNonEmpty() {
        for verb in ScriptVerbCatalog.all {
            XCTAssertFalse(verb.summary.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(verb.token) has an empty summary")
        }
    }

    /// A few representative verbs carry the right surface + arg shape, so a
    /// careless edit to a row is caught (not just the set-equality check).
    func testRepresentativeRows() {
        XCTAssertEqual(ScriptVerbCatalog.verb("open")?.surface, .files)
        XCTAssertEqual(ScriptVerbCatalog.verb("open")?.arg, .path)
        XCTAssertEqual(ScriptVerbCatalog.verb("select-tab")?.arg, .int)
        XCTAssertEqual(ScriptVerbCatalog.verb("toggle-view")?.arg, ScriptVerbCatalog.ArgShape.none)
        XCTAssertEqual(ScriptVerbCatalog.verb("set-theme")?.arg, .string)
        XCTAssertEqual(ScriptVerbCatalog.verb("open-as")?.arg, .structured)
        XCTAssertEqual(ScriptVerbCatalog.verb("tools.uuid")?.surface, .tools)
        XCTAssertEqual(ScriptVerbCatalog.verb("delay")?.surface, .harness)
    }

    // MARK: - Drift detection vs the real dispatch switch (the teeth)

    /// Parse the `case "<verb>":` labels out of `ScriptVerbDispatch.swift`
    /// and assert the catalog enumerates exactly that set. This is what
    /// keeps the catalog (and the scripting docs) from rotting against the
    /// runtime switch.
    func testCatalogMatchesDispatchSwitch() throws {
        guard let source = Self.dispatchSwitchSource() else {
            throw XCTSkip("ScriptVerbDispatch.swift not reachable from this run")
        }
        let switchVerbs = Self.topLevelCaseLabels(in: source)
        XCTAssertFalse(switchVerbs.isEmpty,
                       "parsed zero verbs from the dispatch switch — parser broke")

        let catalogVerbs = ScriptVerbCatalog.tokens

        let missingFromCatalog = switchVerbs.subtracting(catalogVerbs).sorted()
        let extraInCatalog = catalogVerbs.subtracting(switchVerbs).sorted()

        XCTAssertTrue(missingFromCatalog.isEmpty,
                      "verbs in ScriptVerbDispatch.swift but NOT in ScriptVerbCatalog: \(missingFromCatalog)")
        XCTAssertTrue(extraInCatalog.isEmpty,
                      "verbs in ScriptVerbCatalog but NOT in ScriptVerbDispatch.swift: \(extraInCatalog)")
    }

    // MARK: - Helpers

    /// Locate + read `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift`
    /// relative to this test file. Returns nil if it can't be found (so the
    /// drift test self-skips rather than failing on an installed-bundle run
    /// where the source tree isn't present).
    private static func dispatchSwitchSource() -> String? {
        // #filePath: …/Tests/ViewerCoreTests/Automation/ScriptVerbCatalogTests.swift
        // repo root is four ancestors up.
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()   // Automation
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let dispatch = repoRoot
            .appendingPathComponent("Sources/ViewerUI/Automation/ScriptVerbDispatch.swift")
        return try? String(contentsOf: dispatch, encoding: .utf8)
    }

    /// Extract the verb tokens from the dispatch switch.
    ///
    /// Only the TOP-LEVEL `switch cmd` arms are verbs. The nested
    /// `confirm-dirty-close` switch over `arg` (`case "save"`,
    /// `case "discard"`, `case "cancel"`) and `folder-stats`'
    /// `case "on"/"off"` are argument literals, NOT verbs — they are
    /// excluded by an allowlist so the parser stays a pure lexical match
    /// without needing brace-depth tracking.
    private static func topLevelCaseLabels(in source: String) -> Set<String> {
        // Arg-literal `case "…"` labels that live inside nested switches,
        // not the top-level verb switch.
        let argLiterals: Set<String> = ["save", "discard", "cancel", "on", "off"]
        var verbs: Set<String> = []
        // Match one or more comma-separated quoted labels on a `case` line:
        //   case "git-log-click", "git-log-cmd-click", "git-log-shift-click":
        let lineRegex = try! NSRegularExpression(
            pattern: #"^\s*case\s+("[a-zA-Z][a-zA-Z0-9.\-]*"(?:\s*,\s*"[a-zA-Z][a-zA-Z0-9.\-]*")*)\s*:"#)
        let tokenRegex = try! NSRegularExpression(pattern: #""([a-zA-Z][a-zA-Z0-9.\-]*)""#)
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let full = NSRange(line.startIndex..., in: line)
            guard lineRegex.firstMatch(in: line, range: full) != nil else { continue }
            tokenRegex.enumerateMatches(in: line, range: full) { m, _, _ in
                guard let m, let r = Range(m.range(at: 1), in: line) else { return }
                let token = String(line[r])
                if !argLiterals.contains(token) { verbs.insert(token) }
            }
        }
        return verbs
    }
}
