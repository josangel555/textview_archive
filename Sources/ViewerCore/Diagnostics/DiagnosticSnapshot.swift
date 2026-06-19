import Foundation

/// Curated, value-typed diagnostic state for the debug-only diagnostic
/// window (PRIORITIZED_PLAN item 17; triage-instrumentation.md "Diagnostic
/// window" section).
///
/// ## Why a hand-written snapshot and NOT `Codable` of `DocumentModel`
/// `DocumentModel` is a 2700-line `@MainActor` god object full of closures,
/// stores, `NSObject`s, and live `@Published` state. Auto-deriving `Codable`
/// from it would (a) be impossible without conformances on every member and
/// (b) leak internals we never intend to expose — every open file's bytes,
/// every callback, the whole reactive graph. Instead the UI/host curates a
/// *flat snapshot of facts* (see `DocumentModel+Diagnostics.swift`) and hands
/// it to this Foundation-only value type for rendering / export.
///
/// ## Boundary
/// Lives in **ViewerCore**, Foundation-only, no SwiftUI/AppKit (LESSONS
/// guardrail). All members are `Sendable` value types so the snapshot can be
/// captured on the main actor and handed to a background writer without data
/// races. It carries strings + primitives only — no `URL` payloads escape the
/// curation step, mirroring the FFI-shaped discipline the observability
/// records already follow.
///
/// ## Security (PRIORITIZED_PLAN §5 guardrail #7; triage risk note)
/// This is the single most dangerous instrumentation surface: a full dump
/// leaks every open file's absolute path, recents, bookmarks, git roots, and
/// (if not redacted) document content. Therefore:
///   * It must **NEVER** be added to the MCP tool catalog / automation host.
///   * It must **NEVER** be auto-persisted; the window is a live view and any
///     manual export is owner-invoked + 0600 (`DiagnosticDumpWriter`).
///   * Content is curated out by construction (we carry sizes/line counts,
///     not bytes). Absolute paths are redactable via `redactingPaths` for any
///     artifact that can leave the process.
public struct DiagnosticSnapshot: Sendable, Equatable {

    /// Schema version of this snapshot shape. Bumped additively if fields
    /// change so an exported artifact records what produced it.
    /// v2: added `sockets` (process-scoped socket enrichment of socket fds).
    public static let schemaVersion = 2

    // MARK: Process / build

    /// Process id of the running app. Useful when correlating with
    /// `proc_pidinfo` fd output or external `footprint`/`ps` runs.
    public let pid: Int32
    /// Wall-clock capture time, nanoseconds since the Unix epoch. Raw
    /// integer (no `Date` payload) to stay value-flat, matching `ObsEvent`.
    public let capturedAtUnixNanos: UInt64
    /// True when the build is DEBUG. Informational — the gate itself lives
    /// in `DiagnosticGate`.
    public let isDebugBuild: Bool

    // MARK: Document / tabs (curated — NO file contents)

    /// One summary per open tab. Paths only (never bytes); sizes/line counts
    /// are facts, not content.
    public let tabs: [DiagnosticTabSummary]
    /// Index of the selected tab into `tabs`, or nil.
    public let selectedTabIndex: Int?
    /// Sidebar root folder path, if a folder is open.
    public let sidebarRootPath: String?
    /// Count of recently-opened entries (the *paths* themselves are
    /// deliberately NOT included — recents are a path-exfil surface and a
    /// count is enough for a diagnostic).
    public let recentsCount: Int
    /// Count of bookmarks (paths omitted for the same reason).
    public let bookmarksCount: Int

    // MARK: Runtime resources (probed)

    /// Temp-file artifacts WE own in the per-user tmpdir (`mdv-*`).
    public let tempFiles: [DiagnosticTempFile]
    /// Open file descriptors of this process (`proc_pidinfo PROC_PIDLISTFDS`).
    public let openFDs: [DiagnosticOpenFD]
    /// This process's own sockets, enriched with family/proto/port/state
    /// (`proc_pidfdinfo PROC_PIDFDSOCKETINFO`). Process-scoped — NEVER a
    /// system-wide port scan (that needs entitlements we don't hold and isn't
    /// our business). Addresses are deliberately omitted (peer IPs are the
    /// leak surface); we carry ports + state, which is the honest "open
    /// ports" answer for a viewer: which of OUR sockets are listening or
    /// connected, on what port.
    public let sockets: [DiagnosticSocket]
    /// Live subprocesses we manage (LSP servers etc.).
    public let subprocesses: [DiagnosticSubprocess]

    // MARK: Observability roll-up (counts only)

    /// Events currently retained in the observability ring buffer.
    public let obsBufferedEvents: Int
    /// Total events ever emitted (including evicted-by-wrap).
    public let obsTotalEmitted: UInt64

    public init(
        pid: Int32,
        capturedAtUnixNanos: UInt64,
        isDebugBuild: Bool,
        tabs: [DiagnosticTabSummary],
        selectedTabIndex: Int?,
        sidebarRootPath: String?,
        recentsCount: Int,
        bookmarksCount: Int,
        tempFiles: [DiagnosticTempFile],
        openFDs: [DiagnosticOpenFD],
        sockets: [DiagnosticSocket] = [],
        subprocesses: [DiagnosticSubprocess],
        obsBufferedEvents: Int,
        obsTotalEmitted: UInt64
    ) {
        self.pid = pid
        self.capturedAtUnixNanos = capturedAtUnixNanos
        self.isDebugBuild = isDebugBuild
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.sidebarRootPath = sidebarRootPath
        self.recentsCount = recentsCount
        self.bookmarksCount = bookmarksCount
        self.tempFiles = tempFiles
        self.openFDs = openFDs
        self.sockets = sockets
        self.subprocesses = subprocesses
        self.obsBufferedEvents = obsBufferedEvents
        self.obsTotalEmitted = obsTotalEmitted
    }

    /// Return a copy with every absolute path replaced by a redacted form
    /// (`PathRedactor.redact`). Used for any artifact that can leave the
    /// process — an exported file reveals the username + project layout
    /// otherwise (`/Users/<name>/...`). The live in-window view may show
    /// real paths under DEBUG; export should default to redacted.
    public func redactingPaths() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            pid: pid,
            capturedAtUnixNanos: capturedAtUnixNanos,
            isDebugBuild: isDebugBuild,
            tabs: tabs.map { $0.redactingPaths() },
            selectedTabIndex: selectedTabIndex,
            sidebarRootPath: sidebarRootPath.map(PathRedactor.redact),
            recentsCount: recentsCount,
            bookmarksCount: bookmarksCount,
            tempFiles: tempFiles.map { $0.redactingPaths() },
            openFDs: openFDs.map { $0.redactingPaths() },
            // Sockets carry no absolute paths (ports/state/family only), so
            // redaction is a passthrough — but route through it explicitly so
            // a future address-bearing field can't silently skip redaction.
            sockets: sockets.map { $0.redactingPaths() },
            subprocesses: subprocesses.map { $0.redactingPaths() },
            obsBufferedEvents: obsBufferedEvents,
            obsTotalEmitted: obsTotalEmitted)
    }

    /// JSON-serialisable dictionary for export. Deterministic field order is
    /// imposed by `JSONSerialization.sortedKeys` at the write site.
    public func jsonObject() -> [String: Any] {
        [
            "schemaVersion": DiagnosticSnapshot.schemaVersion,
            "pid": Int(pid),
            "capturedAtUnixNanos": capturedAtUnixNanos,
            "isDebugBuild": isDebugBuild,
            "selectedTabIndex": selectedTabIndex as Any,
            "sidebarRootPath": sidebarRootPath as Any,
            "recentsCount": recentsCount,
            "bookmarksCount": bookmarksCount,
            "tabs": tabs.map { $0.jsonObject() },
            "tempFiles": tempFiles.map { $0.jsonObject() },
            "openFDs": openFDs.map { $0.jsonObject() },
            "sockets": sockets.map { $0.jsonObject() },
            "subprocesses": subprocesses.map { $0.jsonObject() },
            "obsBufferedEvents": obsBufferedEvents,
            "obsTotalEmitted": obsTotalEmitted
        ]
    }
}

/// One open tab's curated facts. **No file contents** — `byteCount` /
/// `lineCount` are sizes, not bytes.
public struct DiagnosticTabSummary: Sendable, Equatable {
    public let title: String
    public let path: String?
    /// Coarse state discriminator: `empty`, `loaded`, `binary`, `error`,
    /// `preview`, `loading` — the `DocumentState` case name only.
    public let stateKind: String
    /// View mode raw value (`rendered`, `source`, `hex`, ...).
    public let viewMode: String
    public let isDirty: Bool
    public let diskState: String
    /// Loaded byte count if known (size fact, not content).
    public let byteCount: Int?

    public init(
        title: String,
        path: String?,
        stateKind: String,
        viewMode: String,
        isDirty: Bool,
        diskState: String,
        byteCount: Int?
    ) {
        self.title = title
        self.path = path
        self.stateKind = stateKind
        self.viewMode = viewMode
        self.isDirty = isDirty
        self.diskState = diskState
        self.byteCount = byteCount
    }

    public func redactingPaths() -> DiagnosticTabSummary {
        DiagnosticTabSummary(
            title: title,
            path: path.map(PathRedactor.redact),
            stateKind: stateKind,
            viewMode: viewMode,
            isDirty: isDirty,
            diskState: diskState,
            byteCount: byteCount)
    }

    public func jsonObject() -> [String: Any] {
        [
            "title": title,
            "path": path as Any,
            "stateKind": stateKind,
            "viewMode": viewMode,
            "isDirty": isDirty,
            "diskState": diskState,
            "byteCount": byteCount as Any
        ]
    }
}

/// A temp-file artifact WE own in the per-user tmpdir. Path + size + age
/// only — never the file body (content redaction by construction).
public struct DiagnosticTempFile: Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int
    /// File mtime, nanoseconds since the Unix epoch (raw integer, no `Date`).
    public let modifiedUnixNanos: UInt64

    public init(path: String, sizeBytes: Int, modifiedUnixNanos: UInt64) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedUnixNanos = modifiedUnixNanos
    }

    public func redactingPaths() -> DiagnosticTempFile {
        DiagnosticTempFile(
            path: PathRedactor.redact(path),
            sizeBytes: sizeBytes,
            modifiedUnixNanos: modifiedUnixNanos)
    }

    public func jsonObject() -> [String: Any] {
        ["path": path, "sizeBytes": sizeBytes, "modifiedUnixNanos": modifiedUnixNanos]
    }
}

/// One open file descriptor (from `proc_pidinfo PROC_PIDLISTFDS`).
public struct DiagnosticOpenFD: Sendable, Equatable {
    public let fd: Int32
    /// Human label for the fd type (`vnode`, `socket`, `pipe`, `kqueue`, ...).
    public let kind: String
    /// Resolved filesystem path for vnode fds, if obtainable. nil for
    /// non-vnode kinds (sockets/pipes have no path).
    public let path: String?

    public init(fd: Int32, kind: String, path: String?) {
        self.fd = fd
        self.kind = kind
        self.path = path
    }

    public func redactingPaths() -> DiagnosticOpenFD {
        DiagnosticOpenFD(fd: fd, kind: kind, path: path.map(PathRedactor.redact))
    }

    public func jsonObject() -> [String: Any] {
        ["fd": Int(fd), "kind": kind, "path": path as Any]
    }
}

/// A live subprocess we manage (currently: LSP servers keyed by
/// language@workspace). Carries no command-line args / env — just identity
/// + coarse health, so it isn't a leak of invocation secrets.
public struct DiagnosticSubprocess: Sendable, Equatable {
    /// Subsystem that owns it (`lsp`, ...).
    public let subsystem: String
    /// Stable identity label (e.g. `swift@/path/to/workspace`).
    public let label: String
    /// Coarse liveness (`live`, `dead`, `cold`).
    public let status: String
    /// Optional path embedded in `label` (e.g. workspace root) for redaction.
    public let path: String?

    public init(subsystem: String, label: String, status: String, path: String?) {
        self.subsystem = subsystem
        self.label = label
        self.status = status
        self.path = path
    }

    public func redactingPaths() -> DiagnosticSubprocess {
        // Redact the path component AND the embedded path inside `label`.
        let redactedLabel: String
        if let p = path {
            redactedLabel = label.replacingOccurrences(of: p, with: PathRedactor.redact(p))
        } else {
            redactedLabel = label
        }
        return DiagnosticSubprocess(
            subsystem: subsystem,
            label: redactedLabel,
            status: status,
            path: path.map(PathRedactor.redact))
    }

    public func jsonObject() -> [String: Any] {
        ["subsystem": subsystem, "label": label, "status": status, "path": path as Any]
    }
}

/// One socket owned by THIS process, enriched from `socket_fdinfo`
/// (`proc_pidfdinfo PROC_PIDFDSOCKETINFO`). This is the curated "open ports"
/// answer the diagnostic window was originally too conservative to give.
///
/// ## Why this is safe (and why it isn't the cut-for-good "port scan")
/// The original probe deliberately cut "open ports" because a *system-wide*
/// port enumeration needs entitlements and is a viewer's none-of-its-business.
/// This is the OTHER thing: introspecting **our own** process's sockets, which
/// needs no entitlement (same `proc_pidfdinfo` call already used for vnode
/// paths). It answers the genuinely useful diagnostic question — "is the app
/// holding a listening socket it shouldn't? what local LSP/automation port is
/// it connected to?" — without scanning anyone else.
///
/// ## Content/privacy
/// We carry **ports + state + family/proto only — never peer addresses**. A
/// foreign IP is the exfil surface (who is the app talking to); a port number
/// and a `listen`/`established` label is a fact about our own resource use.
/// Nothing here is a filesystem path, so `redactingPaths()` is a passthrough.
public struct DiagnosticSocket: Sendable, Equatable {
    /// The backing file descriptor (cross-references the `openFDs` row).
    public let fd: Int32
    /// Address family label: `inet`, `inet6`, `unix`, `vsock`, or `other(N)`.
    public let family: String
    /// Protocol label: `tcp`, `udp`, `unix`, `kctl`, `kevt`, or `other`.
    public let proto: String
    /// Local port (host byte order) for inet/inet6 sockets; nil otherwise.
    public let localPort: Int?
    /// Foreign (peer) port (host byte order) for connected inet/inet6
    /// sockets; nil for unconnected/listening/non-inet sockets. The peer
    /// ADDRESS is intentionally omitted — only the port is a fact we expose.
    public let foreignPort: Int?
    /// TCP state label (`listen`, `established`, `close_wait`, ...) for TCP
    /// sockets; a coarse `connected`/`unconnected` for other socket kinds.
    public let state: String
    /// True when this socket is accepting connections (TCP `listen`). The
    /// single most diagnostically interesting bit — a viewer should almost
    /// never be listening.
    public let isListening: Bool

    public init(
        fd: Int32,
        family: String,
        proto: String,
        localPort: Int?,
        foreignPort: Int?,
        state: String,
        isListening: Bool
    ) {
        self.fd = fd
        self.family = family
        self.proto = proto
        self.localPort = localPort
        self.foreignPort = foreignPort
        self.state = state
        self.isListening = isListening
    }

    /// No-op: sockets carry no absolute paths. Present for symmetry with the
    /// other row types so the snapshot's recursion is uniform.
    public func redactingPaths() -> DiagnosticSocket { self }

    public func jsonObject() -> [String: Any] {
        [
            "fd": Int(fd),
            "family": family,
            "proto": proto,
            "localPort": localPort as Any,
            "foreignPort": foreignPort as Any,
            "state": state,
            "isListening": isListening
        ]
    }
}
