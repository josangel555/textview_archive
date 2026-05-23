import XCTest
@testable import ViewerUI

/// String-snapshot pin-test: the body of `SearchAnywhereSection.swift`
/// contains exactly zero `Divider()` calls. An inner `Divider()`
/// between the search field and the result list was the spurious
/// "extra line under SEARCH ANYWHERE" the user reported — it's gone,
/// and the only visible horizontal line below the section is the
/// `ResizableSectionDivider` injected by `SidebarView` between this
/// section and the next.
///
/// Brittle (depends on source-file shape) but catches future
/// regressions: if a contributor re-adds `Divider()` inside the
/// section body, this test fails and steers them toward an explicit
/// "did you mean to add another hairline?" conversation.
///
/// Filter with:
///   `swift test --filter ViewerUITests.SearchAnywhereSectionLayoutTests`
final class SearchAnywhereSectionLayoutTests: XCTestCase {

    /// Resolves the on-disk path to `SearchAnywhereSection.swift`
    /// from the test bundle's location, walking up to the repo root.
    /// `#filePath` is the test file itself — its parent is
    /// `Tests/ViewerUITests`, so the target source lives three
    /// `deletingLastPathComponent` hops up, then back down into
    /// `Sources/ViewerUI`.
    private func sourceContents() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()  // ViewerUITests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo root>
        let target = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ViewerUI")
            .appendingPathComponent("SearchAnywhereSection.swift")
        return try String(contentsOf: target, encoding: .utf8)
    }

    /// Counts occurrences of `Divider()` as a standalone token
    /// (whitespace-anchored, paren-anchored) so substring hits inside
    /// `ResizableSectionDivider`, doc comments mentioning the word, or
    /// type names like `FileMatches` don't accidentally inflate the
    /// count.
    private func countDividerCalls(in source: String) -> Int {
        var count = 0
        source.enumerateLines { line, _ in
            // Skip doc-comment lines: those mention `Divider()` in
            // prose. A real call is preceded only by whitespace.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") {
                return
            }
            // Tokenise on `Divider()` and check the preceding char
            // isn't an identifier continuation (e.g. the `Divider` in
            // `ResizableSectionDivider()`).
            var search = line[...]
            while let range = search.range(of: "Divider()") {
                let lower = range.lowerBound
                if lower == line.startIndex {
                    count += 1
                } else {
                    let prevIdx = line.index(before: lower)
                    let prev = line[prevIdx]
                    let isIdentChar = prev.isLetter || prev.isNumber || prev == "_"
                    if !isIdentChar { count += 1 }
                }
                search = line[range.upperBound...]
            }
        }
        return count
    }

    func test_searchAnywhereSection_hasZeroDividerCalls() throws {
        let source = try sourceContents()
        let count = countDividerCalls(in: source)
        XCTAssertEqual(count, 0,
            """
            Expected exactly 0 `Divider()` calls in \
            SearchAnywhereSection.swift — the only horizontal line \
            below this section should be the `ResizableSectionDivider` \
            owned by `SidebarView`. Found \(count). If you intend to \
            reintroduce an inner divider, update this test with a \
            rationale.
            """
        )
    }

    /// Sanity check on the counter itself: substrings like
    /// `ResizableSectionDivider` (which contain the word "Divider" but
    /// are not `Divider()` calls) must not inflate the count.
    func test_counter_ignoresIdentifierSubstringMatches() {
        let fake = """
        struct Foo {
            var a: ResizableSectionDivider
            // Divider() is fine in comments
            /// Also fine in doc comments: Divider()
        }
        """
        XCTAssertEqual(countDividerCalls(in: fake), 0)
    }

    func test_counter_picksUpRealCall() {
        let fake = """
        VStack {
            Text("hi")
            Divider()
            Text("there")
        }
        """
        XCTAssertEqual(countDividerCalls(in: fake), 1)
    }
}
