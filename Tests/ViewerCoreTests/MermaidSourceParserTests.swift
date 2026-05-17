import XCTest
@testable import ViewerCore

final class MermaidSourceParserTests: XCTestCase {

    // MARK: - Step directives

    func test_parsesStepDirectives() {
        let src = """
        flowchart LR
          A --> B
        %% @step 1
          B --> C
        %% @step 2
          C --> D
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.steps.map(\.step), [1, 2])
        XCTAssertEqual(parsed.steps.map(\.line), [2, 4])
        XCTAssertNil(parsed.id)
    }

    func test_parsesIdDirective() {
        let src = """
        %% @id arch-overview
        flowchart LR
          A --> B
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.id, "arch-overview")
    }

    func test_parsesIdAndSteps() {
        let src = """
        %% @id pipeline
        flowchart LR
          A --> B
        %% @step 1
          B --> C
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.id, "pipeline")
        XCTAssertEqual(parsed.steps.count, 1)
        XCTAssertEqual(parsed.steps.first?.step, 1)
        XCTAssertEqual(parsed.steps.first?.line, 3)
    }

    func test_ignoresMalformedSteps() {
        // Non-integer, empty, negative — all rejected.
        let src = """
        %% @step foo
        %% @step
        %% @step -3
        %% @step 0
        flowchart LR
          A --> B
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.steps, [])
    }

    func test_rejectsNonDirectivePrefixCollision() {
        // `@steplabel` shouldn't match `@step`; `@idea` shouldn't match `@id`.
        let src = """
        %% @steplabel something
        %% @ideal world
        flowchart LR
          A --> B
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.steps, [])
        XCTAssertNil(parsed.id)
    }

    func test_allowsTabSeparator() {
        let src = "%% @step\t3\nflowchart LR\n  A --> B"
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.steps.map(\.step), [3])
    }

    func test_handlesEmptySource() {
        let parsed = MermaidSourceParser.parse("")
        XCTAssertNil(parsed.id)
        XCTAssertTrue(parsed.steps.isEmpty)
    }

    func test_ignoresInlineCommentsAfterCode() {
        // `%%` only matters at start of line (after trim). A trailing
        // `%%` on a code line is not a directive.
        let src = """
        flowchart LR
          A --> B   %% @step 1
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.steps, [])
    }

    func test_acceptsLeadingWhitespaceOnDirective() {
        let src = """
        flowchart LR
            %% @step 1
          A --> B
        """
        let parsed = MermaidSourceParser.parse(src)
        XCTAssertEqual(parsed.steps.map(\.step), [1])
        XCTAssertEqual(parsed.steps.map(\.line), [1])
    }

    // MARK: - Hash + JSON

    func test_hashIsStable() {
        let src = "flowchart LR\n  A --> B"
        XCTAssertEqual(MermaidSourceParser.shortHash(src),
                       MermaidSourceParser.shortHash(src))
    }

    func test_hashDiffersForDifferentSource() {
        XCTAssertNotEqual(
            MermaidSourceParser.shortHash("a"),
            MermaidSourceParser.shortHash("b"))
    }

    func test_hashIsHex8() {
        let h = MermaidSourceParser.shortHash("anything")
        XCTAssertEqual(h.count, 8)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func test_encodeStepsRoundtrips() {
        let steps = [
            MermaidSourceParser.StepAnnotation(step: 1, line: 5),
            MermaidSourceParser.StepAnnotation(step: 2, line: 9),
        ]
        let json = MermaidSourceParser.encodeSteps(steps)
        XCTAssertTrue(json.contains("\"step\":1"))
        XCTAssertTrue(json.contains("\"line\":9"))
        // Sorted keys → "line" precedes "step" lexicographically.
        XCTAssertTrue(json.contains("\"line\":5,\"step\":1"))
    }

    func test_encodeStepsEmptyIsEmptyArray() {
        XCTAssertEqual(MermaidSourceParser.encodeSteps([]), "[]")
    }
}
