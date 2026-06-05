import Foundation
import ViewerKit

/// The ten v1 MCP tools, per design §6. Each tool has a descriptor
/// (name + JSON Schema for `tools/list`) and a dispatcher (the closure
/// that turns args into an `AutomationHost` call).
///
/// Tools are kept in this single file so the catalog reads top-to-
/// bottom — the action vocabulary is small and stable enough that the
/// usual "one file per handler" wins us nothing.
@MainActor
public enum MCPToolCatalog {

    // MARK: - Catalog

    public static let all: [MCP.ToolDescriptor] = [
        openPathDescriptor,
        selectTabDescriptor,
        setViewModeDescriptor,
        findDescriptor,
        gotoLineDescriptor,
        visibleTextDescriptor,
        currentStateDescriptor,
        toggleBookmarkDescriptor,
        listBookmarksDescriptor,
        snapshotWindowDescriptor,
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
        case "find":              return try find(args, host)
        case "goto_line":         return try gotoLine(args, host)
        case "visible_text":      return try visibleText(args, host)
        case "current_state":     return try currentState(args, host)
        case "toggle_bookmark":   return try toggleBookmark(args, host)
        case "list_bookmarks":    return try listBookmarks(args, host)
        case "snapshot_window":   return try snapshotWindow(args, host)
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

    // MARK: - Validation

    /// Validates a path arg per design §8:
    ///   - resolves `~` and relative components
    ///   - must exist
    ///   - must be inside the user's home directory (rejects /etc/...,
    ///     /System/..., other users' homes — the viewer is for the
    ///     current user's files only).
    private static func validatedExistingURL(from path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        // Allow paths under the user's home, plus the per-user temp dir (also
        // under /var/folders, owned by user) which is where `mdv -` stashes
        // stdin and where tests stage scratch files. ANCHORED prefixes only:
        // `temp` does NOT end in `/`, so a bare `hasPrefix(temp)` would admit a
        // user-writable SIBLING like `/var/folders/<rand>/T-attacker/loot`
        // (AUDIT S3). Containment is checked BEFORE existence so an out-of-jail
        // path can't be probed via the differential notFound/permissionDenied
        // error (existence oracle).
        let temp = fm.temporaryDirectory.standardizedFileURL.path
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
}
