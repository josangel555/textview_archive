import Foundation

/// CLI ⇄ live-GUI-instance discovery (TSK-353, "find active instance and
/// operate on it").
///
/// The existing CLI surfaces (`textview`, `--script`, `--mcp-stdio`, the URL
/// scheme) either spawn a fresh process or run headless. There was no way for a
/// terminal command to ask "is a GUI instance already running, and which one?"
/// so it could route a command to it instead of cold-launching another window.
/// This is the transport-agnostic *discovery + command-encoding* layer that
/// gap needs.
///
/// Design (deliberately filesystem-based, no live socket here):
///   - A running GUI instance drops a small `InstanceRecord` JSON file under a
///     well-known directory (`Application Support/MarkdownViewer/Instances/`),
///     one file per pid, named `<pid>.json`. It rewrites it on launch and
///     removes it on clean termination.
///   - The CLI side enumerates that directory, decodes the records, and prunes
///     any whose pid is no longer alive (stale files from a crash). What's left
///     is the set of *live* instances; `mostRecent()` picks the newest by launch
///     date — the natural "the instance the user is looking at" heuristic.
///   - The command the CLI wants the instance to run is modeled as
///     `InstanceCommand`, encoded into an `InstanceMessage` envelope. Encoding
///     the message is pure and host-testable; the actual byte transport to the
///     discovered instance (a Unix-domain socket / port advertised in the
///     record's `endpoint`) is the larger remote-transport epic (TSK-400) and
///     is intentionally NOT implemented here.
///
/// Everything in this type is pure logic over an injectable directory + an
/// injectable liveness probe, so the full discover → prune → select → encode
/// path is exercised by host XCTests with no real process or socket.
public enum InstanceRegistry {

    // MARK: - Record

    /// What a live GUI instance advertises so a CLI can find and address it.
    public struct InstanceRecord: Codable, Equatable, Sendable {
        /// OS process id of the running GUI instance. Used both as the file
        /// name (`<pid>.json`) and as the liveness key.
        public var pid: Int32
        /// When the instance came up. The newest record is treated as the
        /// "frontmost / current" instance by `mostRecent()`.
        public var launchDate: Date
        /// Opaque transport endpoint the instance listens on (e.g. a
        /// Unix-domain socket path or `host:port`). The CLI hands this to the
        /// transport layer (TSK-400); discovery doesn't interpret it.
        public var endpoint: String
        /// App version string of the instance, so a CLI can refuse to drive an
        /// instance whose protocol it doesn't understand.
        public var version: String

        public init(pid: Int32, launchDate: Date, endpoint: String, version: String) {
            self.pid = pid
            self.launchDate = launchDate
            self.endpoint = endpoint
            self.version = version
        }
    }

    // MARK: - Liveness

    /// Returns true if a process with `pid` is currently alive.
    ///
    /// `kill(pid, 0)` sends no signal but performs the permission/existence
    /// check: it succeeds for a live process we own, fails with `ESRCH` if no
    /// such process exists, and `EPERM` if it exists but we can't signal it
    /// (still alive). So "alive" = success OR `EPERM`; only `ESRCH` means dead.
    public static func isPidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Directory

    /// The default discovery directory:
    /// `~/Library/Application Support/MarkdownViewer/Instances/`. Matches the
    /// no-bundle-id Application Support subtree the rest of the app's session /
    /// bookmark state lives under (see CLAUDE.md "Persisted state").
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("Instances", isDirectory: true)
    }

    /// The on-disk file for a given pid within `directory`.
    public static func recordURL(for pid: Int32, in directory: URL) -> URL {
        directory.appendingPathComponent("\(pid).json", isDirectory: false)
    }

    // MARK: - Register / deregister

    /// Write `record` into `directory` (creating it if needed), one file per
    /// pid. Called by a GUI instance at launch. Throws on an unwritable dir so
    /// the caller can degrade gracefully (discovery simply finds nothing).
    @discardableResult
    public static func register(_ record: InstanceRecord, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = recordURL(for: record.pid, in: directory)
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Remove the record for `pid` from `directory`. Called on clean
    /// termination. Best-effort: a missing file is not an error.
    public static func deregister(pid: Int32, in directory: URL) {
        try? FileManager.default.removeItem(at: recordURL(for: pid, in: directory))
    }

    // MARK: - Discover

    /// Decode every well-formed `<pid>.json` record in `directory`, drop the
    /// ones whose pid is dead per `isAlive`, and return the survivors sorted
    /// newest-launch-first.
    ///
    /// - `directory`: where instances advertise (defaults to `defaultDirectory()`).
    /// - `isAlive`: liveness probe, injected for tests; defaults to `isPidAlive`.
    /// - `pruneStale`: when true (default), dead instances' files are deleted as
    ///   a side effect so the directory self-heals after a crash. Pass false for
    ///   a pure read (tests that assert on the directory).
    ///
    /// A record whose pid doesn't match its file name is treated as stale
    /// (defensive against a hand-edited / corrupt file).
    public static func discover(
        in directory: URL = defaultDirectory(),
        isAlive: (Int32) -> Bool = isPidAlive,
        pruneStale: Bool = true
    ) -> [InstanceRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var live: [InstanceRecord] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(InstanceRecord.self, from: data) else {
                // Corrupt / unreadable file — treat as stale.
                if pruneStale { try? fm.removeItem(at: url) }
                continue
            }
            let nameMatches = url.deletingPathExtension().lastPathComponent == "\(record.pid)"
            if nameMatches, isAlive(record.pid) {
                live.append(record)
            } else if pruneStale {
                try? fm.removeItem(at: url)
            }
        }
        return live.sorted { $0.launchDate > $1.launchDate }
    }

    /// The newest live instance, or nil when none is running. The CLI's "open
    /// in the running app, else launch one" decision pivots on this.
    public static func mostRecent(
        in directory: URL = defaultDirectory(),
        isAlive: (Int32) -> Bool = isPidAlive
    ) -> InstanceRecord? {
        discover(in: directory, isAlive: isAlive).first
    }

    // MARK: - Command envelope

    /// An operation the CLI wants a live instance to perform. Transport-
    /// agnostic: the same value is what we'd serialize over a socket once the
    /// transport (TSK-400) lands.
    public enum InstanceCommand: Codable, Equatable, Sendable {
        /// Open files/folders (absolute paths) in the running instance.
        case open(paths: [String])
        /// Bring the instance to the foreground.
        case activate
        /// Open a fresh empty window.
        case newWindow
        /// Liveness handshake — the instance echoes its record back.
        case ping
    }

    /// The wire envelope wrapping one command, carrying a protocol version so an
    /// instance can reject a message it doesn't understand and a client-supplied
    /// id for request/response correlation.
    public struct InstanceMessage: Codable, Equatable, Sendable {
        /// Bumped when the on-wire shape changes incompatibly.
        public static let currentProtocol = 1

        public var proto: Int
        public var id: String
        public var command: InstanceCommand

        public init(id: String, command: InstanceCommand, proto: Int = InstanceMessage.currentProtocol) {
            self.proto = proto
            self.id = id
            self.command = command
        }
    }

    /// Encode a command into a transport-ready envelope payload. Pure — no I/O.
    public static func encodeMessage(_ message: InstanceMessage) throws -> Data {
        try encoder.encode(message)
    }

    /// Decode a transport payload back into an envelope. The instance side uses
    /// this; surfaced here so encode/decode round-trips are host-tested.
    public static func decodeMessage(_ data: Data) throws -> InstanceMessage {
        try decoder.decode(InstanceMessage.self, from: data)
    }

    /// Convenience: build the message a `textview <paths>` invocation would send
    /// to a live instance — `.open` when there are paths, `.activate` otherwise
    /// (a bare `textview` just focuses the running app).
    public static func messageForLaunch(paths: [String], id: String) -> InstanceMessage {
        let command: InstanceCommand = paths.isEmpty ? .activate : .open(paths: paths)
        return InstanceMessage(id: id, command: command)
    }

    // MARK: - Codec

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
