import Foundation

/// User keybinding overrides, parsed from `~/.textview/keybinding.json`.
///
/// ## Format
///
/// A flat JSON object mapping `commandID → shortcut string`:
///
/// ```json
/// {
///   "view.toggleSidebar": "cmd+shift+e",
///   "file.save":          "cmd+s",
///   "view.quickOpen":     "cmd+p"
/// }
/// ```
///
/// - **Keys** are `CommandDescriptor.id` values (see
///   `CommandRegistry+BuiltIn.swift`). An unknown id is parsed but has no
///   effect (no command to bind) — it's surfaced in
///   `ParseResult.unknownIDs` and logged, not fatal.
/// - **Values** are `"cmd+shift+f"`-style strings parsed by
///   `Shortcut.parse`. Accepted modifier tokens: `cmd`/`command`/`meta`,
///   `shift`, `alt`/`opt`/`option`, `ctrl`/`control`. The base key is the
///   last `+`-separated token: a single character, or a symbolic name
///   (`left`, `right`, `up`, `down`, `tab`, `space`, `escape`, `return`,
///   `delete`, `backslash`, …). A malformed value is dropped (surfaced in
///   `ParseResult.invalidValues` and logged).
///
/// ## Precedence
///
/// **User > default.** A binding here REPLACES the built-in
/// `defaultShortcut` for that command (`CommandRegistry.applying`). The
/// merge is total replacement, not addition — set a command's value to a
/// new keystroke to rebind it.
///
/// ## Conflicts
///
/// If two commands end up bound to the same keystroke (whether by a
/// built-in collision or a user override), `CommandRegistry.shortcutMap`
/// resolves it **last-wins** (later in catalog declaration order keeps
/// the key) and reports the loser via its `onConflict` callback, which
/// the app logs through `Obs`.
///
/// ## Robustness
///
/// `load(directory:)` is total: a missing file, a missing directory, an
/// unreadable file, non-object JSON, or a value that isn't a string all
/// resolve to an EMPTY config (built-in defaults stand) — never a crash,
/// never a thrown error to the caller. Per-entry problems (bad value,
/// non-string value) drop just that entry. The `~/.textview/` directory
/// is created if absent so a future settings UI / first write has a home,
/// but its absence is not itself an error.
public struct KeybindingConfig: Sendable, Equatable {

    /// The successfully-parsed `commandID → Shortcut` overrides.
    public let bindings: [String: Shortcut]

    public init(bindings: [String: Shortcut] = [:]) {
        self.bindings = bindings
    }

    /// An empty config — built-in defaults only.
    public static let empty = KeybindingConfig()

    public var isEmpty: Bool { bindings.isEmpty }

    /// Structured outcome of a parse, so the caller can log the partials
    /// (unknown ids, malformed values) without the parser importing the
    /// observability sink. `config` carries only the entries that both
    /// parsed AND name a known command.
    public struct ParseResult: Sendable, Equatable {
        public let config: KeybindingConfig
        /// Values that failed `Shortcut.parse` — `commandID → raw string`.
        public let invalidValues: [String: String]
        /// IDs present in the file but not in the supplied registry.
        public let unknownIDs: [String]
        /// `true` when a file existed but its top-level JSON was not an
        /// object of strings (whole file ignored).
        public let malformedFile: Bool
    }

    // MARK: - Loading

    /// Standard config directory under the user's home: `~/.textview`.
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".textview", isDirectory: true)
    }

    /// The keybinding file name inside the config directory.
    public static let fileName = "keybinding.json"

    /// Load + parse `<directory>/keybinding.json`, validating ids against
    /// `registry`. Creates `directory` if absent (best-effort). Totally
    /// safe — see the type doc; the worst case is `.empty`.
    ///
    /// - Parameters:
    ///   - directory: the config dir. Defaults to `~/.textview`. Tests
    ///     inject a temp dir so the real config is never touched.
    ///   - registry: the catalog whose ids the file's keys are validated
    ///     against. Defaults to the built-in catalog.
    /// - Returns: a `ParseResult` — `.config` is what to apply; the other
    ///   fields let the caller log partial failures.
    public static func load(
        directory: URL = defaultDirectory,
        registry: CommandRegistry = .builtIn
    ) -> ParseResult {
        let fm = FileManager.default
        // Ensure the directory exists for future writes. A failure here is
        // non-fatal — we just won't have created it.
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        let fileURL = directory.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            // Absent file → defaults. Not malformed; this is the common case.
            return ParseResult(
                config: .empty, invalidValues: [:],
                unknownIDs: [], malformedFile: false)
        }
        return parse(data: data, registry: registry)
    }

    /// Pure parse of raw JSON bytes — no I/O, the unit-testable core.
    /// Exposed `internal`+`public` so tests can feed bytes directly
    /// without staging a file.
    public static func parse(
        data: Data,
        registry: CommandRegistry = .builtIn
    ) -> ParseResult {
        // A top-level object of string values is the only valid shape.
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return ParseResult(
                config: .empty, invalidValues: [:],
                unknownIDs: [], malformedFile: true)
        }

        var bindings: [String: Shortcut] = [:]
        var invalid: [String: String] = [:]
        var unknown: [String] = []

        for (id, rawValue) in dict {
            guard let str = rawValue as? String else {
                // Non-string value for a key → treat that entry as bad.
                invalid[id] = String(describing: rawValue)
                continue
            }
            guard let shortcut = Shortcut.parse(str) else {
                invalid[id] = str
                continue
            }
            if registry.command(id: id) == nil {
                unknown.append(id)
                // Still skip applying — nothing to bind.
                continue
            }
            bindings[id] = shortcut
        }

        return ParseResult(
            config: KeybindingConfig(bindings: bindings),
            invalidValues: invalid,
            unknownIDs: unknown.sorted(),
            malformedFile: false)
    }
}
