import Foundation

/// TSK-1340 — the ⌘K palette's PARAM-INPUT step. Several menu commands
/// aren't palette-invokable today only because the palette can't collect a
/// value: Go to Line (a line number), Apply jq (a filter string), Convert
/// Encoding (one of N targets). This is the pure state machine the palette
/// view drives: command → needs-param → validated input → dispatch line.
/// The view is a render tail; the flow, validation, and verb assembly are
/// host-tested here.
public enum PaletteParamFlow {

    /// What kind of value a param command collects — drives the input row's
    /// placeholder + validation.
    public enum ParamKind: Equatable, Sendable {
        case integer(min: Int, max: Int?)
        case text(placeholder: String)
        /// A closed set (e.g. encoding targets); the input matches a token.
        case choice(options: [String])

        public var placeholder: String {
            switch self {
            case .integer(let lo, let hi):
                return hi.map { "line (\(lo)–\($0))" } ?? "line number"
            case .text(let p): return p
            case .choice(let opts): return "one of: \(opts.joined(separator: ", "))"
            }
        }
    }

    /// A command that needs a value before it can dispatch.
    public struct ParamCommand: Equatable, Sendable {
        public let commandID: String
        /// The verb prefix; the validated value is appended (space-joined).
        public let verbPrefix: String
        public let kind: ParamKind
        public init(commandID: String, verbPrefix: String, kind: ParamKind) {
            self.commandID = commandID
            self.verbPrefix = verbPrefix
            self.kind = kind
        }
    }

    /// The built-in param commands (the three the audit named). Encoding
    /// targets mirror the Convert-Encoding menu; kept minimal here (the
    /// common set) — the menu remains the exhaustive surface.
    public static let builtIns: [ParamCommand] = [
        ParamCommand(commandID: "view.goToLine", verbPrefix: "goto-line",
                     kind: .integer(min: 1, max: nil)),
        ParamCommand(commandID: "view.applyJQ", verbPrefix: "apply-jq",
                     kind: .text(placeholder: "jq filter (e.g. .items[].name)")),
        ParamCommand(commandID: "view.convertEncoding", verbPrefix: "convert-encoding",
                     kind: .choice(options: [
                        "utf-8", "utf-16", "utf-16le", "utf-16be",
                        "latin1", "windows-1252", "ascii"])),
    ]

    public static func command(forID id: String) -> ParamCommand? {
        builtIns.first { $0.commandID == id }
    }

    /// Validate raw input for a kind. `.success(normalized)` carries the
    /// canonical value to append; `.failure(message)` is shown inline and
    /// blocks dispatch (the input row stays open).
    public enum Validation: Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    public static func validate(_ raw: String, kind: ParamKind) -> Validation {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("Enter a value") }
        switch kind {
        case .integer(let lo, let hi):
            guard let n = Int(trimmed) else { return .failure("Enter a number") }
            if n < lo { return .failure("Must be ≥ \(lo)") }
            if let hi, n > hi { return .failure("Must be ≤ \(hi)") }
            return .success(String(n))
        case .text:
            return .success(trimmed)
        case .choice(let opts):
            // Case-insensitive exact, then unique prefix (type "utf-8" or
            // "win" and get windows-1252 if unambiguous).
            let lower = trimmed.lowercased()
            if let exact = opts.first(where: { $0.lowercased() == lower }) {
                return .success(exact)
            }
            let prefixHits = opts.filter { $0.lowercased().hasPrefix(lower) }
            if prefixHits.count == 1 { return .success(prefixHits[0]) }
            if prefixHits.count > 1 {
                return .failure("Ambiguous: \(prefixHits.joined(separator: ", "))")
            }
            return .failure("Not a valid option")
        }
    }

    /// The verb line to dispatch once input validates. `nil` when validation
    /// fails (the caller keeps the input row open showing the message).
    public static func dispatchLine(for command: ParamCommand, rawInput: String) -> String? {
        guard case .success(let value) = validate(rawInput, kind: command.kind) else {
            return nil
        }
        return "\(command.verbPrefix) \(value)"
    }
}
