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
    private static func validatedExistingURL(from path: String) throws -> URL {
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
            + "Returns {doc, rev}. " + canvasDSLHint,
        inputSchema: emptySchema
    )

    private static func canvasNew(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        _ = args
        do {
            let doc = try host.automationCanvasStore.create()
            return .object(["doc": .string(doc.id), "rev": .int(0)])
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
            let lint: [MCP.Value] = try doc.adapter.lintAll().map { f in
                .object([
                    "severity": .string(f.severity),
                    "code": .string(f.code),
                    "id": f.id.map { MCP.Value.string($0) } ?? .null,
                    "message": .string(f.message),
                ])
            }
            return .object(["lint": .array(lint)])
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
        description: "Export a canvas doc as a SELF-CONTAINED static HTML file (theme "
            + "custom-property block + the lowered page — the B0 export tier). "
            + "Returns {path, bytes}.",
        inputSchema: schema([
            "doc":  .object(["type": .string("string")]),
            "path": .object(["type": .string("string"),
                             "description": .string("Output .html path")]),
        ], required: ["doc", "path"])
    )

    private static func canvasExport(_ args: MCP.Value, _ host: AutomationHost) throws -> MCP.Value {
        let doc = try canvasDoc(try args.string("doc"), host)
        let path = try args.string("path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let html = try doc.adapter.html()
            try EditorWriter.save(html, to: url)
            return .object(["path": .string(url.path), "bytes": .int(html.utf8.count)])
        } catch {
            throw MCPError.toolFailed("canvas_export: \(error)")
        }
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

}
