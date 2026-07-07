import Foundation

/// STAGE-B DELETED TWIN (TSK-649/TSK-1213, 2026-07-07): the Swift formula
/// EVALUATOR (lexer/parser/evaluate, ~40 builtin functions, cycle detection)
/// that lived here was deleted after the MDV_RUST_FORMULA default flipped ON
/// — the engine is rust-core's `formula.rs` (function semantics, error
/// propagation and cycle rules pinned there and by the retargeted contract
/// suites). What remains: the value/error CONTRACT types below, and the
/// grid bridge (`formulaGridSnapshot` + `recalcAllFormulas`) that feeds the
/// rust recalc.

// MARK: - EditableCSVModel bridge (rust recalc wiring)

extension EditableCSVModel {
    /// A1 → raw text for every non-empty DATA cell (the header, grid row 0, is
    /// skipped — "A1 = first data row"). The snapshot the Rust recalc resolves
    /// against.
    func formulaGridSnapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        guard rowCount > 1 else { return snapshot }
        for r in 1..<rowCount {
            for c in 0..<columnCount {
                guard let v = getCell(row: r, column: c), !v.isEmpty else { continue }
                snapshot[CellReference(row: r - 1, column: c).a1] = v
            }
        }
        return snapshot
    }

    /// Compute every FORMULA cell's value in ONE pass: A1-space `CellReference`
    /// → computed `FormulaValue`, via the rust recalc engine (one snapshot, one
    /// recalc, formula-cell references resolved in dependency order). A bridge
    /// fault degrades to [:] — raw formula text shows unmarked in the grid
    /// (observable via the runRustOnly log), never a crash.
    public func recalcAllFormulas(environment: [String: String]? = nil) -> [CellReference: FormulaValue] {
        // The env parameter is kept for call-site compatibility (tests pin the
        // default path with environment: [:]); the gate no longer has a Swift
        // arm to select.
        _ = environment
        return RustCoreFallback.runRustOnly(
            .formula,
            rust: { try RustFormulaAdapter.recalc(cells: formulaGridSnapshot()) },
            degraded: [:]
        ).value
    }
}

// MARK: - Value type

/// The result of evaluating a formula or cell. Mirrors the spreadsheet value
/// model: number, text, boolean, blank, or a typed error.
public enum FormulaValue: Equatable, Sendable {
    case number(Double)
    case text(String)
    case boolean(Bool)
    case blank
    case error(FormulaError)

    /// Text→number coercion shared by the value coercions below (the engine
    /// rule the rust side mirrors): trimmed; optional sign, decimal,
    /// scientific notation; NaN/Inf/hex textual forms rejected. `nil` when
    /// the WHOLE trimmed string isn't a number.
    static func parseNumber(_ s: some StringProtocol) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        for ch in t where !(ch.isASCIIDigit || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E") {
            return nil
        }
        return Double(t)
    }

    /// Numeric coercion: numbers as-is, booleans as 1/0, numeric text parsed,
    /// blank as 0; otherwise nil (caller decides whether nil → error). Errors
    /// never coerce.
    public var asNumber: Double? {
        switch self {
        case .number(let n): return n
        case .boolean(let b): return b ? 1 : 0
        case .blank: return 0
        case .text(let s): return FormulaValue.parseNumber(s)
        case .error: return nil
        }
    }

    /// Textual coercion for `&`/CONCAT/text functions. A number renders without
    /// a trailing `.0` for integers; a boolean as TRUE/FALSE; blank as "".
    public var asText: String {
        switch self {
        case .number(let n): return Self.formatNumber(n)
        case .text(let s): return s
        case .boolean(let b): return b ? "TRUE" : "FALSE"
        case .blank: return ""
        case .error(let e): return e.display
        }
    }

    /// Boolean coercion for IF/AND/OR/NOT: booleans as-is, a non-zero number is
    /// true, blank is false, text "TRUE"/"FALSE" (case-insensitive) map across,
    /// other text is false. Errors are false here (the caller checks `.error`
    /// first to propagate).
    public var asBool: Bool {
        switch self {
        case .boolean(let b): return b
        case .number(let n): return n != 0
        case .blank: return false
        case .text(let s):
            let l = s.lowercased()
            if l == "true" { return true }
            if l == "false" { return false }
            if let n = FormulaValue.parseNumber(s) { return n != 0 }
            return false
        case .error: return false
        }
    }

    /// A display string for the value as the grid would show it (numbers
    /// trimmed, errors as their `#…!` token).
    public var display: String { asText }

    /// Render a Double the way a sheet cell would: integers without a decimal
    /// point, fractionals with up to a sane precision and no trailing zeros.
    static func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(Int64(n))
        }
        // Trim trailing zeros from a %g-style render.
        var s = String(format: "%.10g", n)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

/// Spreadsheet error values. They propagate through operators (an error
/// operand makes the whole expression that error) and surface to the grid as
/// their `#…!` token.
public enum FormulaError: Error, Equatable, Sendable {
    case divideByZero       // #DIV/0!
    case value              // #VALUE!  — wrong type of operand
    case ref                // #REF!    — invalid cell reference
    case name               // #NAME?   — unknown function/name
    case num                // #NUM!    — invalid numeric arg (e.g. SQRT(-1))
    case cycle              // #CYCLE!  — circular reference
    case parse              // #ERROR!  — couldn't parse the formula
    case na                 // #N/A     — value not available (e.g. a lookup miss)

    public var display: String {
        switch self {
        case .divideByZero: return "#DIV/0!"
        case .value:        return "#VALUE!"
        case .ref:          return "#REF!"
        case .name:         return "#NAME?"
        case .num:          return "#NUM!"
        case .cycle:        return "#CYCLE!"
        case .parse:        return "#ERROR!"
        case .na:           return "#N/A"
        }
    }
}
