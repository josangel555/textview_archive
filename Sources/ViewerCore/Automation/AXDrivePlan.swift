import Foundation

// TSK-1254 — the agent-drive COMMAND grammar.
//
// The public, deterministic action surface an AGENT (or the UAT driver) uses to
// drive native chrome by `mdv.*` accessibilityIdentifier: a single text command
// → a structured (target, action) plan. The out-of-process driver executable
// and the agent-entry both PARSE a command into this, then resolve it through
// `AXDriverCore.find` + the live `AXUIElement` adapter. Keeping the grammar a
// pure value type makes it host-testable (the attach/perform is VM/AX-TCC-tail).
//
// Grammar (one command per line):
//   press  <mdv.id>                 — activate (AXPress / CGEvent-at-frame)
//   read   <mdv.id>                 — read the element's value/label
//   scroll <mdv.id> <up|down|left|right>
//   set    <mdv.id> <value…>        — set the element's value (rest-of-line)
// `<mdv.id>` may be an exact id or a trailing-glob (`mdv.tab.*`) — it parses
// through `AXQuery`, so the same dynamic-id matching the rest of the driver uses.

public enum AXScrollDirection: String, Equatable, Sendable, CaseIterable {
    case up, down, left, right
}

public struct AXDrivePlan: Equatable, Sendable {

    public enum Action: Equatable, Sendable {
        case press
        case read
        case scroll(AXScrollDirection)
        case setValue(String)
    }

    public let query: AXQuery
    public let action: Action

    public init(query: AXQuery, action: Action) {
        self.query = query
        self.action = action
    }

    /// Parse one drive command. Returns nil for any malformed input (an agent-
    /// supplied command is untrusted).
    public init?(parsing command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // verb, id, then the remainder (for scroll dir / set value).
        let parts = trimmed.split(separator: " ", maxSplits: 2,
                                  omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let verb = parts[0].lowercased()
        let id = parts[1]
        guard id.hasPrefix("mdv.") else { return nil }
        let rest = parts.count >= 3 ? parts[2] : ""
        let q = AXQuery(id)

        switch verb {
        case "press":
            guard rest.isEmpty else { return nil }   // press takes no arg
            self = AXDrivePlan(query: q, action: .press)
        case "read":
            guard rest.isEmpty else { return nil }
            self = AXDrivePlan(query: q, action: .read)
        case "scroll":
            guard let dir = AXScrollDirection(rawValue: rest.lowercased()) else { return nil }
            self = AXDrivePlan(query: q, action: .scroll(dir))
        case "set":
            guard !rest.isEmpty else { return nil }   // set requires a value
            self = AXDrivePlan(query: q, action: .setValue(rest))
        default:
            return nil
        }
    }

    /// The canonical command string (round-trips with `init(parsing:)`).
    public var serialized: String {
        let id = query.match == .prefix ? query.stem + "*" : query.stem
        switch action {
        case .press:            return "press \(id)"
        case .read:             return "read \(id)"
        case .scroll(let dir):  return "scroll \(id) \(dir.rawValue)"
        case .setValue(let v):  return "set \(id) \(v)"
        }
    }
}
