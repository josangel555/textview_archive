import XCTest
import ViewerKit
@testable import ViewerCore

/// Fake AutomationHost: records every call and returns canned values.
/// Lets us test the catalog's arg parsing + result shape without
/// pulling in DocumentModel (which needs AppKit/SwiftUI and would
/// drag the suite onto the VM-only test list).
@MainActor
final class FakeAutomationHost: AutomationHost {

    var openedPath: (URL, Bool)?
    var nextOpenedID: UUID = UUID()
    var selectedByIndex: Int?
    var selectedById: UUID?
    var setViewModeArg: ViewMode?
    var setZoomArg: Double?
    var gotoLineArg: (Int, Int?)?
    var findQuery: FindQuery?
    var findResult: [FindMatch] = []
    var visibleTextResult: String = ""
    var toggleBookmarkLine: (called: Bool, line: Int?) = (false, nil)
    var stateResult: AutomationState = .init(
        tabs: [], selectedTabIndex: nil, viewMode: "rendered",
        zoom: 1.0, sidebarRoot: nil, isPalettePresented: false
    )
    var listBookmarksResult: [BookmarkEntry] = []
    var snapshotResult: Result<Data, Error> = .success(Data([0x89, 0x50, 0x4E, 0x47]))

    func automationOpenPath(_ url: URL, newTab: Bool) -> UUID {
        openedPath = (url, newTab)
        return nextOpenedID
    }
    func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool {
        selectedByIndex = index
        selectedById = id
        return true
    }
    func automationSetViewMode(_ mode: ViewMode) { setViewModeArg = mode }
    func automationSetZoom(_ zoom: Double) { setZoomArg = zoom }
    func automationGotoLine(_ line: Int, column: Int?) { gotoLineArg = (line, column) }
    func automationFind(_ query: FindQuery) -> [FindMatch] {
        findQuery = query
        return findResult
    }
    func automationVisibleText() -> String { visibleTextResult }
    func automationCurrentState() -> AutomationState { stateResult }
    func automationToggleBookmark(line: Int?) {
        toggleBookmarkLine = (true, line)
    }
    func automationListBookmarks() -> [BookmarkEntry] { listBookmarksResult }
    func automationSnapshotPNG() throws -> Data {
        try snapshotResult.get()
    }
}

@MainActor
final class MCPToolCatalogTests: XCTestCase {

    // Lazy initialization sidesteps the Swift-6.1-vs-6.3 setUp
    // isolation divergence: 6.1 (VM canary) keeps `override func
    // setUp()` nonisolated even when the class is `@MainActor`, so
    // assignment to a MainActor-isolated stored property is
    // rejected. The async `setUp() async throws` variant has its
    // own non-Sendable `super` send. A lazy var owned by the
    // MainActor-isolated class avoids both pitfalls.
    private lazy var host: FakeAutomationHost = FakeAutomationHost()

    // MARK: - Catalog

    func test_allDescriptors_haveUniqueNames() {
        let names = MCPToolCatalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 16)
    }

    func test_allDescriptors_includeAllSpecifiedTools() {
        let names = Set(MCPToolCatalog.all.map(\.name))
        let expected: Set<String> = [
            "open_path", "select_tab", "set_view_mode", "set_zoom",
            "find", "search_files", "goto_line", "visible_text", "current_state",
            "toggle_bookmark", "list_bookmarks", "snapshot_window",
            "list_runnable_tasks", "process_memory", "outline", "git_status",
        ]
        XCTAssertEqual(names, expected)
    }

    // MARK: - outline

    func test_outline_returnsMarkdownHeadings() throws {
        host.visibleTextResult = "# Title\n\nintro\n\n## Section A\n\ntext\n\n### Sub\n\n## Section B\n"
        let result = try MCPToolCatalog.dispatch(name: "outline", args: .object([:]), host: host)
        guard case .object(let obj) = result,
              case .array(let headings)? = obj["headings"],
              case .int(let count)? = obj["count"] else {
            XCTFail("malformed result: \(result)"); return
        }
        XCTAssertEqual(count, 4)
        XCTAssertEqual(headings.count, 4)
        // First heading: level 1, "Title", line 1 (teeth: a handler that ignored
        // the text would return 0 headings).
        guard case .object(let h0) = headings[0],
              case .string(let title0)? = h0["title"],
              case .int(let level0)? = h0["level"],
              case .int(let line0)? = h0["line"] else {
            XCTFail("malformed heading: \(headings[0])"); return
        }
        XCTAssertEqual(title0, "Title")
        XCTAssertEqual(level0, 1)
        XCTAssertEqual(line0, 1)
    }

    func test_outline_emptyForNonMarkdown() throws {
        host.visibleTextResult = "func main() {}\nlet x = 1\n"
        let result = try MCPToolCatalog.dispatch(name: "outline", args: .object([:]), host: host)
        guard case .object(let obj) = result, case .int(let count)? = obj["count"] else {
            XCTFail("malformed: \(result)"); return
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - git_status

    func test_gitStatus_readsBranchFromHEAD() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-git-\(UUID().uuidString)", isDirectory: true)
        let dotGit = tmp.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try "ref: refs/heads/feature-x\n".write(
            to: dotGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        host.stateResult = AutomationState(
            tabs: [], selectedTabIndex: nil, viewMode: "rendered",
            zoom: 1.0, sidebarRoot: tmp.path, isPalettePresented: false)

        let result = try MCPToolCatalog.dispatch(name: "git_status", args: .object([:]), host: host)
        guard case .object(let obj) = result,
              case .bool(let isRepo)? = obj["isRepo"],
              case .string(let branch)? = obj["branch"] else {
            XCTFail("malformed result: \(result)"); return
        }
        XCTAssertTrue(isRepo)
        XCTAssertEqual(branch, "feature-x", "teeth: reads the branch from .git/HEAD")
    }

    func test_gitStatus_notARepo() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        host.stateResult = AutomationState(
            tabs: [], selectedTabIndex: nil, viewMode: "rendered",
            zoom: 1.0, sidebarRoot: tmp.path, isPalettePresented: false)

        let result = try MCPToolCatalog.dispatch(name: "git_status", args: .object([:]), host: host)
        guard case .object(let obj) = result, case .bool(let isRepo)? = obj["isRepo"] else {
            XCTFail("malformed: \(result)"); return
        }
        XCTAssertFalse(isRepo)
    }

    // MARK: - process_memory

    func test_processMemory_reportsAppFootprint() throws {
        let result = try MCPToolCatalog.dispatch(
            name: "process_memory", args: .object([:]), host: host)
        guard case .object(let obj) = result else {
            XCTFail("malformed result: \(result)"); return
        }
        // The live test process has a real phys_footprint > 0 (teeth: a handler
        // that didn't read ProcessMemory.sample would miss it / return 0).
        guard case .int(let footprint)? = obj["appFootprintBytes"] else {
            XCTFail("missing appFootprintBytes"); return
        }
        XCTAssertGreaterThan(footprint, 0)
        // Full sample shape surfaced.
        XCTAssertNotNil(obj["webKitHelperBytes"])
        XCTAssertNotNil(obj["webKitHelperCount"])
        XCTAssertNotNil(obj["helpersComplete"])
    }

    // MARK: - list_runnable_tasks

    func test_listRunnableTasks_returnsDiscoveredTasks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-mcp-tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = #"{ "scripts": { "test": "vitest", "build": "tsc" } }"#
        try pkg.write(to: tmp.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        // The tool must faithfully return RunnableTaskDiscovery's result (teeth:
        // a broken handler / wrong mapping diverges from the direct discovery).
        let direct = RunnableTaskDiscovery.discover(
            projectRoot: tmp.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertGreaterThanOrEqual(direct.count, 2, "the 2 package.json scripts at minimum")

        let result = try MCPToolCatalog.dispatch(
            name: "list_runnable_tasks",
            args: .object(["path": .string(tmp.path)]),
            host: host)

        guard case .object(let obj) = result,
              case .int(let count)? = obj["count"],
              case .array(let taskVals)? = obj["tasks"] else {
            XCTFail("malformed result: \(result)"); return
        }
        XCTAssertEqual(count, direct.count)
        XCTAssertEqual(taskVals.count, direct.count)
        let toolNames = Set(taskVals.compactMap { v -> String? in
            if case .object(let t) = v, case .string(let n)? = t["name"] { return n }
            return nil
        })
        XCTAssertEqual(toolNames, Set(direct.map(\.name)))
        XCTAssertTrue(toolNames.contains("test"))
        XCTAssertTrue(toolNames.contains("build"))
    }

    func test_listRunnableTasks_pathOutsideHome_throwsPermissionDenied() {
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "list_runnable_tasks",
                                        args: .object(["path": .string("/etc")]),
                                        host: host)
        ) { error in
            guard case .permissionDenied = error as? MCPError else {
                XCTFail("expected .permissionDenied, got \(error)"); return
            }
        }
    }

    func test_unknownTool_throwsNotFound() {
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "no_such_tool", args: .object([:]), host: host)
        ) { error in
            guard case .notFound = error as? MCPError else {
                XCTFail("expected .notFound, got \(error)"); return
            }
        }
    }

    // MARK: - open_path

    func test_openPath_pathOutsideHome_throwsPermissionDenied() {
        let args: MCP.Value = .object(["path": .string("/etc/hosts")])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "open_path", args: args, host: host)
        ) { error in
            guard case .permissionDenied = error as? MCPError else {
                XCTFail("expected .permissionDenied, got \(error)"); return
            }
        }
    }

    func test_openPath_tempDirSiblingPrefix_throwsPermissionDenied() {
        // TSK-135: containment must be ANCHORED. A path that merely shares the
        // per-user temp dir as a string prefix WITHOUT a separator
        // (…/T  vs  …/T-evil/loot) is a sibling OUTSIDE the jail and must be
        // rejected with .permissionDenied. A bare `hasPrefix(temp)` would admit
        // it (then fall through to a notFound existence probe) — so this asserts
        // permissionDenied specifically, and fails if the anchor regresses.
        // Containment is checked before existence, so the path need not exist.
        let temp = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().path
        let sibling = temp + "-evil-\(UUID().uuidString)/loot.txt"
        let args: MCP.Value = .object(["path": .string(sibling)])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "open_path", args: args, host: host)
        ) { error in
            guard case .permissionDenied = error as? MCPError else {
                XCTFail("expected .permissionDenied for temp-dir sibling, got \(error)"); return
            }
        }
    }

    func test_openPath_nonexistentPath_throwsNotFound() {
        // Use a tilde-expanded path that won't exist.
        let args: MCP.Value = .object([
            "path": .string("~/.this-path-definitely-does-not-exist-\(UUID().uuidString)"),
        ])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "open_path", args: args, host: host)
        ) { error in
            guard case .notFound = error as? MCPError else {
                XCTFail("expected .notFound, got \(error)"); return
            }
        }
    }

    func test_openPath_validPathInTemp_dispatchesAndReturnsTabId() throws {
        // Stage a scratch file under the user's per-user tempdir
        // (whitelisted alongside $HOME by the catalog validator).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let id = UUID()
        host.nextOpenedID = id
        let args: MCP.Value = .object([
            "path": .string(tmp.path),
            "newTab": .bool(false),
        ])
        let result = try MCPToolCatalog.dispatch(name: "open_path", args: args, host: host)
        XCTAssertEqual(host.openedPath?.0.path, tmp.path)
        XCTAssertEqual(host.openedPath?.1, false)
        XCTAssertEqual(result, .object(["tabId": .string(id.uuidString)]))
    }

    func test_openPath_missingArg_throwsInvalidParams() {
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "open_path", args: .object([:]), host: host)
        ) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected .invalidParams, got \(error)"); return
            }
        }
    }

    // MARK: - select_tab

    func test_selectTab_byIndex_dispatches() throws {
        let args: MCP.Value = .object(["byIndex": .int(2)])
        _ = try MCPToolCatalog.dispatch(name: "select_tab", args: args, host: host)
        XCTAssertEqual(host.selectedByIndex, 2)
        XCTAssertNil(host.selectedById)
    }

    func test_selectTab_byId_dispatches() throws {
        let uuid = UUID()
        let args: MCP.Value = .object(["byId": .string(uuid.uuidString)])
        _ = try MCPToolCatalog.dispatch(name: "select_tab", args: args, host: host)
        XCTAssertEqual(host.selectedById, uuid)
    }

    func test_selectTab_invalidUUID_throwsInvalidParams() {
        let args: MCP.Value = .object(["byId": .string("not-a-uuid")])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "select_tab", args: args, host: host)
        )
    }

    func test_selectTab_noArgs_throwsInvalidParams() {
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "select_tab", args: .object([:]), host: host)
        )
    }

    // MARK: - set_view_mode

    func test_setViewMode_validMode_dispatches() throws {
        let args: MCP.Value = .object(["mode": .string("source")])
        _ = try MCPToolCatalog.dispatch(name: "set_view_mode", args: args, host: host)
        XCTAssertEqual(host.setViewModeArg, .source)
    }

    func test_setViewMode_invalidMode_throws() {
        let args: MCP.Value = .object(["mode": .string("bogus")])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "set_view_mode", args: args, host: host)
        )
    }

    // MARK: - set_zoom

    func test_setZoom_inRange_dispatchesVerbatimAndReportsNotClamped() throws {
        let args: MCP.Value = .object(["zoom": .double(1.5)])
        let result = try MCPToolCatalog.dispatch(name: "set_zoom", args: args, host: host)
        XCTAssertEqual(host.setZoomArg, 1.5)
        guard case .object(let o) = result else { return XCTFail("result not object") }
        XCTAssertEqual(o["zoom"], .double(1.5))
        XCTAssertEqual(o["requested"], .double(1.5))
        XCTAssertEqual(o["clamped"], .bool(false))
    }

    func test_setZoom_integerArg_acceptedAsDouble() throws {
        // JSON `2` decodes to `.int` (Int is tried before Double); a
        // Double-typed zoom arg must still accept it as 2.0.
        let args: MCP.Value = .object(["zoom": .int(2)])
        let result = try MCPToolCatalog.dispatch(name: "set_zoom", args: args, host: host)
        XCTAssertEqual(host.setZoomArg, 2.0)
        guard case .object(let o) = result else { return XCTFail("result not object") }
        XCTAssertEqual(o["zoom"], .double(2.0))
        XCTAssertEqual(o["clamped"], .bool(false))
    }

    func test_setZoom_aboveMax_clampsAndReportsClamped() throws {
        let tooBig = PreferencesStore.maxZoom + 5.0
        let args: MCP.Value = .object(["zoom": .double(tooBig)])
        let result = try MCPToolCatalog.dispatch(name: "set_zoom", args: args, host: host)
        // Host received the CLAMPED value, never the raw out-of-range one.
        XCTAssertEqual(host.setZoomArg, PreferencesStore.maxZoom)
        guard case .object(let o) = result else { return XCTFail("result not object") }
        XCTAssertEqual(o["zoom"], .double(PreferencesStore.maxZoom))
        XCTAssertEqual(o["requested"], .double(tooBig))
        XCTAssertEqual(o["clamped"], .bool(true))
    }

    func test_setZoom_belowMin_clampsToMin() throws {
        let tooSmall = PreferencesStore.minZoom - 5.0
        let args: MCP.Value = .object(["zoom": .double(tooSmall)])
        let result = try MCPToolCatalog.dispatch(name: "set_zoom", args: args, host: host)
        XCTAssertEqual(host.setZoomArg, PreferencesStore.minZoom)
        guard case .object(let o) = result else { return XCTFail("result not object") }
        XCTAssertEqual(o["zoom"], .double(PreferencesStore.minZoom))
        XCTAssertEqual(o["clamped"], .bool(true))
    }

    func test_setZoom_missingArg_throwsInvalidParams() {
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "set_zoom", args: .object([:]), host: host)
        ) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected .invalidParams, got \(error)"); return
            }
        }
        XCTAssertNil(host.setZoomArg)
    }

    func test_setZoom_nonNumericArg_throwsInvalidParams() {
        let args: MCP.Value = .object(["zoom": .string("big")])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "set_zoom", args: args, host: host)
        ) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected .invalidParams, got \(error)"); return
            }
        }
        XCTAssertNil(host.setZoomArg)
    }

    func test_setZoom_nonFiniteArg_throwsInvalidParams() {
        // NaN / Inf must be rejected before reaching the clamp — NaN
        // compares false against every bound, so it would slip past
        // min/max and corrupt the persisted zoom.
        let args: MCP.Value = .object(["zoom": .double(Double.nan)])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "set_zoom", args: args, host: host)
        ) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected .invalidParams, got \(error)"); return
            }
        }
        XCTAssertNil(host.setZoomArg)
    }

    // MARK: - find

    func test_find_passesQueryThrough() throws {
        host.findResult = [FindMatch(range: NSRange(location: 0, length: 5), line: 1, column: 1)]
        let args: MCP.Value = .object([
            "query": .string("hello"),
            "regex": .bool(true),
            "caseSensitive": .bool(true),
        ])
        let result = try MCPToolCatalog.dispatch(name: "find", args: args, host: host)
        XCTAssertEqual(host.findQuery?.pattern, "hello")
        XCTAssertEqual(host.findQuery?.kind, .regex)
        XCTAssertEqual(host.findQuery?.caseSensitive, true)
        // Result shape: matches array + truncated + total
        guard case .object(let o) = result else { return XCTFail("result not object") }
        XCTAssertEqual(o["total"], .int(1))
        XCTAssertEqual(o["truncated"], .bool(false))
    }

    func test_find_invalidRegex_throwsInvalidParams_notZeroMatches() {
        // An unbalanced group is a syntax error. Without pre-validation
        // the host's FindEngine throws, automationFind swallows it to
        // `[]`, and the tool would report `total:0` — indistinguishable
        // from a genuine no-match. We must surface an MCP error instead.
        let args: MCP.Value = .object([
            "query": .string("(unterminated"),
            "regex": .bool(true),
        ])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "find", args: args, host: host)
        ) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected .invalidParams, got \(error)"); return
            }
        }
        // The bad pattern must never reach the host.
        XCTAssertNil(host.findQuery)
    }

    func test_find_unsafeRegex_throwsInvalidParams() {
        // A classic ReDoS shape — rejected by RegexComplexityGuard
        // before it can be handed to the engine. Same observable
        // contract: an MCP error, not a silent `total:0`.
        let args: MCP.Value = .object([
            "query": .string("(a+)+$"),
            "regex": .bool(true),
        ])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "find", args: args, host: host)
        ) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected .invalidParams, got \(error)"); return
            }
        }
        XCTAssertNil(host.findQuery)
    }

    func test_find_validRegex_dispatchesNormally() throws {
        // A well-formed regex must pass pre-validation untouched.
        let args: MCP.Value = .object([
            "query": .string("h.llo"),
            "regex": .bool(true),
        ])
        _ = try MCPToolCatalog.dispatch(name: "find", args: args, host: host)
        XCTAssertEqual(host.findQuery?.pattern, "h.llo")
        XCTAssertEqual(host.findQuery?.kind, .regex)
    }

    func test_find_literalPattern_skipsRegexValidation() throws {
        // The same `(unterminated` string is a perfectly valid LITERAL
        // query — pre-validation only applies when regex:true, so this
        // must dispatch, not throw.
        let args: MCP.Value = .object([
            "query": .string("(unterminated"),
            "regex": .bool(false),
        ])
        _ = try MCPToolCatalog.dispatch(name: "find", args: args, host: host)
        XCTAssertEqual(host.findQuery?.pattern, "(unterminated")
        XCTAssertEqual(host.findQuery?.kind, .literal)
    }

    // MARK: - goto_line

    func test_gotoLine_dispatches() throws {
        let args: MCP.Value = .object(["line": .int(42), "column": .int(7)])
        _ = try MCPToolCatalog.dispatch(name: "goto_line", args: args, host: host)
        XCTAssertEqual(host.gotoLineArg?.0, 42)
        XCTAssertEqual(host.gotoLineArg?.1, 7)
    }

    func test_gotoLine_zeroOrNegative_throws() {
        let args: MCP.Value = .object(["line": .int(0)])
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "goto_line", args: args, host: host)
        )
    }

    // MARK: - visible_text

    func test_visibleText_returnsText() throws {
        host.visibleTextResult = "hello world"
        let result = try MCPToolCatalog.dispatch(name: "visible_text",
                                                 args: .object([:]), host: host)
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["text"], .string("hello world"))
        XCTAssertEqual(o["truncated"], .bool(false))
        XCTAssertEqual(o["totalBytes"], .int(11))
    }

    // MARK: - current_state

    func test_currentState_serialisesStatePayload() throws {
        host.stateResult = AutomationState(
            tabs: [
                .init(id: "T-1", path: "/tmp/a.md", title: "a.md", viewMode: "rendered"),
            ],
            selectedTabIndex: 0,
            viewMode: "rendered",
            zoom: 1.25,
            sidebarRoot: "/tmp",
            isPalettePresented: false
        )
        let result = try MCPToolCatalog.dispatch(name: "current_state",
                                                 args: .object([:]), host: host)
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["zoom"], .double(1.25))
        XCTAssertEqual(o["viewMode"], .string("rendered"))
        XCTAssertEqual(o["sidebarRoot"], .string("/tmp"))
        guard case .array(let tabs)? = o["tabs"] else { return XCTFail() }
        XCTAssertEqual(tabs.count, 1)
    }

    // MARK: - toggle_bookmark

    func test_toggleBookmark_fileLevel() throws {
        _ = try MCPToolCatalog.dispatch(name: "toggle_bookmark",
                                        args: .object([:]), host: host)
        XCTAssertTrue(host.toggleBookmarkLine.called)
        XCTAssertNil(host.toggleBookmarkLine.line)
    }

    func test_toggleBookmark_lineLevel() throws {
        let args: MCP.Value = .object(["line": .int(12)])
        _ = try MCPToolCatalog.dispatch(name: "toggle_bookmark", args: args, host: host)
        XCTAssertEqual(host.toggleBookmarkLine.line, 12)
    }

    // MARK: - list_bookmarks

    func test_listBookmarks_emitsArray() throws {
        host.listBookmarksResult = [
            BookmarkEntry(url: URL(fileURLWithPath: "/tmp/a.md"),
                          addedAt: Date(timeIntervalSince1970: 0),
                          displayName: "a", line: nil),
            BookmarkEntry(url: URL(fileURLWithPath: "/tmp/b.md"),
                          addedAt: Date(timeIntervalSince1970: 0),
                          displayName: "b:5", line: 5),
        ]
        let result = try MCPToolCatalog.dispatch(name: "list_bookmarks",
                                                 args: .object([:]), host: host)
        guard case .object(let o) = result,
              case .array(let bms)? = o["bookmarks"] else {
            return XCTFail()
        }
        XCTAssertEqual(bms.count, 2)
    }

    // MARK: - snapshot_window

    func test_snapshotWindow_returnsBase64() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        host.snapshotResult = .success(bytes)
        let result = try MCPToolCatalog.dispatch(name: "snapshot_window",
                                                 args: .object([:]), host: host)
        guard case .object(let o) = result else { return XCTFail() }
        XCTAssertEqual(o["pngBase64"], .string(bytes.base64EncodedString()))
        XCTAssertEqual(o["bytes"], .int(bytes.count))
    }

    func test_snapshotWindow_hostThrows_surfacesToolFailed() {
        struct Boom: Error {}
        host.snapshotResult = .failure(Boom())
        XCTAssertThrowsError(
            try MCPToolCatalog.dispatch(name: "snapshot_window",
                                        args: .object([:]), host: host)
        ) { error in
            guard case .toolFailed = error as? MCPError else {
                XCTFail("expected .toolFailed, got \(error)"); return
            }
        }
    }
}
