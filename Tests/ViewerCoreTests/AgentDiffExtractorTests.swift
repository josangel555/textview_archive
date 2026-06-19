import XCTest
@testable import ViewerCore

/// Host-tested behavior for `AgentDiffExtractor` (TSK-940 — "Review
/// agent-written diffs in-app"). The extractor turns an agent (Claude Code)
/// `Edit`/`Write`/`MultiEdit` tool call into reviewable unified-diff text.
/// These tests pin both the produced text shape AND that it parses cleanly
/// through the existing render path (`RustDiffAdapter.parse`), so a regression
/// in either fails the host gate.
final class AgentDiffExtractorTests: XCTestCase {

    // MARK: - isDiffable / diffableToolNames

    func test_isDiffable_recognizesMutatingTools() {
        XCTAssertTrue(AgentDiffExtractor.isDiffable(toolName: "Edit"))
        XCTAssertTrue(AgentDiffExtractor.isDiffable(toolName: "Write"))
        XCTAssertTrue(AgentDiffExtractor.isDiffable(toolName: "MultiEdit"))
    }

    func test_isDiffable_rejectsNonMutatingTools() {
        XCTAssertFalse(AgentDiffExtractor.isDiffable(toolName: "Read"))
        XCTAssertFalse(AgentDiffExtractor.isDiffable(toolName: "Bash"))
        XCTAssertFalse(AgentDiffExtractor.isDiffable(toolName: "Grep"))
        XCTAssertFalse(AgentDiffExtractor.isDiffable(toolName: ""))
    }

    // MARK: - Edit

    func test_edit_producesUnifiedDiffWithRemovedAndAddedLines() {
        let input = [
            "file_path": "/repo/auth.swift",
            "old_string": "let x = 1\nlet y = 2",
            "new_string": "let x = 10\nlet y = 20\nlet z = 30",
        ]
        let text = AgentDiffExtractor.unifiedDiffText(toolName: "Edit", input: input)
        XCTAssertNotNil(text)
        let diff = text!
        XCTAssertTrue(diff.contains("diff --git a/repo/auth.swift b/repo/auth.swift"))
        XCTAssertTrue(diff.contains("--- a/repo/auth.swift"))
        XCTAssertTrue(diff.contains("+++ b/repo/auth.swift"))
        // Two removed lines, three added lines.
        XCTAssertTrue(diff.contains("@@ -1,2 +1,3 @@"))
        XCTAssertTrue(diff.contains("-let x = 1"))
        XCTAssertTrue(diff.contains("-let y = 2"))
        XCTAssertTrue(diff.contains("+let x = 10"))
        XCTAssertTrue(diff.contains("+let z = 30"))
    }

    func test_edit_parsesThroughRenderPath() {
        let input = [
            "file_path": "src/main.rs",
            "old_string": "foo()",
            "new_string": "bar()\nbaz()",
        ]
        let text = AgentDiffExtractor.unifiedDiffText(toolName: "Edit", input: input)!
        let files = RustDiffAdapter.parse(text)
        XCTAssertEqual(files.count, 1, "extractor output must parse to exactly one file")
        let file = files[0]
        XCTAssertEqual(file.newPath, "src/main.rs")
        // One hunk: 1 removed + 2 added.
        XCTAssertEqual(file.hunks.count, 1)
        let removed = file.hunks[0].lines.filter { $0.kind == .removed }
        let added = file.hunks[0].lines.filter { $0.kind == .added }
        XCTAssertEqual(removed.map(\.content), ["foo()"])
        XCTAssertEqual(added.map(\.content), ["bar()", "baz()"])
    }

    func test_edit_noOpReturnsNil() {
        let input = [
            "file_path": "a.txt",
            "old_string": "same",
            "new_string": "same",
        ]
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(toolName: "Edit", input: input))
    }

    func test_edit_missingPayloadReturnsNil() {
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "Edit", input: ["file_path": "a.txt", "old_string": "x"]))
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "Edit", input: ["file_path": "a.txt"]))
    }

    func test_edit_deletionToEmptyString() {
        let input = [
            "file_path": "x.swift",
            "old_string": "removeMe",
            "new_string": "",
        ]
        let text = AgentDiffExtractor.unifiedDiffText(toolName: "Edit", input: input)!
        XCTAssertTrue(text.contains("@@ -1,1 +0,0 @@"))
        XCTAssertTrue(text.contains("-removeMe"))
        let files = RustDiffAdapter.parse(text)
        XCTAssertEqual(files.first?.hunks.first?.lines.filter { $0.kind == .added }.count, 0)
    }

    // MARK: - Write

    func test_write_rendersAsNewFileAllAdded() {
        let input = [
            "file_path": "/new/file.md",
            "content": "# Title\n\nBody line\n",
        ]
        let text = AgentDiffExtractor.unifiedDiffText(toolName: "Write", input: input)!
        XCTAssertTrue(text.contains("diff --git a/new/file.md b/new/file.md"))
        XCTAssertTrue(text.contains("new file mode 100644"))
        XCTAssertTrue(text.contains("--- /dev/null"))
        XCTAssertTrue(text.contains("+++ b/new/file.md"))
        // 3 lines (trailing newline's empty fragment dropped).
        XCTAssertTrue(text.contains("@@ -0,0 +1,3 @@"))
        let files = RustDiffAdapter.parse(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isNew, "Write must parse as a new-file diff")
        let added = files[0].hunks.flatMap { $0.lines }.filter { $0.kind == .added }
        XCTAssertEqual(added.map(\.content), ["# Title", "", "Body line"])
    }

    func test_write_missingContentReturnsNil() {
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "Write", input: ["file_path": "x"]))
    }

    func test_write_singleLineNoTrailingNewline() {
        let text = AgentDiffExtractor.unifiedDiffText(
            toolName: "Write", input: ["file_path": "a", "content": "one line"])!
        XCTAssertTrue(text.contains("@@ -0,0 +1,1 @@"))
        XCTAssertTrue(text.contains("+one line"))
    }

    // MARK: - MultiEdit

    func test_multiEdit_oneHunkPerEdit() {
        // `edits` arrives as a stringified JSON array (matching how
        // ClaudeLogParser.stringifyInput serialises nested values).
        let editsJSON = #"""
        [{"old_string":"alpha","new_string":"ALPHA"},{"old_string":"beta\ngamma","new_string":"BETA"}]
        """#
        let input = [
            "file_path": "multi.txt",
            "edits": editsJSON,
        ]
        let text = AgentDiffExtractor.unifiedDiffText(toolName: "MultiEdit", input: input)!
        let files = RustDiffAdapter.parse(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks.count, 2, "one hunk per edit")
        // Edit 1: 1 removed, 1 added. Edit 2: 2 removed, 1 added.
        let h0 = files[0].hunks[0]
        XCTAssertEqual(h0.lines.filter { $0.kind == .removed }.map(\.content), ["alpha"])
        XCTAssertEqual(h0.lines.filter { $0.kind == .added }.map(\.content), ["ALPHA"])
        let h1 = files[0].hunks[1]
        XCTAssertEqual(h1.lines.filter { $0.kind == .removed }.map(\.content), ["beta", "gamma"])
        XCTAssertEqual(h1.lines.filter { $0.kind == .added }.map(\.content), ["BETA"])
    }

    func test_multiEdit_skipsNoOpEdits() {
        let editsJSON = #"[{"old_string":"x","new_string":"x"},{"old_string":"a","new_string":"b"}]"#
        let text = AgentDiffExtractor.unifiedDiffText(
            toolName: "MultiEdit", input: ["file_path": "f", "edits": editsJSON])!
        let files = RustDiffAdapter.parse(text)
        XCTAssertEqual(files[0].hunks.count, 1, "no-op edit dropped, only the real one remains")
    }

    func test_multiEdit_allNoOpReturnsNil() {
        let editsJSON = #"[{"old_string":"same","new_string":"same"}]"#
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "MultiEdit", input: ["file_path": "f", "edits": editsJSON]))
    }

    func test_multiEdit_malformedPayloadReturnsNil() {
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "MultiEdit", input: ["file_path": "f", "edits": "not json"]))
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "MultiEdit", input: ["file_path": "f"]))
    }

    func test_parseMultiEdits_skipsEntriesMissingKeys() {
        let json = #"[{"old_string":"a"},{"old_string":"b","new_string":"c"}]"#
        let edits = AgentDiffExtractor.parseMultiEdits(json)
        XCTAssertEqual(edits?.count, 1)
        XCTAssertEqual(edits?.first?.old, "b")
        XCTAssertEqual(edits?.first?.new, "c")
    }

    // MARK: - Non-diffable tools

    func test_nonDiffableTool_returnsNil() {
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "Bash", input: ["command": "ls"]))
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(
            toolName: "Read", input: ["file_path": "x"]))
    }

    // MARK: - ClaudeEvent convenience

    func test_unifiedDiffTextForEvent_diffableToolUse() {
        let event = ClaudeEvent(id: "t1", timestamp: nil, kind: .toolUse(
            id: "t1", name: "Edit",
            input: ["file_path": "z.swift", "old_string": "a", "new_string": "b"]))
        let text = AgentDiffExtractor.unifiedDiffText(for: event)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("-a"))
        XCTAssertTrue(text!.contains("+b"))
    }

    func test_unifiedDiffTextForEvent_nonToolUseReturnsNil() {
        let event = ClaudeEvent(id: "m1", timestamp: nil, kind: .assistantMessage(text: "hi"))
        XCTAssertNil(AgentDiffExtractor.unifiedDiffText(for: event))
    }

    // MARK: - splitKeepingTrailingEmpty edge cases

    func test_splitKeepingTrailingEmpty() {
        XCTAssertEqual(AgentDiffExtractor.splitKeepingTrailingEmpty(""), [])
        XCTAssertEqual(AgentDiffExtractor.splitKeepingTrailingEmpty("a"), ["a"])
        XCTAssertEqual(AgentDiffExtractor.splitKeepingTrailingEmpty("a\n"), ["a"])
        XCTAssertEqual(AgentDiffExtractor.splitKeepingTrailingEmpty("a\nb"), ["a", "b"])
        // Interior blank line preserved.
        XCTAssertEqual(AgentDiffExtractor.splitKeepingTrailingEmpty("a\n\nb"), ["a", "", "b"])
        // Only the LAST trailing-newline empty fragment is dropped (one of two).
        XCTAssertEqual(AgentDiffExtractor.splitKeepingTrailingEmpty("a\n\n"), ["a", ""])
    }
}
