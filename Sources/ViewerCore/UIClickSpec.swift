import Foundation

/// Parsed form of the `ui-click` / `ui-double-click` script verbs — the
/// harness's REAL-event interaction layer (TSK-313/314/522 validation).
///
///     ui-click <ax-id> [cmd] [shift] [at FX FY]
///     ui-double-click <ax-id> [cmd] [shift] [at FX FY]
///
/// `FX FY` position the click as FRACTIONS of the target view's bounds
/// (0…1, default 0.5 0.5 = center) — fraction-based so scripts survive
/// layout/size changes; `FY` is in the target view's native coordinate
/// space (flippedness varies by view). Strict grammar: any unknown token
/// fails the parse, so a typo'd modifier can't silently degrade a test
/// into an unmodified click.
public struct UIClickSpec: Equatable, Sendable {
    public let identifier: String
    public let clickCount: Int
    public let command: Bool
    public let shift: Bool
    public let fx: Double
    public let fy: Double

    public static func parse(verb: String, arg: String) -> UIClickSpec? {
        let clickCount: Int
        switch verb {
        case "ui-click": clickCount = 1
        case "ui-double-click": clickCount = 2
        default: return nil
        }
        var tokens = arg.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        let identifier = tokens.removeFirst()
        var command = false
        var shift = false
        var fx = 0.5
        var fy = 0.5
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case "cmd":
                command = true
                i += 1
            case "shift":
                shift = true
                i += 1
            case "at":
                guard i + 3 <= tokens.count,
                      let x = Double(tokens[i + 1]),
                      let y = Double(tokens[i + 2]),
                      x.isFinite, y.isFinite
                else { return nil }
                fx = min(max(x, 0), 1)
                fy = min(max(y, 0), 1)
                i += 3
            default:
                return nil
            }
        }
        return UIClickSpec(identifier: identifier,
                           clickCount: clickCount,
                           command: command,
                           shift: shift,
                           fx: fx,
                           fy: fy)
    }
}
