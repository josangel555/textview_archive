import Foundation
import RustCore
import ViewerKit

/// The v1 MCP tools, per design §6. Each tool has a descriptor
/// (name + JSON Schema for `tools/list`) and a dispatcher (the closure
/// that turns args into an `AutomationHost` call).
///
/// Tools are kept in this single file so the catalog reads top-to-
/// bottom — the action vocabulary is small and stable enough that the
/// usual "one file per handler" wins us nothing.
///
/// TSK-697 — Agent Services suite (foundation slice). The owner's call:
/// "all these should be accessible for an Agent through MCP." This is the
/// canonical home for agent-callable services, so the first Agent Service
/// — `search_files` (global / cross-file grep, backed by the existing
/// `CrossFileSearch` engine) — lands here alongside the v1 viewer-control
/// tools. The other four capabilities (semantic/LSP search, refactor,
/// test runner, code review) are tracked as the epic's `remaining` slices,
/// each to add one tool to this catalog backed by its existing engine.
@MainActor
public enum MCPToolCatalog {

    // MARK: - Catalog

    public static let all: [MCP.ToolDescriptor] = [
        openPathDescriptor,
        selectTabDescriptor,
        setViewModeDescriptor,
        setZoomDescriptor,
        findDescriptor,
        searchFilesDescriptor,
        gotoLineDescriptor,
        visibleTextDescriptor,
        outlineDescriptor,
        gitStatusDescriptor,
        runVerbDescriptor,
        listVerbsDescriptor,
        listSurfacesDescriptor,
        lintDescriptor,
        currentStateDescriptor,
        toggleBookmarkDescriptor,
        listBookmarksDescriptor,
        snapshotWindowDescriptor,
        listRunnableTasksDescriptor,
        getReviewContextDescriptor,
        listReviewCommentsDescriptor,
        processMemoryDescriptor,
        canvasNewDescriptor,
        canvasOpenDescriptor,
        canvasSaveDescriptor,
        canvasApplyDescriptor,
        canvasReadDescriptor,
        canvasVocabDescriptor,
        canvasLintDescriptor,
        canvasUndoDescriptor,
        canvasExportDescriptor,
        canvasKitImportDescriptor,
        canvasTimelineDescriptor,
        whoCallsDescriptor,
        gotoDefinitionDescriptor,
        findReferencesDescriptor,
        renameSymbolDescriptor,
        runTaskDescriptor,
        moveFileDescriptor,
    ]

    /// Dispatch a tool call. Returns the structured tool-result value
    /// (which the server wraps in a `ToolCallResult`). Throws
    /// `MCPError` on arg/permission/tool failures.
    public static func dispatch(
        name: String,
        args: MCP.Value,
        host: AutomationHost
    ) throws -> MCP.Value {
        switch name {
        case "open_path":         return try openPath(args, host)
        case "select_tab":        return try selectTab(args, host)
        case "set_view_mode":     return try setViewMode(args, host)
        case "set_zoom":          return try setZoom(args, host)
        case "find":              return try find(args, host)
        case "search_files":      return try searchFiles(args, host)
        case "goto_line":         return try gotoLine(args, host)
        case "visible_text":      return try visibleText(args, host)
        case "outline":           return try outline(args, host)
        case "git_status":        return try gitStatus(args, host)
        case "run_verb":          return try runVerb(args, host)
        case "list_verbs":        return try listVerbs(args, host)
        case "list_surfaces":     return try listSurfaces(args, host)
        case "lint":              return try lint(args, host)
        case "current_state":     return try currentState(args, host)
        case "toggle_bookmark":   return try toggleBookmark(args, host)
        case "list_bookmarks":    return try listBookmarks(args, host)
        case "snapshot_window":   return try snapshotWindow(args, host)
        case "list_runnable_tasks": return try listRunnableTasks(args, host)
        case "get_review_context":  return try getReviewContext(args)
        case "list_review_comments": return try listReviewComments(args)
        case "process_memory":    return try processMemory(args, host)
        case "canvas_new":         return try canvasNew(args, host)
        case "canvas_open":        return try canvasOpen(args, host)
        case "canvas_save":        return try canvasSave(args, host)
        case "canvas_apply":       return try canvasApply(args, host)
        case "canvas_read":        return try canvasRead(args, host)
        case "canvas_vocab":       return try canvasVocab(args, host)
        case "canvas_lint":        return try canvasLint(args, host)
        case "canvas_undo":        return try canvasUndo(args, host)
        case "canvas_export":      return try canvasExport(args, host)
        case "canvas_kit_import":  return try canvasKitImport(args, host)
        case "canvas_timeline":    return try canvasTimeline(args, host)
        default:
            throw MCPError.notFound("unknown tool: \(name)")
        }
    }

    // MARK: - Schemas

    private static func schema(_ properties: [String: MCP.Value],
                               required: [String] = []) -> MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }
    private static let emptySchema: MCP.Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    // MARK: - open_path

    private static let openPathDescriptor = MCP.ToolDescriptor(
        name: "open_path",
        description: "Open a file or folder. Returns the resulting tab id.",
        inputSchema: schema([
            "path":   .object(["type": .string("string"),
                               "description": .string("Absolute or ~-expanded filesystem path")]),
            "newTab": .object(["type": .string("boolean"),
                               "description": .string("Force a new tab (default true)")]),
        ], required: ["path"])
    )

    private static func openPath(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let path = try args.string("path")
        let newTab = (try? args.bool("newTab")) ?? true
        let url = try validatedExistingURL(from: path)
        let id = host.automationOpenPath(url, newTab: newTab)
        return .object(["tabId": .string(id.uuidString)])
    }

    // MARK: - select_tab

    private static let selectTabDescriptor = MCP.ToolDescriptor(
        name: "select_tab",
        description: "Select a tab by 1-based index or id (exactly one of byIndex/byId).",
        inputSchema: schema([
            "byIndex": .object(["type": .string("integer")]),
            "byId":    .object(["type": .string("string")]),
        ])
    )

    private static func selectTab(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let idx = args.optionalInt("byIndex")
        let idStr = args.optionalString("byId")
        guard idx != nil || idStr != nil else {
            throw MCPError.invalidParams("provide byIndex or byId")
        }
        let uuid = idStr.flatMap(UUID.init(uuidString:))
        if idStr != nil && uuid == nil {
            throw MCPError.invalidParams("byId is not a valid UUID")
        }
        let changed = host.automationSelectTab(byIndex: idx, byId: uuid)
        return .object(["changed": .bool(changed)])
    }

    // MARK: - set_view_mode

    private static let setViewModeDescriptor = MCP.ToolDescriptor(
        name: "set_view_mode",
        description: "Set the current tab's view mode. One of: rendered, source, formatted, table, diff, hex.",
        inputSchema: schema([
            "mode": .object(["type": .string("string"),
                             "enum": .array(ViewMode.allCases.map { .string($0.rawValue) })]),
        ], required: ["mode"])
    )

    private static func setViewMode(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let raw = try args.string("mode")
        guard let mode = ViewMode(rawValue: raw) else {
            throw MCPError.invalidParams("unknown view mode: \(raw)")
        }
        host.automationSetViewMode(mode)
        return .object(["mode": .string(mode.rawValue)])
    }

    // MARK: - set_zoom

    private static let setZoomDescriptor = MCP.ToolDescriptor(
        name: "set_zoom",
        description: """
        Set the absolute content zoom multiplier. Clamped to \
        [\(PreferencesStore.minZoom), \(PreferencesStore.maxZoom)]; \
        the applied (post-clamp) value is returned, along with whether a \
        clamp occurred. 1.0 = 100%.
        """,
        inputSchema: schema([
            "zoom": .object(["type": .string("number"),
                             "description": .string(
                                "Zoom multiplier; 1.0 = 100%. "
                                + "Clamped to [\(PreferencesStore.minZoom), "
                                + "\(PreferencesStore.maxZoom)].")]),
        ], required: ["zoom"])
    )

    private static func setZoom(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let requested = try args.double("zoom")
        // Clamp HERE (the catalog is where policy/limits live, mirroring
        // open_path's path jail) rather than in the host — and report the
        // applied value + a `clamped` flag so a client that asked for an
        // out-of-range zoom can SEE that its request was reshaped instead
        // of silently no-op'ing. `automationSetZoom` applies verbatim.
        let lo = PreferencesStore.minZoom
        let hi = PreferencesStore.maxZoom
        let applied = min(max(requested, lo), hi)
        host.automationSetZoom(applied)
        return .object([
            "zoom": .double(applied),
            "requested": .double(requested),
            "clamped": .bool(applied != requested),
        ])
    }

    // MARK: - find

    // MARK: TSK-1192 — code nav (the ASYNC tool lane)

    private static let whoCallsDescriptor = MCP.ToolDescriptor(
        name: "who_calls",
        description: "Semantic code nav: resolve a symbol via the live LSP and "
            + "return its definition plus every caller (file:line, capped at 200). "
            + "Requires a running language server for the symbol's language.",
        inputSchema: schema([
            "symbol": .object(["type": .string("string")]),
        ], required: ["symbol"])
    )

    /// TSK-1560 — position-based nav (the agent-services s1 slice). Inputs
    /// are EDITOR-facing 1-based line/column; the handler converts to
    /// LSP-native 0-based.
    private static let gotoDefinitionDescriptor = MCP.ToolDescriptor(
        name: "goto_definition",
        description: "Semantic code nav: the definition location(s) of the "
            + "symbol at file:line:column (1-based). Requires a running "
            + "language server for the file's language.",
        inputSchema: schema([
            "file":   .object(["type": .string("string")]),
            "line":   .object(["type": .string("integer")]),
            "column": .object(["type": .string("integer")]),
        ], required: ["file", "line", "column"])
    )

    private static let findReferencesDescriptor = MCP.ToolDescriptor(
        name: "find_references",
        description: "Semantic code nav: every reference to the symbol at "
            + "file:line:column (1-based; declaration included, capped at "
            + "200). Requires a running language server for the file's language.",
        inputSchema: schema([
            "file":   .object(["type": .string("string")]),
            "line":   .object(["type": .string("integer")]),
            "column": .object(["type": .string("integer")]),
        ], required: ["file", "line", "column"])
    )

    /// TSK-1561 — the refactor-rename tool (agent-services s2). DRY-RUN BY
    /// DEFAULT: without `apply:true` it only reports what would change.
    private static let renameSymbolDescriptor = MCP.ToolDescriptor(
        name: "rename_symbol",
        description: "Refactor: rename the symbol at file:line:column "
            + "(1-based) to new_name via the live LSP. DRY-RUN by default — "
            + "returns the per-file edit summary without changing anything; "
            + "pass apply:true to apply to OPEN tabs (files not open are "
            + "reported in skippedFiles and never written — open them and "
            + "re-run). Requires a running language server.",
        inputSchema: schema([
            "file":     .object(["type": .string("string")]),
            "line":     .object(["type": .string("integer")]),
            "column":   .object(["type": .string("integer")]),
            "new_name": .object(["type": .string("string")]),
            "apply":    .object(["type": .string("boolean")]),
        ], required: ["file", "line", "column", "new_name"])
    )

    /// TSK-1562 — the test/task-runner tool (agent-services s3). The
    /// ALLOWLIST is discovery itself: only a task id that
    /// `list_runnable_tasks` reports for that project can run — there is no
    /// way to express an arbitrary command. Spawn is shell-free
    /// (/usr/bin/env + tokenized argv), output-capped, and wall-clock
    /// bounded.
    private static let runTaskDescriptor = MCP.ToolDescriptor(
        name: "run_task",
        description: "Run ONE discovered task by id (from list_runnable_tasks "
            + "on the same path) and return its exit code + captured output. "
            + "Only listed tasks can run — arbitrary commands are not "
            + "expressible. Bounded: timeout_seconds (default 120, max 600), "
            + "output capped at 64KB.",
        inputSchema: schema([
            "path": .object(["type": .string("string"),
                             "description": .string("Project root (the same path given to list_runnable_tasks)")]),
            "id":   .object(["type": .string("string"),
                             "description": .string("Task id exactly as reported by list_runnable_tasks (e.g. \"makefile:test\")")]),
            "timeout_seconds": .object(["type": .string("integer")]),
        ], required: ["path", "id"])
    )

    /// run_task's bounds: the output cap keeps a noisy build from flooding
    /// the wire; the timeout ceiling keeps an agent from parking a runner
    /// for an hour. nonisolated: read from the async lane.
    nonisolated static let runTaskMaxOutputBytes = 64 * 1024
    nonisolated static let runTaskDefaultTimeout: TimeInterval = 120
    nonisolated static let runTaskMaxTimeout: TimeInterval = 600

    /// TSK-1565 — the move-file refactor tool (agent-services s5). DRY-RUN
    /// BY DEFAULT; `importFixup` is honest about server support.
    private static let moveFileDescriptor = MCP.ToolDescriptor(
        name: "move_file",
        description: "Refactor: move a file, with import fixup where the "
            + "language server supports workspace/willRenameFiles "
            + "(TypeScript/JS, Java) and an honest importFixup:\"unsupported\" "
            + "plain move otherwise. DRY-RUN by default — returns the edit "
            + "summary without touching disk or buffers; pass apply:true to "
            + "apply edits to open tabs, move (never overwrites an existing "
            + "destination), and notify the server.",
        inputSchema: schema([
            "from":  .object(["type": .string("string")]),
            "to":    .object(["type": .string("string")]),
            "apply": .object(["type": .string("boolean")]),
        ], required: ["from", "to"])
    )

    /// Tools that MUST run on the server's reader thread (an LSP round-trip
    /// can take seconds — parking the main actor would freeze the UI).
    public nonisolated static func isAsyncTool(_ name: String) -> Bool {
        name == "who_calls" || name == "goto_definition" || name == "find_references"
            || name == "rename_symbol" || name == "run_task" || name == "move_file"
    }

    /// Carries the host existential across the async-tool boundary.
    /// @unchecked: the async lane only calls `automationWhoCalls`, whose
    /// live implementation is `nonisolated` and hops to the right actors
    /// (the LSP pool) internally — no host state is touched off-actor.
    public struct AsyncHostBox: @unchecked Sendable {
        public let host: AutomationHost
        public init(_ host: AutomationHost) { self.host = host }
    }

    /// The async lane's dispatcher — the counterpart of `dispatch` for
    /// `isAsyncTool` names.
    public nonisolated static func dispatchAsync(
        name: String,
        args: MCP.Value,
        host: AsyncHostBox
    ) async throws -> MCP.Value {
        switch name {
        case "who_calls":
            let symbol = try args.string("symbol")
            guard let result = await host.host.automationWhoCalls(symbol: symbol) else {
                throw MCPError.toolFailed(
                    "no definition found for '\(symbol)' — check the spelling, "
                    + "and that a language server is running for that language "
                    + "(open a file of that type to warm the LSP pool)")
            }
            return CodeNav.format(result)
        case "goto_definition", "find_references":
            let file = try args.string("file")
            let line = try args.int("line")
            let column = try args.int("column")
            guard line >= 1, column >= 1 else {
                throw MCPError.invalidParams("line and column are 1-based (got \(line):\(column))")
            }
            // Convert to LSP-native 0-based for the host.
            let result: CodeNav.NavLocations?
            if name == "goto_definition" {
                result = await host.host.automationDefinition(
                    file: file, line: line - 1, character: column - 1)
            } else {
                result = await host.host.automationReferences(
                    file: file, line: line - 1, character: column - 1)
            }
            guard let nav = result else {
                throw MCPError.toolFailed(
                    "no language server routed for '\(file)' — open a file of "
                    + "that type to warm the LSP pool, then retry")
            }
            return CodeNav.formatNav(nav)
        case "rename_symbol":
            let file = try args.string("file")
            let line = try args.int("line")
            let column = try args.int("column")
            let newName = try args.string("new_name")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let apply = (try? args.bool("apply")) ?? false
            guard line >= 1, column >= 1 else {
                throw MCPError.invalidParams("line and column are 1-based (got \(line):\(column))")
            }
            guard !newName.isEmpty else {
                throw MCPError.invalidParams("new_name must be a non-blank identifier")
            }
            guard let outcome = await host.host.automationRenameSymbol(
                file: file, line: line - 1, character: column - 1,
                newName: newName, apply: apply)
            else {
                throw MCPError.toolFailed(
                    "no language server routed for '\(file)' — open a file of "
                    + "that type to warm the LSP pool, then retry")
            }
            return CodeNav.formatRename(outcome)
        case "run_task":
            return try await runTask(args)
        case "move_file":
            let from = try args.string("from")
            let to = try args.string("to")
            let apply = (try? args.bool("apply")) ?? false
            // Both endpoints jail-validated: the source must exist; for the
            // destination (which doesn't exist yet — that's the point, and
            // the mover creates intermediate dirs) validate the DEEPEST
            // EXISTING ancestor.
            _ = try validatedExistingURL(from: from)
            let toURL = URL(fileURLWithPath: (to as NSString).expandingTildeInPath)
            var ancestor = toURL.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: ancestor.path),
                  ancestor.pathComponents.count > 1 {
                ancestor = ancestor.deletingLastPathComponent()
            }
            _ = try validatedExistingURL(from: ancestor.path)
            guard from != to else {
                throw MCPError.invalidParams("from and to are the same path")
            }
            guard let outcome = await host.host.automationMoveFile(
                from: from, to: toURL.path, apply: apply)
            else {
                throw MCPError.toolFailed("move backend unavailable on this host")
            }
            return CodeNav.formatMove(outcome)
        default:
            throw MCPError.notFound("unknown async tool: \(name)")
        }
    }

    /// TSK-1562 — resolve the id against a FRESH discovery pass (the
    /// allowlist), spawn shell-free through /usr/bin/env, and return the
    /// bounded outcome. Runs detached so a long task never blocks the MCP
    /// reader's executor thread.
    private nonisolated static func runTask(_ args: MCP.Value) async throws -> MCP.Value {
        let path = try args.string("path")
        let id = try args.string("id")
        let requested = TimeInterval((try? args.int("timeout_seconds")) ?? Int(runTaskDefaultTimeout))
        let timeout = min(max(requested, 1), runTaskMaxTimeout)
        let root = try validatedExistingURL(from: path)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        guard let task = tasks.first(where: { $0.id == id }) else {
            let available = tasks.map(\.id).sorted().joined(separator: ", ")
            throw MCPError.toolFailed(
                "no runnable task '\(id)' at \(root.path) — only tasks reported "
                + "by list_runnable_tasks can run. Available: "
                + (available.isEmpty ? "(none discovered)" : available))
        }
        let spec = RunSpec.build(for: task)
        let result = try await Task.detached(priority: .utility) {
            let process = Process()
            // Shell-free spawn: /usr/bin/env resolves the driver on PATH and
            // execs the tokenized argv — no shell ever interprets anything.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = spec.argv
            process.currentDirectoryURL = spec.workingDirectory
            if !spec.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(spec.environment) { _, new in new }
            }
            return try ProcessRunner.run(
                process, timeout: timeout, maxOutputBytes: runTaskMaxOutputBytes)
        }.value
        return .object([
            "id": .string(task.id),
            "command": .string(spec.shellCommandLine),
            "exitCode": .int(Int(result.terminationStatus)),
            "timedOut": .bool(result.timedOut),
            "truncated": .bool(result.truncated),
            "stdout": .string(String(decoding: result.stdout, as: UTF8.self)),
            "stderr": .string(String(decoding: result.stderr, as: UTF8.self)),
        ])
    }

    private static let findDescriptor = MCP.ToolDescriptor(
        name: "find",
        description: "Search the current tab's text. Returns up to 1000 matches.",
        inputSchema: schema([
            "query":         .object(["type": .string("string")]),
            "regex":         .object(["type": .string("boolean")]),
            "caseSensitive": .object(["type": .string("boolean")]),
            "wholeWord":     .object(["type": .string("boolean")]),
        ], required: ["query"])
    )

    private static func find(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let q = try args.string("query")
        let regex = (try? args.bool("regex")) ?? false
        let cs = (try? args.bool("caseSensitive")) ?? false
        let ww = (try? args.bool("wholeWord")) ?? false
        if regex {
            // Pre-validate the pattern HERE, before handing it to
            // `automationFind`. The host's `FindEngine` throws on a bad
            // (or ReDoS-unsafe) pattern, but `automationFind` maps that
            // throw to `[]` — so without this guard a syntactically
            // invalid regex is indistinguishable from a genuine no-match
            // (`total:0`). Mirror `FindEngine.makeRegex`'s two-stage
            // check so the JSON-RPC error path fires instead: first the
            // ReDoS complexity guard, then the actual compile. The
            // whole-word `\b…\b` wrap the engine adds is always valid
            // around a compilable pattern, so compiling the raw pattern
            // is sufficient to detect a syntax error.
            if let reason = RegexComplexityGuard.reject(q) {
                throw MCPError.invalidParams("unsafe regex: \(reason)")
            }
            do {
                _ = try NSRegularExpression(pattern: q)
            } catch {
                throw MCPError.invalidParams("invalid regex: \(q)")
            }
        }
        let query = FindQuery(
            pattern: q,
            kind: regex ? .regex : .literal,
            caseSensitive: cs,
            wholeWord: ww
        )
        let matches = host.automationFind(query)
        // Cap result size — a regex like `.` against a 1 MB file is a
        // foot-gun if we serialise every char.
        let cap = 1_000
        let truncated = Array(matches.prefix(cap))
        let arr: [MCP.Value] = truncated.map { m in
            .object([
                "line":     .int(m.line),
                "column":   .int(m.column),
                "location": .int(m.range.location),
                "length":   .int(m.range.length),
            ])
        }
        return .object([
            "matches": .array(arr),
            "truncated": .bool(matches.count > cap),
            "total": .int(matches.count),
        ])
    }

    // MARK: - search_files

    /// Hard ceiling on the `maxResults` an agent may request, regardless of
    /// what it passes. Mirrors the `find` tool's 1000-match serialisation cap
    /// — a single tool call should never serialise an unbounded result set
    /// over the wire. Clamped (not rejected) so an over-eager request still
    /// succeeds with a sane bound.
    static let searchFilesResultCeiling = 1_000

    private static let searchFilesDescriptor = MCP.ToolDescriptor(
        name: "search_files",
        description: """
            Global / cross-file text search (grep) under a folder. Returns \
            matches grouped by file, with 1-based line numbers and full line \
            content. Skips binary files, VCS/build dirs (.git, node_modules, \
            .build, …) and files over 2 MiB. The root must be inside the \
            user's home directory.
            """,
        inputSchema: schema([
            "root": .object(["type": .string("string"),
                             "description": .string("Folder to search, absolute or ~-expanded. Must exist and be inside the user's home.")]),
            "query": .object(["type": .string("string"),
                              "description": .string("Text (or regex when regex:true) to search for.")]),
            "regex": .object(["type": .string("boolean"),
                              "description": .string("Treat query as a regular expression (ReDoS-guarded). Default false.")]),
            "caseSensitive": .object(["type": .string("boolean"),
                                      "description": .string("Default false.")]),
            "filenamesOnly": .object(["type": .string("boolean"),
                                      "description": .string("Match file NAMES only, never file bodies (cheap over large trees). Default false.")]),
            "maxResults": .object(["type": .string("integer"),
                                   "description": .string("Total match cap (clamped to 1000). Default 500.")]),
        ], required: ["root", "query"])
    )

    private static func searchFiles(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let rootPath = try args.string("root")
        let query = try args.string("query")
        guard !query.isEmpty else {
            throw MCPError.invalidParams("query must not be empty")
        }
        let regex = (try? args.bool("regex")) ?? false
        let cs = (try? args.bool("caseSensitive")) ?? false
        let filenamesOnly = (try? args.bool("filenamesOnly")) ?? false

        // Reuse the home/temp jail the rest of the catalog enforces — and
        // require the root to be an existing DIRECTORY (a file root is a
        // client error, not an empty result).
        let root = try validatedExistingURL(from: rootPath)
        let isDir = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory ?? false
        guard isDir else {
            throw MCPError.invalidParams("root is not a directory: \(root.path)")
        }

        // Pre-validate a regex the SAME way `find` does so a bad/unsafe
        // pattern surfaces as an MCP error rather than a silent zero-match
        // (the engine maps a rejected pattern to `[]`, indistinguishable
        // from a genuine no-match). `validateRegex` runs the ReDoS guard
        // then a compile.
        if regex, let reason = CrossFileSearch.validateRegex(query, caseSensitive: cs) {
            throw MCPError.invalidParams("invalid regex: \(reason)")
        }

        // Clamp the result cap to the wire ceiling. A non-positive request
        // is meaningless — fall back to the engine default.
        let requested = args.optionalInt("maxResults")
        let maxResults: Int
        if let r = requested, r > 0 {
            maxResults = min(r, searchFilesResultCeiling)
        } else {
            maxResults = min(CrossFileSearch.Options().maxResults, searchFilesResultCeiling)
        }
        var options = CrossFileSearch.Options()
        options.caseSensitive = cs
        options.useRegex = regex
        options.maxResults = maxResults

        let fileMatches = filenamesOnly
            ? CrossFileSearch.searchFilenames(root: root, query: query, options: options)
            : CrossFileSearch.search(root: root, query: query, options: options)

        var totalMatches = 0
        let files: [MCP.Value] = fileMatches.map { fm in
            let matchValues: [MCP.Value] = fm.matches.map { m in
                totalMatches += 1
                return .object([
                    "line": .int(m.lineNumber),
                    "text": .string(m.line),
                ])
            }
            // filenamesOnly hits carry no line matches but ARE a result — count
            // the file itself so `total` is non-zero for a filename-only search.
            if fm.matches.isEmpty { totalMatches += 1 }
            return .object([
                "path": .string(fm.url.path),
                "matches": .array(matchValues),
            ])
        }

        return .object([
            "files": .array(files),
            "fileCount": .int(fileMatches.count),
            "total": .int(totalMatches),
            // The engine halts the walk at `maxResults`; report whether the
            // cap was hit so the agent knows the result set may be partial.
            "truncated": .bool(totalMatches >= maxResults),
        ])
    }

    // MARK: - goto_line

    private static let gotoLineDescriptor = MCP.ToolDescriptor(
        name: "goto_line",
        description: "Scroll the source view to a 1-based line. Optional column is advisory.",
        inputSchema: schema([
            "line":   .object(["type": .string("integer")]),
            "column": .object(["type": .string("integer")]),
        ], required: ["line"])
    )

    private static func gotoLine(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let line = try args.int("line")
        guard line > 0 else { throw MCPError.invalidParams("line must be >= 1") }
        let column = args.optionalInt("column")
        host.automationGotoLine(line, column: column)
        return .object(["line": .int(line)])
    }

    // MARK: - visible_text

    private static let visibleTextDescriptor = MCP.ToolDescriptor(
        name: "visible_text",
        description: "Return the text content of the currently-selected tab (10 MB cap).",
        inputSchema: emptySchema
    )

    private static func visibleText(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let text = host.automationVisibleText()
        // Final UTF-8 byte-length cap — host should already enforce
        // but belt-and-braces protects against future impl drift.
        let byteCount = text.utf8.count
        if byteCount > AutomationLimits.visibleTextMaxBytes {
            let cap = AutomationLimits.visibleTextMaxBytes
            // Byte-exact, code-point-boundary-correct truncation. We keep the
            // longest prefix of at most `cap` bytes that ends on a UTF-8 scalar
            // boundary. The boundary test is the byte AT the cut point (the
            // first EXCLUDED byte): a UTF-8 continuation byte is 0b10xxxxxx
            // (0x80...0xBF), so if `head[cap]` is a continuation byte the scalar
            // it belongs to straddles the cap and we must back the cut up past
            // its (≤3) continuation bytes to the scalar's lead. A complete
            // scalar ending exactly at the cap is therefore KEPT (its cut byte
            // is the next scalar's lead, not a continuation byte). Testing
            // `head[boundary - 1]` instead would wrongly chop a complete
            // trailing rune (its final byte is itself a continuation byte) and,
            // for a straddler, stop one byte late — overshooting the cap and
            // emitting U+FFFD. Take `cap + 1` bytes so the cut byte is in hand
            // without materializing the whole (multi-MB) string.
            let head = Array(text.utf8.prefix(cap + 1))
            var boundary = cap
            while boundary > 0, head[boundary] & 0b1100_0000 == 0b1000_0000 {
                boundary -= 1
            }
            let truncated = String(decoding: head[..<boundary], as: UTF8.self)
            return .object([
                "text": .string(truncated),
                "truncated": .bool(true),
                "totalBytes": .int(byteCount),
            ])
        }
        return .object([
            "text": .string(text),
            "truncated": .bool(false),
            "totalBytes": .int(byteCount),
        ])
    }

    // MARK: - outline

    private static let outlineDescriptor = MCP.ToolDescriptor(
        name: "outline",
        description: "Return the Markdown heading outline of the currently-selected tab as "
            + "[{level (1-6), title, line (1-based)}] — for agent navigation / jump-to-heading. "
            + "Empty for non-Markdown content.",
        inputSchema: emptySchema
    )

    /// Surfaces the built-but-unconsumed `MarkdownOutline` parser (TSK-511) as an
    /// agent-drivable read tool: the document's heading TOC, so an agent can
    /// `goto_line` to a section instead of full-text scanning. Pure read over the
    /// active tab's text; output capped so a pathological all-headings document
    /// can't return an unbounded payload.
    private static func outline(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let headings = MarkdownOutline.headings(in: host.automationVisibleText())
        let cap = 5000
        let items = headings.prefix(cap).map { h in
            MCP.Value.object([
                "level": .int(h.level),
                "title": .string(h.title),
                "line": .int(h.line),
            ])
        }
        return .object([
            "headings": .array(Array(items)),
            "count": .int(headings.count),
            "truncated": .bool(headings.count > cap),
        ])
    }

    // MARK: - git_status

    private static let gitStatusDescriptor = MCP.ToolDescriptor(
        name: "git_status",
        description: "Return the git context of the open workspace root: { isRepo, root, branch }. "
            + "Reads .git/HEAD directly (no subprocess, never throws); branch is omitted for a "
            + "detached HEAD or a non-repo root.",
        inputSchema: emptySchema
    )

    /// Wrap-a-host-reader (like outline/process_memory): the open workspace's git
    /// badge via SessionGitInfo (reads .git/HEAD directly, no subprocess). Gives
    /// an agent the repo/branch context without spawning git.
    private static func gitStatus(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let root = host.automationCurrentState().sidebarRoot
        let badge = SessionGitInfo.badge(forRootPath: root)
        var obj: [String: MCP.Value] = ["isRepo": .bool(badge.isRepoRoot)]
        if let root { obj["root"] = .string(root) }
        if let branch = badge.branch { obj["branch"] = .string(branch) }
        return .object(obj)
    }

    // MARK: - run_verb

    private static let runVerbDescriptor = MCP.ToolDescriptor(
        name: "run_verb",
        description: "Dispatch a script-verb — the public agent ACTION surface (~60 verbs: "
            + "edit-*, focus-*, view toggles, git/terminal/tab/session actions). `verb` is the "
            + "token, optionally with a trailing argument (e.g. \"edit-uppercase\" or "
            + "\"goto-line 42\"). Only catalogued verbs run. Returns { handled, verb }.",
        inputSchema: schema(["verb": .object([
            "type": .string("string"),
            "description": .string("A ScriptVerbCatalog token, optionally with a trailing arg."),
        ])], required: ["verb"])
    )

    /// P0a — the script-verb bus as the public agent ACTION surface. Validates the
    /// token against ScriptVerbCatalog (only known verbs run; an unknown token is
    /// rejected before the host is ever touched) and dispatches the full line via
    /// the host (→ ScriptVerb.apply, the same surface the palette / --script use).
    private static func runVerb(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let line = try args.string("verb")
        let token = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
        guard ScriptVerbCatalog.tokens.contains(token) else {
            throw MCPError.invalidParams("unknown script verb: \(token)")
        }
        let handled = host.automationRunVerb(line)
        return .object(["handled": .bool(handled), "verb": .string(token)])
    }

    // MARK: - list_verbs

    private static let listVerbsDescriptor = MCP.ToolDescriptor(
        name: "list_verbs",
        description: "List every catalogued script verb — the run_verb ACTION vocabulary — as "
            + "[{verb, surface, arg, summary}], so an agent can DISCOVER the available actions "
            + "instead of guessing tokens. `arg` is none|path|int|string|enumToken|structured. "
            + "Read-only; the companion of run_verb.",
        inputSchema: emptySchema
    )

    /// Discoverability for the action surface: run_verb EXECUTES a verb but, until
    /// now, nothing ENUMERATED them — an agent had to know the tokens. Returns the
    /// full ScriptVerbCatalog (token + surface + arg shape + summary) so the agent
    /// can self-describe what it can do. Pure read of the static catalog.
    private static func listVerbs(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let verbs: [MCP.Value] = ScriptVerbCatalog.all.map { v in
            .object([
                "verb": .string(v.token),
                "surface": .string(v.surface.rawValue),
                "arg": .string(v.arg.rawValue),
                "summary": .string(v.summary),
            ])
        }
        return .object([
            "verbs": .array(verbs),
            "count": .int(ScriptVerbCatalog.all.count),
        ])
    }

    // MARK: - list_surfaces

    private static let listSurfacesDescriptor = MCP.ToolDescriptor(
        name: "list_surfaces",
        description: "List the agent-addressable UI surfaces — the curated mdv.* AX identifier "
            + "contract — as [{id, surface, summary}], so an agent can DISCOVER what it can "
            + "address (for element references / Copy-Reference and the native-chrome driver). "
            + "Read-only; the addressing companion of list_verbs (actions).",
        inputSchema: emptySchema
    )

    /// Discoverability for the ADDRESSING surface — the sibling of list_verbs:
    /// returns the curated AXIdentifierCatalog (every stable top-level mdv.* id +
    /// its surface group + summary) so an agent can self-describe what it can
    /// reference/address. Pure read of the static catalog.
    private static func listSurfaces(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let surfaces: [MCP.Value] = AXIdentifierCatalog.critical.map { e in
            .object([
                "id": .string(e.id),
                "surface": .string(e.surface.rawValue),
                "summary": .string(e.summary),
            ])
        }
        return .object([
            "surfaces": .array(surfaces),
            "count": .int(AXIdentifierCatalog.critical.count),
        ])
    }

    // MARK: - lint

    private static let lintDescriptor = MCP.ToolDescriptor(
        name: "lint",
        description: "Lint the currently-selected tab as Markdown — returns [{rule, line, message}] "
            + "for image-alt (missing alt text), heading-skip (H-level jumps, e.g. H1→H3), and "
            + "dup-anchor (duplicate heading slugs). Empty for clean / non-Markdown content.",
        inputSchema: emptySchema
    )

    /// Surfaces the built MarkdownLint engine (image-alt / heading-skip /
    /// dup-anchor) as an agent read tool — an agent authoring Markdown can check
    /// its own edits. Output capped defensively.
    private static func lint(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let issues = MarkdownLint.lint(host.automationVisibleText())
        let cap = 2000
        let items = issues.prefix(cap).map { issue in
            MCP.Value.object([
                "rule": .string(issue.rule),
                "line": .int(issue.line),
                "message": .string(issue.message),
            ])
        }
        return .object([
            "issues": .array(Array(items)),
            "count": .int(issues.count),
            "truncated": .bool(issues.count > cap),
        ])
    }

    // MARK: - current_state

    private static let currentStateDescriptor = MCP.ToolDescriptor(
        name: "current_state",
        description: "Snapshot of the app: tab list, selected index, view mode, zoom, sidebar root, palette state.",
        inputSchema: emptySchema
    )

    private static func currentState(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let state = host.automationCurrentState()
        return try MCPServer.encodeValue(state)
    }

    // MARK: - toggle_bookmark

    private static let toggleBookmarkDescriptor = MCP.ToolDescriptor(
        name: "toggle_bookmark",
        description: "Toggle a bookmark on the current tab. Omit line for a file-level bookmark.",
        inputSchema: schema([
            "line": .object(["type": .string("integer")]),
        ])
    )

    private static func toggleBookmark(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let line = args.optionalInt("line")
        if let line, line < 1 {
            throw MCPError.invalidParams("line must be >= 1")
        }
        host.automationToggleBookmark(line: line)
        return .object(["ok": .bool(true)])
    }

    // MARK: - list_bookmarks

    private static let listBookmarksDescriptor = MCP.ToolDescriptor(
        name: "list_bookmarks",
        description: "All persisted bookmarks. Path-only and line-scoped entries are both returned.",
        inputSchema: emptySchema
    )

    private static func listBookmarks(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let entries = host.automationListBookmarks()
        let arr: [MCP.Value] = entries.map { b in
            var obj: [String: MCP.Value] = [
                "path": .string(b.url.path),
                "displayName": .string(b.displayName),
                "addedAt": .string(ISO8601DateFormatter().string(from: b.addedAt)),
            ]
            if let l = b.line { obj["line"] = .int(l) }
            return .object(obj)
        }
        return .object(["bookmarks": .array(arr)])
    }

    // MARK: - snapshot_window

    private static let snapshotWindowDescriptor = MCP.ToolDescriptor(
        name: "snapshot_window",
        description: "Capture the main window to PNG. Returns base64-encoded bytes.",
        inputSchema: emptySchema
    )

    private static func snapshotWindow(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let png: Data
        do {
            png = try host.automationSnapshotPNG()
        } catch {
            throw MCPError.toolFailed("snapshot failed: \(error)")
        }
        // Base64 keeps the wire format pure JSON. Clients that want
        // raw bytes can decode locally. (MCP supports an `image`
        // content block too, but v1 sticks to text + base64 for
        // simpler client parsing.)
        return .object([
            "pngBase64": .string(png.base64EncodedString()),
            "bytes": .int(png.count),
        ])
    }

    // MARK: - list_runnable_tasks

    private static let listRunnableTasksDescriptor = MCP.ToolDescriptor(
        name: "list_runnable_tasks",
        description: "List the runnable tasks (package.json scripts, Cargo targets, Makefile targets, common test commands) discovered in a project directory. Read-only — scans manifests, runs nothing.",
        inputSchema: schema([
            "path": .object(["type": .string("string"),
                             "description": .string("Absolute or ~-expanded path to the project root directory to scan")]),
        ], required: ["path"])
    )

    private static func listRunnableTasks(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let path = try args.string("path")
        let root = try validatedExistingURL(from: path)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        let items: [MCP.Value] = tasks.map { t in
            .object([
                "id": .string(t.id),
                "name": .string(t.name),
                "source": .string(t.source.rawValue),
                "command": .string(t.command),
                "arguments": .array(t.arguments.map { MCP.Value.string($0) }),
            ])
        }
        return .object([
            "count": .int(tasks.count),
            "tasks": .array(items),
        ])
    }

    // MARK: - review read-tools (TSK-1563, agent-services s4 — READ-ONLY)

    private static let getReviewContextDescriptor = MCP.ToolDescriptor(
        name: "get_review_context",
        description: "READ-ONLY: the assembled Q&A context for a code review "
            + "(title, scope, every comment with its severity, anchor, body, "
            + "and frozen diff hunk — size-bounded). Defaults to the most "
            + "recently updated review; pass review_id to pick one. The "
            + "payload lists the other available reviews.",
        inputSchema: schema([
            "review_id":  .object(["type": .string("string")]),
            "question":   .object(["type": .string("string"),
                                   "description": .string("Optional question to frame the context for")]),
            "store_path": .object(["type": .string("string"),
                                   "description": .string("Optional review-store directory override (defaults to the app store)")]),
        ], required: [])
    )

    private static let listReviewCommentsDescriptor = MCP.ToolDescriptor(
        name: "list_review_comments",
        description: "READ-ONLY: the raw comment list of a code review "
            + "(including replies), with ids, anchors, severities, and "
            + "resolved flags. Defaults to the most recently updated review.",
        inputSchema: schema([
            "review_id":  .object(["type": .string("string")]),
            "store_path": .object(["type": .string("string")]),
        ], required: [])
    )

    /// The store to read: an explicit (jail-validated) override, else the
    /// app's default directory.
    private static func reviewStore(from args: MCP.Value) throws -> ReviewStore {
        if let p = try? args.string("store_path") {
            return ReviewStore(directory: try validatedExistingURL(from: p))
        }
        return ReviewStore()
    }

    /// Resolve the target review: explicit id, else the most recently
    /// updated. Failures name what IS available.
    private static func resolveReview(_ args: MCP.Value, store: ReviewStore) throws -> Review {
        let summaries = store.list()
        if let id = try? args.string("review_id") {
            guard let r = store.load(id: id) else {
                let available = summaries.map(\.id).joined(separator: ", ")
                throw MCPError.toolFailed(
                    "no review '\(id)' in the store — available: "
                    + (available.isEmpty ? "(none)" : available))
            }
            return r
        }
        guard let latest = summaries.max(by: { $0.updatedAt < $1.updatedAt }),
              let r = store.load(id: latest.id) else {
            throw MCPError.toolFailed("no reviews in the store")
        }
        return r
    }

    private static func getReviewContext(_ args: MCP.Value) throws -> MCP.Value {
        let store = try reviewStore(from: args)
        let review = try resolveReview(args, store: store)
        let question = (try? args.string("question")) ?? "What does this review contain?"
        let ctx = ReviewQAContext.build(review: review, question: question)
        let others = store.list().filter { $0.id != review.id }
        return .object([
            "reviewID": .string(ctx.reviewID),
            "title": .string(ctx.reviewTitle),
            "description": .string(ctx.reviewDescription ?? ""),
            "scope": .string(ctx.scopeSummary),
            "repoRoot": .string(ctx.repoRoot),
            "commentCount": .int(ctx.comments.count),
            "droppedComments": .int(ctx.droppedCommentCount),
            "comments": .array(ctx.comments.map { item in
                .object([
                    "id": .string(item.commentID),
                    "file": .string(item.filePath),
                    "severity": .string(item.severity.rawValue),
                    "resolved": .bool(item.resolved),
                    "lines": .string("\(item.anchor.startLine)-\(item.anchor.endLine) (\(item.anchor.side.rawValue))"),
                    "body": .string(item.body),
                    "hunkHeader": .string(item.hunkHeader),
                    "hunk": .string(item.hunkText),
                ])
            }),
            "availableReviews": .array(others.map {
                .object(["id": .string($0.id), "title": .string($0.title)])
            }),
        ])
    }

    private static func listReviewComments(_ args: MCP.Value) throws -> MCP.Value {
        let store = try reviewStore(from: args)
        let review = try resolveReview(args, store: store)
        return .object([
            "reviewID": .string(review.id),
            "title": .string(review.title),
            "count": .int(review.comments.count),
            "comments": .array(review.comments.map { c in
                .object([
                    "id": .string(c.id),
                    "parentId": .string(c.parentId ?? ""),
                    "file": .string(c.filePath),
                    "severity": .string(c.severity.rawValue),
                    "resolved": .bool(c.resolved),
                    "lines": .string("\(c.anchor.startLine)-\(c.anchor.endLine) (\(c.anchor.side.rawValue))"),
                    "body": .string(c.body),
                ])
            }),
        ])
    }

    // MARK: - process_memory

    private static let processMemoryDescriptor = MCP.ToolDescriptor(
        name: "process_memory",
        description: "Report the app process's OS-level memory: appFootprintBytes = phys_footprint (the CORRECT metric — includes compressed memory; NOT VSZ/RSS) of the main process, plus the summed WebKit helper-process footprint. Read-only; no args.",
        inputSchema: emptySchema
    )

    private static func processMemory(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let s = ProcessMemory.sample()
        var obj: [String: MCP.Value] = [
            "webKitHelperBytes": .int(Int(s.webKitHelperBytes)),
            "webKitHelperCount": .int(s.webKitHelperCount),
            "helpersComplete": .bool(s.helpersComplete),
        ]
        // nil only on a kernel-status failure (surfaced as absent, not a fabricated 0).
        if let app = s.appFootprintBytes { obj["appFootprintBytes"] = .int(Int(app)) }
        return .object(obj)
    }

    // MARK: - Validation

    /// Validates a path arg per design §8:
    ///   - resolves `~` and relative components
    ///   - must exist
    ///   - must be inside the user's home directory (rejects /etc/...,
    ///     /System/..., other users' homes — the viewer is for the
    ///     current user's files only).
    /// nonisolated: pure path/filesystem logic — shared by the sync
    /// dispatch AND the async lane's `run_task` (TSK-1562).
    private nonisolated static func validatedExistingURL(from path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        // Resolve symlinks so the containment check is physical-to-physical.
        // `standardizedFileURL` only collapses `..`/`.` LEXICALLY; an in-jail
        // symlink (e.g. `~/link -> /etc`) would otherwise pass `hasPrefix(home)`
        // and let MCP `read_file`/`open` reach the out-of-jail target — the same
        // symlink-escape the URLSchemePolicy fence closes. Resolving both operands
        // keeps it honest (AUDIT S3 — this is the MCP-validator prong of that
        // finding). `resolvingSymlinksInPath()` on a path whose leaf doesn't yet
        // exist resolves the existing leading components and leaves the rest
        // verbatim, and we require existence below anyway.
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL.resolvingSymlinksInPath().path
        // Allow paths under the user's home, plus the per-user temp dir (also
        // under /var/folders, owned by user) which is where `mdv -` stashes
        // stdin and where tests stage scratch files. ANCHORED prefixes only:
        // `temp` does NOT end in `/`, so a bare `hasPrefix(temp)` would admit a
        // user-writable SIBLING like `/var/folders/<rand>/T-attacker/loot`
        // (AUDIT S3). Containment is checked BEFORE existence so an out-of-jail
        // path can't be probed via the differential notFound/permissionDenied
        // error (existence oracle).
        let temp = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let underHome = url.path == home || url.path.hasPrefix(home + "/")
        let underTemp = url.path == temp || url.path.hasPrefix(temp + "/")
        guard underHome || underTemp else {
            throw MCPError.permissionDenied(
                "path is outside the user's home directory: \(url.path)")
        }
        guard fm.fileExists(atPath: url.path) else {
            throw MCPError.notFound("path does not exist: \(url.path)")
        }
        return url
    }

    // MARK: - canvas_* (M2 agent surface — TSK-1368; docs/canvas/plans/M2-PLAN.md)

    /// The short grammar header embedded in tool descriptions (07-DSL-SPIKE:
    /// the cheat-sheet leads, canvas_vocab carries the full vocabulary).
    private static let canvasDSLHint = """
        DSL: `<kind> [#id] ["text"] [prop=value …] [{` …children… `}` — kinds: \
        frame/text/image/shape/component/embed/hole; edits: set/unset/move/remove #id; \
        values: 8, "str", true, $token.path. Call canvas_vocab for the FULL vocabulary.
        """

    private static let canvasNewDescriptor = MCP.ToolDescriptor(
        name: "canvas_new",
        description: "Create an empty canvas document (default theme, root page pg:1). "
            + "mode: \"ui-design\" seeds the UI-Design workspace (starter kit + "
            + "artboards; template: desktop|mobile|both, default both). "
            + "Returns {doc, rev}. " + canvasDSLHint,
        inputSchema: schema([
            "mode":     .object(["type": .string("string")]),
            "template": .object(["type": .string("string")]),
            "slides":   .object(["type": .string("integer")]),
        ])
    )

    private static func canvasNew(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        do {
            let doc = try host.automationCanvasStore.create()
            switch (try? args.string("mode")) {
            case "ui-design":
                let template = (try? args.string("template"))
                    .flatMap(CanvasUIDesignMode.Template.init(rawValue:)) ?? .both
                try CanvasUIDesignMode.seed(into: doc, template: template)
            case "presentation":
                let slides = (try? args.int("slides")) ?? 3
                try CanvasPresentationMode.seed(into: doc, slides: slides)
            default:
                break
            }
            return .object(["doc": .string(doc.id), "rev": .int(Int(doc.lastKnownRev))])
        } catch {
            throw MCPError.toolFailed("canvas_new: \(error)")
        }
    }

    private static let canvasOpenDescriptor = MCP.ToolDescriptor(
        name: "canvas_open",
        description: "Open a .canvas file (deduped: one doc per file). Returns {doc, rev}.",
        inputSchema: schema([
            "path": .object(["type": .string("string"),
                             "description": .string("Path to a .canvas file")]),
        ], required: ["path"])
    )

    private static func canvasOpen(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let path = try args.string("path")
        let url = try validatedExistingURL(from: path)
        do {
            let doc = try host.automationCanvasStore.open(url: url)
            return .object(["doc": .string(doc.id), "rev": .int(Int(doc.lastKnownRev))])
        } catch let e as CanvasStoreError {
            throw MCPError.invalidParams(canvasStoreErrorMessage(e))
        }
    }

    private static let canvasSaveDescriptor = MCP.ToolDescriptor(
        name: "canvas_save",
        description: "Save a canvas doc — to its file, or to `path` (untitled docs "
            + "require path; the doc id re-keys to the path). Returns {doc, path}.",
        inputSchema: schema([
            "doc":  .object(["type": .string("string")]),
            "path": .object(["type": .string("string"),
                             "description": .string("Target .canvas path (optional when file-backed)")]),
        ], required: ["doc"])
    )

    private static func canvasSave(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let id = try args.string("doc")
        let path = try? args.string("path")
        do {
            let target = try host.automationCanvasStore.save(
                id, to: path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            let newID = CanvasDocumentStore.docID(for: target)
            return .object(["doc": .string(newID), "path": .string(target.path)])
        } catch let e as CanvasStoreError {
            throw MCPError.invalidParams(canvasStoreErrorMessage(e))
        }
    }

    private static let canvasApplyDescriptor = MCP.ToolDescriptor(
        name: "canvas_apply",
        description: "Apply a canvas DSL fragment (inserts under the root page; "
            + "set/unset/move/remove statements for edits) against baseRev. Returns "
            + "{rev, applied, minted, noop, lint} on success or {rejected, detail, "
            + "currentRev} — a rejection is DATA, not an error: read detail, fix, retry. "
            + canvasDSLHint,
        inputSchema: schema([
            "doc":     .object(["type": .string("string")]),
            "baseRev": .object(["type": .string("integer"),
                                "description": .string("The revision this edit is based on")]),
            "dsl":     .object(["type": .string("string")]),
        ], required: ["doc", "baseRev", "dsl"])
    )

    private static func canvasApply(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let id = try args.string("doc")
        let baseRev = try args.int("baseRev")
        let dsl = try args.string("dsl")
        let doc = try canvasDoc(id, host)
        do {
            let applied = try doc.adapter.applyDSL(baseRev: UInt64(baseRev), dsl)
            doc.lastKnownRev = applied.rev
            let lint: [MCP.Value] = applied.lint.map { f in
                .object([
                    "severity": .string(f.severity),
                    "code": .string(f.code),
                    "id": f.id.map { MCP.Value.string($0) } ?? .null,
                    "message": .string(f.message),
                ])
            }
            return .object([
                "rev": .int(Int(applied.rev)),
                "applied": .int(applied.patches.count),
                "minted": .array(applied.minted.map { .string($0) }),
                "noop": .bool(applied.noop),
                "lint": .array(lint),
            ])
        } catch let rejection as CanvasRejection {
            return .object([
                "rejected": .string(rejection.kind),
                "detail": .string(rejection.detail),
                "currentRev": .int(Int(rejection.currentRev)),
            ])
        }
    }

    /// Shared doc lookup with the store's teaching message.
    private static func canvasDoc(
        _ id: String, _ host: AutomationHost
    ) throws -> CanvasOpenDocument {
        do {
            return try host.automationCanvasStore.doc(id)
        } catch let e as CanvasStoreError {
            throw MCPError.invalidParams(canvasStoreErrorMessage(e))
        }
    }

    private static func canvasStoreErrorMessage(_ e: CanvasStoreError) -> String {
        switch e {
        case .unknownDoc(let m), .notCanvasFile(let m), .loadFailed(let m),
             .saveFailed(let m), .untitledNeedsPath(let m):
            return m
        }
    }


    private static let canvasReadDescriptor = MCP.ToolDescriptor(
        name: "canvas_read",
        description: "Read a canvas doc back as canonical DSL — the whole page, or one "
            + "subtree via `anchor` (e.g. \"#hero\"). `format: \"json\"` returns the "
            + "canonical document JSON instead. Returns {dsl|json, rev}.",
        inputSchema: schema([
            "doc":    .object(["type": .string("string")]),
            "anchor": .object(["type": .string("string"),
                               "description": .string("#name of the subtree to slice")]),
            "format": .object(["type": .string("string"),
                               "description": .string("\"dsl\" (default) or \"json\"")]),
        ], required: ["doc"])
    )

    private static func canvasRead(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        let rev = MCP.Value.int(Int(doc.lastKnownRev))
        if (try? args.string("format")) == "json" {
            do {
                return .object(["json": .string(try doc.adapter.save()), "rev": rev])
            } catch {
                throw MCPError.toolFailed("canvas_read: \(error)")
            }
        }
        do {
            if let anchor = try? args.string("anchor") {
                let name = anchor.hasPrefix("#") ? String(anchor.dropFirst()) : anchor
                guard let slice = try doc.adapter.renderDSL(node: "nd:\(name)") else {
                    throw MCPError.invalidParams(
                        "no node '#\(name)' — canvas_read without anchor lists the page")
                }
                return .object(["dsl": .string(slice), "rev": rev])
            }
            return .object(["dsl": .string(try doc.adapter.renderDSL()), "rev": rev])
        } catch let e as MCPError {
            throw e
        } catch {
            throw MCPError.toolFailed("canvas_read: \(error)")
        }
    }

    private static let canvasVocabDescriptor = MCP.ToolDescriptor(
        name: "canvas_vocab",
        description: "The FULL canvas authoring vocabulary (generated from the live "
            + "registry — kinds, per-kind props with semantics, this doc's design tokens, "
            + "caps, rejection kinds). `format: \"json\"` for the structured form.",
        inputSchema: schema([
            "doc":    .object(["type": .string("string"),
                               "description": .string("Doc whose tokens to include (optional)")]),
            "format": .object(["type": .string("string")]),
        ])
    )

    private static func canvasVocab(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let asJSON = (try? args.string("format")) == "json"
        do {
            let adapter: CanvasDocAdapter
            if let id = try? args.string("doc") {
                adapter = try canvasDoc(id, host).adapter
            } else {
                adapter = try CanvasDocAdapter() // default-theme vocabulary
            }
            return .object(["vocabulary": .string(try adapter.vocabulary(asJSON: asJSON))])
        } catch let e as MCPError {
            throw e
        } catch {
            throw MCPError.toolFailed("canvas_vocab: \(error)")
        }
    }

    private static let canvasLintDescriptor = MCP.ToolDescriptor(
        name: "canvas_lint",
        description: "Full-document lint (advisory: token health, tier-2 steering, holes, "
            + "dangling refs, unclamped text). Returns {lint: [{severity, code, id, message}]}.",
        inputSchema: schema([
            "doc": .object(["type": .string("string")]),
        ], required: ["doc"])
    )

    private static func canvasLint(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        do {
            // Static stage (the engine) + the MEASURED stage (cached by the
            // rendered lens's controller — M4.S9). `measured` tells the
            // agent whether geometry findings are included or the doc is
            // unmounted.
            var findings = try doc.adapter.lintAll()
            let measured = doc.measuredLint
            findings.append(contentsOf: measured ?? [])
            let lint: [MCP.Value] = findings.map { f in
                .object([
                    "severity": .string(f.severity),
                    "code": .string(f.code),
                    "id": f.id.map { MCP.Value.string($0) } ?? .null,
                    "message": .string(f.message),
                ])
            }
            return .object([
                "lint": .array(lint),
                "measured": .bool(measured != nil),
            ])
        } catch {
            throw MCPError.toolFailed("canvas_lint: \(error)")
        }
    }

    private static let canvasUndoDescriptor = MCP.ToolDescriptor(
        name: "canvas_undo",
        description: "Undo the most recent applied batch (bounded history). Returns "
            + "{rev, undone}; undone=false means the history was empty. Re-read after.",
        inputSchema: schema([
            "doc": .object(["type": .string("string")]),
        ], required: ["doc"])
    )

    private static func canvasUndo(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        do {
            if let rev = try doc.adapter.undo() {
                doc.lastKnownRev = rev
                return .object(["rev": .int(Int(rev)), "undone": .bool(true)])
            }
            return .object(["rev": .int(Int(doc.lastKnownRev)), "undone": .bool(false)])
        } catch {
            throw MCPError.toolFailed("canvas_undo: \(error)")
        }
    }


    private static let canvasExportDescriptor = MCP.ToolDescriptor(
        name: "canvas_export",
        description: "Export a canvas doc as static HTML. flavor: \"standalone\" "
            + "(default; theme custom-property block + the lowered page — the B0 "
            + "tier, self-contained) or \"fragment\" (one artboard's subtree, NO "
            + "theme block, var(--cv-*) refs inlined as literals — embeddable in "
            + "an existing site). deck = a self-contained offline HTML deck (slides "
            + "+ inlined player, arrow-key nav, zero network). print = a paginated "
            + "print layout (one slide per page; File▸Print▸Save-as-PDF → PDF deck). fragment picks the "
            + "artboard arg (#id) or the first role=artboard node. Returns {path, bytes, flavor}.",
        inputSchema: schema([
            "doc":  .object(["type": .string("string")]),
            "path": .object(["type": .string("string"),
                             "description": .string("Output .html path")]),
            "flavor":   .object(["type": .string("string")]),
            "artboard": .object(["type": .string("string"),
                                 "description": .string("#id of the artboard (fragment)")]),
        ], required: ["doc", "path"])
    )

    private static func canvasExport(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        let path = try args.string("path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let flavor = (try? args.string("flavor")) ?? "standalone"
        do {
            let html: String
            switch flavor {
            case "standalone":
                html = try doc.adapter.html()
            case "fragment":
                let nodeID = try canvasFragmentTarget(args, doc)
                guard let fragment = try doc.adapter.renderFragment(node: nodeID) else {
                    throw MCPError.toolFailed(
                        "canvas_export: fragment target \(nodeID) not found")
                }
                html = fragment
            case "deck":
                html = try doc.adapter.exportDeckHTML()
            case "print":
                html = try doc.adapter.exportDeckPrintHTML()
            default:
                throw MCPError.toolFailed(
                    "canvas_export: flavor must be standalone|fragment|deck|print, got \(flavor)")
            }
            try EditorWriter.save(html, to: url)
            return .object([
                "path": .string(url.path),
                "bytes": .int(html.utf8.count),
                "flavor": .string(flavor),
            ])
        } catch let e as MCPError {
            throw e
        } catch {
            throw MCPError.toolFailed("canvas_export: \(error)")
        }
    }

    /// Resolve the fragment target: the explicit `artboard` arg (#id → nd:id)
    /// or the first role=artboard node in the outline.
    private static func canvasFragmentTarget(
        _ args: MCP.Value, _ doc: CanvasOpenDocument
    ) throws -> String {
        if let raw = try? args.string("artboard"), !raw.isEmpty {
            return raw.hasPrefix("nd:") ? raw
                : "nd:" + (raw.hasPrefix("#") ? String(raw.dropFirst()) : raw)
        }
        let root = try CanvasOutlineParser.parse(doc.adapter.save())
        if let board = firstArtboard(root) { return board.id }
        throw MCPError.toolFailed(
            "canvas_export: fragment needs an artboard — pass {artboard: \"#id\"} "
                + "or add a role=artboard frame")
    }

    private static func firstArtboard(_ node: CanvasOutlineNode) -> CanvasOutlineNode? {
        let isArtboard = node.props.contains {
            $0.name == "role" && $0.value == .str("artboard")
        }
        if isArtboard { return node }
        for child in node.children {
            if let hit = firstArtboard(child) { return hit }
        }
        return nil
    }


    private static let canvasKitImportDescriptor = MCP.ToolDescriptor(
        name: "canvas_kit_import",
        description: "Vendor the starter component kit into a canvas doc (6 components: "
            + "kit-card/button/badge/header/two-col/kpi — then `use #kit-card #my-card`). "
            + "Copies + pins by hash; a locally-EDITED kit component blocks re-import "
            + "(driftDetected=true, nothing overwritten). Returns {imported, driftDetected}.",
        inputSchema: schema([
            "doc": .object(["type": .string("string")]),
        ], required: ["doc"])
    )

    private static func canvasKitImport(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        do {
            let result = try CanvasStarterKit.importKit(into: doc)
            return .object([
                "imported": .bool(result.imported),
                "driftDetected": .bool(result.driftDetected),
            ])
        } catch {
            throw MCPError.toolFailed("canvas_kit_import: \(error)")
        }
    }


    private static let canvasTimelineDescriptor = MCP.ToolDescriptor(
        name: "canvas_timeline",
        description: "The deck's presentation timeline (M6): per role=slide frame, the "
            + "stepCount and, for each step, the visibleIds. This is the DECLARATIVE "
            + "verification surface — check step reveals here BEFORE any screenshot. "
            + "Returns {slides: [{id, stepCount, steps: [{step, visibleIds}]}]}.",
        inputSchema: schema([
            "doc": .object(["type": .string("string")]),
        ], required: ["doc"])
    )

    private static func canvasTimeline(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        do {
            let json = try doc.adapter.timelineJSON()
            guard let data = json.data(using: .utf8),
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let slides = obj["slides"] as? [[String: Any]]
            else { return .object(["slides": .array([])]) }
            let out: [MCP.Value] = slides.map { slide in
                let steps = (slide["steps"] as? [[String: Any]] ?? []).map { st -> MCP.Value in
                    let ids = (st["visibleIds"] as? [String] ?? []).map { MCP.Value.string($0) }
                    return .object([
                        "step": .int(st["step"] as? Int ?? 0),
                        "visibleIds": .array(ids),
                    ])
                }
                return .object([
                    "id": .string(slide["id"] as? String ?? ""),
                    "stepCount": .int(slide["stepCount"] as? Int ?? 0),
                    "steps": .array(steps),
                ])
            }
            return .object(["slides": .array(out)])
        } catch {
            throw MCPError.toolFailed("canvas_timeline: \(error)")
        }
    }

}
