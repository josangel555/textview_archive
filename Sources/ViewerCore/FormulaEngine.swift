import Foundation

/// TSK-673 — pure, host-testable formula-evaluation engine for the sheet/CSV
/// grid (foundation slice of the "Sheet: calculation + formula eval" epic).
///
/// This is the calculation core only. It has NO UI, no dependency on the
/// `EditableCSVModel`, and no I/O. The front-end (a later slice) feeds it a
/// `CellResolver` closure that maps an A1 `CellReference` to that cell's RAW
/// text, and the engine returns a `FormulaValue` (a number, text, boolean,
/// blank, or a spreadsheet error). The resolver indirection is what keeps the
/// engine decoupled from any particular grid model AND is the hook a future
/// dependency-aware recalc layer plugs into.
///
/// ## What this slice supports
/// - Literals: numbers (`12`, `-3.5`, `1e3`), strings (`"hi"`), booleans
///   (`TRUE`/`FALSE`).
/// - Cell references (`A1`) and ranges (`A1:B3`).
/// - Arithmetic `+ - * / ^` (right-assoc power), unary `+`/`-`, percent `%`
///   postfix, parentheses, and `&` string concatenation.
/// - Comparisons `= <> < <= > >=` yielding booleans.
/// - Functions: `SUM AVERAGE MIN MAX COUNT COUNTA PRODUCT ABS ROUND INT MOD
///   SQRT POWER IF AND OR NOT CONCAT LEN UPPER LOWER TRIM`.
/// - Spreadsheet error values that PROPAGATE (an error operand makes the whole
///   expression that error), plus cycle detection (`#CYCLE!`).
///
/// ## What it deliberately does NOT do (the `remaining` of the epic)
/// - No automatic dependency graph / incremental recalc (the resolver is
///   called on demand; a cycle is caught by a visited-set the caller seeds).
/// - No absolute (`$A$1`) references, no named ranges, no multi-sheet refs.
/// - No date/time or financial functions.
/// - No write-back / persistence of formulas into the CSV file.
public enum FormulaEngine {

    // MARK: - Public entry points

    /// Evaluate a cell's RAW text. If it starts with `=` it is treated as a
    /// formula and evaluated; otherwise it is parsed as a literal value (a bare
    /// number becomes `.number`, everything else `.text`). This is the entry the
    /// grid uses per cell.
    ///
    /// `origin` is the cell being evaluated (used to seed cycle detection so a
    /// formula that transitively refers back to itself reports `#CYCLE!`).
    /// `resolve` returns the RAW text of another cell, or nil for a blank/out-
    /// of-range cell.
    public static func evaluate(
        raw: String,
        origin: CellReference? = nil,
        resolve: @escaping CellResolver = { _ in nil }
    ) -> FormulaValue {
        guard let formula = formulaBody(of: raw) else {
            return literalValue(of: raw)
        }
        var visiting = Set<CellReference>()
        if let origin { visiting.insert(origin) }
        return evaluateFormula(formula, resolve: resolve, visiting: &visiting)
    }

    /// Evaluate a formula body (the text AFTER the leading `=`). Exposed so a
    /// caller that already stripped the `=` (or wants to compose) can use it.
    public static func evaluateFormula(
        _ body: String,
        resolve: @escaping CellResolver = { _ in nil },
        visiting: inout Set<CellReference>
    ) -> FormulaValue {
        var parser = FormulaParser(tokens: FormulaLexer.tokenize(body))
        let ast: FormulaExpr
        do {
            ast = try parser.parseExpression()
            try parser.expectEnd()
        } catch let e as FormulaError {
            return .error(e)
        } catch {
            return .error(.parse)
        }
        var ctx = EvalContext(resolve: resolve, visiting: visiting)
        let result = evaluate(ast, &ctx)
        visiting = ctx.visiting
        return result
    }

    /// `true` when `raw` is a formula (after trimming, begins with `=`).
    public static func isFormula(_ raw: String) -> Bool {
        formulaBody(of: raw) != nil
    }

    /// The formula body if `raw` is a formula (`=…`), else nil. Leading
    /// whitespace before `=` is tolerated (matches spreadsheet leniency); a lone
    /// `=` yields an empty body (which evaluates to an error).
    static func formulaBody(of raw: String) -> String? {
        let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "=" else { return nil }
        return String(trimmed.dropFirst())
    }

    /// Interpret non-formula raw text as a literal value: a parseable number
    /// becomes `.number`, an empty string `.blank`, otherwise `.text`. Booleans
    /// are NOT auto-coerced from bare text (`TRUE` as a cell value is text);
    /// only formula syntax produces booleans.
    static func literalValue(of raw: String) -> FormulaValue {
        if raw.isEmpty { return .blank }
        if let n = parseNumber(raw) { return .number(n) }
        return .text(raw)
    }

    /// Parse a number the way the engine coerces text→number: trims surrounding
    /// whitespace, accepts an optional leading sign, a decimal, and scientific
    /// notation. Returns nil if the WHOLE trimmed string isn't a number.
    static func parseNumber(_ s: some StringProtocol) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // Reject NaN/Inf textual forms and hex (Double(_:) would accept some).
        for ch in t where !(ch.isASCIIDigit || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E") {
            return nil
        }
        return Double(t)
    }

    // MARK: - Evaluation

    private struct EvalContext {
        let resolve: CellResolver
        var visiting: Set<CellReference>
    }

    private static func evaluate(_ expr: FormulaExpr, _ ctx: inout EvalContext) -> FormulaValue {
        switch expr {
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .text(s)
        case .bool(let b):
            return .boolean(b)
        case .ref(let ref):
            return resolveCell(ref, &ctx)
        case .range:
            // A bare range used where a scalar is expected is an error; ranges
            // are only meaningful as function arguments (handled in `call`).
            return .error(.value)
        case .unary(let op, let operand):
            return applyUnary(op, evaluate(operand, &ctx))
        case .binary(let op, let lhs, let rhs):
            return applyBinary(op, evaluate(lhs, &ctx), evaluate(rhs, &ctx))
        case .call(let name, let args):
            return callFunction(name, args, &ctx)
        }
    }

    /// Resolve a single cell reference to a value, with cycle detection. A cell
    /// already on the `visiting` stack is a cycle → `#CYCLE!`. A blank/out-of-
    /// range cell is `.blank`. A cell whose own text is a formula is evaluated
    /// recursively (so `A1 = B1 + 1`, `B1 = 2` works).
    private static func resolveCell(_ ref: CellReference, _ ctx: inout EvalContext) -> FormulaValue {
        if ctx.visiting.contains(ref) { return .error(.cycle) }
        guard let raw = ctx.resolve(ref) else { return .blank }
        guard let body = formulaBody(of: raw) else {
            return literalValue(of: raw)
        }
        ctx.visiting.insert(ref)
        defer { ctx.visiting.remove(ref) }
        var parser = FormulaParser(tokens: FormulaLexer.tokenize(body))
        let ast: FormulaExpr
        do {
            ast = try parser.parseExpression()
            try parser.expectEnd()
        } catch let e as FormulaError {
            return .error(e)
        } catch {
            return .error(.parse)
        }
        return evaluate(ast, &ctx)
    }

    // MARK: Operators

    private static func applyUnary(_ op: FormulaUnaryOp, _ v: FormulaValue) -> FormulaValue {
        if case .error = v { return v }
        switch op {
        case .negate:
            guard let n = v.asNumber else { return .error(.value) }
            return .number(-n)
        case .plus:
            guard let n = v.asNumber else { return .error(.value) }
            return .number(n)
        case .percent:
            guard let n = v.asNumber else { return .error(.value) }
            return .number(n / 100.0)
        }
    }

    private static func applyBinary(_ op: FormulaBinaryOp, _ lhs: FormulaValue, _ rhs: FormulaValue) -> FormulaValue {
        if case .error = lhs { return lhs }
        if case .error = rhs { return rhs }

        switch op {
        case .concat:
            return .text(lhs.asText + rhs.asText)
        case .eq, .ne, .lt, .le, .gt, .ge:
            return compare(op, lhs, rhs)
        case .add, .sub, .mul, .div, .pow:
            guard let a = lhs.asNumber, let b = rhs.asNumber else { return .error(.value) }
            switch op {
            case .add: return .number(a + b)
            case .sub: return .number(a - b)
            case .mul: return .number(a * b)
            case .div:
                guard b != 0 else { return .error(.divideByZero) }
                return .number(a / b)
            case .pow: return .number(Foundation.pow(a, b))
            default: return .error(.value)   // unreachable
            }
        }
    }

    private static func compare(_ op: FormulaBinaryOp, _ lhs: FormulaValue, _ rhs: FormulaValue) -> FormulaValue {
        // Numeric comparison when both coerce to numbers; otherwise textual
        // (case-insensitive, matching spreadsheet text comparison).
        let result: Bool
        if let a = lhs.asNumber, let b = rhs.asNumber {
            switch op {
            case .eq: result = a == b
            case .ne: result = a != b
            case .lt: result = a < b
            case .le: result = a <= b
            case .gt: result = a > b
            case .ge: result = a >= b
            default: return .error(.value)
            }
        } else {
            let a = lhs.asText.lowercased()
            let b = rhs.asText.lowercased()
            switch op {
            case .eq: result = a == b
            case .ne: result = a != b
            case .lt: result = a < b
            case .le: result = a <= b
            case .gt: result = a > b
            case .ge: result = a >= b
            default: return .error(.value)
            }
        }
        return .boolean(result)
    }

    // MARK: Functions

    /// Collect the numeric values an argument expands to: a range flattens to
    /// the numbers in its cells (skipping blanks and non-numeric text, as SUM
    /// does), a scalar contributes its one number if numeric. An error operand
    /// propagates. Returns nil to signal "propagate this error" via `errorOut`.
    private static func numericValues(
        of args: [FormulaExpr],
        _ ctx: inout EvalContext,
        errorOut: inout FormulaError?
    ) -> [Double] {
        var nums = [Double]()
        for arg in args {
            if case .range(let a, let b) = arg {
                let range = CellRange(a, b)
                for ref in range.cells {
                    let v = resolveCell(ref, &ctx)
                    if case .error(let e) = v { errorOut = e; return [] }
                    if let n = numericContribution(v) { nums.append(n) }
                }
            } else {
                let v = evaluate(arg, &ctx)
                if case .error(let e) = v { errorOut = e; return [] }
                if let n = numericContribution(v) { nums.append(n) }
            }
        }
        return nums
    }

    /// The numeric contribution of a value to an aggregate (SUM/COUNT/…): a
    /// `.number` or `.boolean` counts; a `.blank` and a `.text` cell do NOT
    /// (blanks are absent; text — even numeric-looking — is not summed, matching
    /// spreadsheet range semantics). Returns nil to mean "skip this value".
    private static func numericContribution(_ v: FormulaValue) -> Double? {
        switch v {
        case .number(let n): return n
        case .boolean(let b): return b ? 1 : 0
        case .blank, .text, .error: return nil
        }
    }

    /// Count of non-blank values an argument list expands to (COUNTA), and
    /// separately the numeric count (COUNT) is `numericValues(...).count`.
    private static func nonBlankCount(
        of args: [FormulaExpr],
        _ ctx: inout EvalContext,
        errorOut: inout FormulaError?
    ) -> Int {
        var n = 0
        for arg in args {
            if case .range(let a, let b) = arg {
                for ref in CellRange(a, b).cells {
                    let v = resolveCell(ref, &ctx)
                    if case .error(let e) = v { errorOut = e; return 0 }
                    if case .blank = v { continue }
                    n += 1
                }
            } else {
                let v = evaluate(arg, &ctx)
                if case .error(let e) = v { errorOut = e; return 0 }
                if case .blank = v { continue }
                n += 1
            }
        }
        return n
    }

    private static func callFunction(_ name: String, _ args: [FormulaExpr], _ ctx: inout EvalContext) -> FormulaValue {
        switch name {
        case "SUM", "AVERAGE", "MIN", "MAX", "COUNT", "PRODUCT":
            var err: FormulaError?
            let nums = numericValues(of: args, &ctx, errorOut: &err)
            if let err { return .error(err) }
            switch name {
            case "SUM":     return .number(nums.reduce(0, +))
            case "PRODUCT": return .number(nums.reduce(1, *))
            case "COUNT":   return .number(Double(nums.count))
            case "AVERAGE":
                guard !nums.isEmpty else { return .error(.divideByZero) }
                return .number(nums.reduce(0, +) / Double(nums.count))
            case "MIN":     return nums.isEmpty ? .number(0) : .number(nums.min()!)
            case "MAX":     return nums.isEmpty ? .number(0) : .number(nums.max()!)
            default:        return .error(.name)
            }

        case "COUNTA":
            var err: FormulaError?
            let n = nonBlankCount(of: args, &ctx, errorOut: &err)
            if let err { return .error(err) }
            return .number(Double(n))

        case "ABS", "INT", "SQRT":
            guard args.count == 1 else { return .error(.value) }
            let v = evaluate(args[0], &ctx)
            if case .error = v { return v }
            guard let x = v.asNumber else { return .error(.value) }
            switch name {
            case "ABS":  return .number(abs(x))
            case "INT":  return .number(x.rounded(.down))
            case "SQRT": return x < 0 ? .error(.num) : .number(x.squareRoot())
            default:     return .error(.name)
            }

        case "ROUND":
            guard args.count == 1 || args.count == 2 else { return .error(.value) }
            let v = evaluate(args[0], &ctx)
            if case .error = v { return v }
            guard let x = v.asNumber else { return .error(.value) }
            var digits = 0
            if args.count == 2 {
                let dv = evaluate(args[1], &ctx)
                if case .error = dv { return dv }
                guard let d = dv.asNumber else { return .error(.value) }
                digits = Int(d)
            }
            let factor = Foundation.pow(10.0, Double(digits))
            return .number((x * factor).rounded() / factor)

        case "MOD", "POWER":
            guard args.count == 2 else { return .error(.value) }
            let a = evaluate(args[0], &ctx); if case .error = a { return a }
            let b = evaluate(args[1], &ctx); if case .error = b { return b }
            guard let x = a.asNumber, let y = b.asNumber else { return .error(.value) }
            if name == "MOD" {
                guard y != 0 else { return .error(.divideByZero) }
                // Excel MOD result takes the sign of the divisor.
                return .number(x - y * (x / y).rounded(.down))
            }
            return .number(Foundation.pow(x, y))

        case "IF":
            guard args.count == 2 || args.count == 3 else { return .error(.value) }
            let cond = evaluate(args[0], &ctx)
            if case .error = cond { return cond }
            let truthy = cond.asBool
            if truthy { return evaluate(args[1], &ctx) }
            return args.count == 3 ? evaluate(args[2], &ctx) : .boolean(false)

        case "AND", "OR":
            guard !args.isEmpty else { return .error(.value) }
            var acc = (name == "AND")
            for arg in args {
                let v = evaluate(arg, &ctx)
                if case .error = v { return v }
                if name == "AND" { acc = acc && v.asBool } else { acc = acc || v.asBool }
            }
            return .boolean(acc)

        case "NOT":
            guard args.count == 1 else { return .error(.value) }
            let v = evaluate(args[0], &ctx)
            if case .error = v { return v }
            return .boolean(!v.asBool)

        case "CONCAT", "CONCATENATE":
            var out = ""
            for arg in args {
                if case .range(let a, let b) = arg {
                    for ref in CellRange(a, b).cells {
                        let v = resolveCell(ref, &ctx)
                        if case .error = v { return v }
                        out += v.asText
                    }
                } else {
                    let v = evaluate(arg, &ctx)
                    if case .error = v { return v }
                    out += v.asText
                }
            }
            return .text(out)

        case "LEN", "UPPER", "LOWER", "TRIM":
            guard args.count == 1 else { return .error(.value) }
            let v = evaluate(args[0], &ctx)
            if case .error = v { return v }
            let s = v.asText
            switch name {
            case "LEN":   return .number(Double(s.count))
            case "UPPER": return .text(s.uppercased())
            case "LOWER": return .text(s.lowercased())
            case "TRIM":  return .text(s.trimmingCharacters(in: .whitespaces))
            default:      return .error(.name)
            }

        case "LEFT", "RIGHT":
            guard args.count == 1 || args.count == 2 else { return .error(.value) }
            let v = evaluate(args[0], &ctx); if case .error = v { return v }
            let s = v.asText
            var n = 1
            if args.count == 2 {
                let nv = evaluate(args[1], &ctx); if case .error = nv { return nv }
                guard let d = nv.asNumber else { return .error(.value) }
                n = Int(d)
            }
            guard n >= 0 else { return .error(.value) }
            let count = min(n, s.count)
            return .text(name == "LEFT" ? String(s.prefix(count)) : String(s.suffix(count)))

        case "MID":
            guard args.count == 3 else { return .error(.value) }
            let v = evaluate(args[0], &ctx); if case .error = v { return v }
            let sv = evaluate(args[1], &ctx); if case .error = sv { return sv }
            let lv = evaluate(args[2], &ctx); if case .error = lv { return lv }
            guard let startD = sv.asNumber, let lenD = lv.asNumber, startD >= 1, lenD >= 0
            else { return .error(.value) }
            let chars = Array(v.asText)
            let from = Int(startD) - 1                       // Excel MID is 1-based
            guard from < chars.count else { return .text("") }
            let to = min(from + Int(lenD), chars.count)
            return .text(String(chars[from..<to]))

        case "ROUNDUP", "ROUNDDOWN":
            guard args.count == 1 || args.count == 2 else { return .error(.value) }
            let v = evaluate(args[0], &ctx); if case .error = v { return v }
            guard let x = v.asNumber else { return .error(.value) }
            var digits = 0
            if args.count == 2 {
                let dv = evaluate(args[1], &ctx); if case .error = dv { return dv }
                guard let d = dv.asNumber else { return .error(.value) }
                digits = Int(d)
            }
            let factor = Foundation.pow(10.0, Double(digits))
            let scaled = x * factor
            let r = (name == "ROUNDUP") ? scaled.rounded(.awayFromZero) : scaled.rounded(.towardZero)
            return .number(r / factor)

        case "CEILING", "FLOOR":
            guard args.count == 1 || args.count == 2 else { return .error(.value) }
            let v = evaluate(args[0], &ctx); if case .error = v { return v }
            guard let x = v.asNumber else { return .error(.value) }
            var sig = 1.0
            if args.count == 2 {
                let s = evaluate(args[1], &ctx); if case .error = s { return s }
                guard let sg = s.asNumber else { return .error(.value) }
                sig = sg
            }
            guard sig != 0 else { return .number(0) }
            let q = x / sig
            return .number((name == "CEILING" ? q.rounded(.up) : q.rounded(.down)) * sig)

        case "IFERROR":
            guard args.count == 2 else { return .error(.value) }
            let v = evaluate(args[0], &ctx)
            if case .error = v { return evaluate(args[1], &ctx) }
            return v

        default:
            return .error(.name)
        }
    }
}

/// A closure that maps a cell reference to that cell's RAW text (the unparsed
/// contents, including a leading `=` if it is itself a formula), or nil for a
/// blank / out-of-range cell. This is the engine's ONLY view of the grid.
public typealias CellResolver = (CellReference) -> String?

// MARK: - EditableCSVModel bridge (minimal wiring)

extension EditableCSVModel {
    /// A `CellResolver` over this CSV grid. The formula engine addresses cells
    /// in A1 space where **A1 = the FIRST DATA row, column A** — i.e. the header
    /// row (grid row 0) is treated as labels, NOT as A1. So `A1` resolves to
    /// grid `(row: 1, column: 0)`, `B2` to grid `(row: 2, column: 1)`, etc. This
    /// matches how a user thinks about a CSV opened as a sheet: row 1 of the
    /// data is "row 1". Out-of-range refs and the header are returned as nil
    /// (blank) so a formula over them is well-defined.
    ///
    /// Note this captures a snapshot of the model by value (the model is a
    /// `struct`); re-derive the resolver after edits to see them.
    public func formulaResolver() -> CellResolver {
        { ref in
            // A1 → grid row 1 (skip header). Negative / header rows are blank.
            let gridRow = ref.row + 1
            guard gridRow >= 1 else { return nil }
            return self.getCell(row: gridRow, column: ref.column)
        }
    }

    /// Evaluate the cell at A1-space `reference` against this grid, returning its
    /// computed `FormulaValue`. A formula cell (`=…`) is evaluated; a literal is
    /// coerced. Convenience over `FormulaEngine.evaluate` for the CSV bridge.
    public func evaluateFormulaCell(at reference: CellReference) -> FormulaValue {
        let resolver = formulaResolver()
        guard let raw = resolver(reference) else { return .blank }
        return FormulaEngine.evaluate(raw: raw, origin: reference, resolve: resolver)
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

    /// Numeric coercion: numbers as-is, booleans as 1/0, numeric text parsed,
    /// blank as 0; otherwise nil (caller decides whether nil → error). Errors
    /// never coerce.
    public var asNumber: Double? {
        switch self {
        case .number(let n): return n
        case .boolean(let b): return b ? 1 : 0
        case .blank: return 0
        case .text(let s): return FormulaEngine.parseNumber(s)
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
            if let n = FormulaEngine.parseNumber(s) { return n != 0 }
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

    public var display: String {
        switch self {
        case .divideByZero: return "#DIV/0!"
        case .value:        return "#VALUE!"
        case .ref:          return "#REF!"
        case .name:         return "#NAME?"
        case .num:          return "#NUM!"
        case .cycle:        return "#CYCLE!"
        case .parse:        return "#ERROR!"
        }
    }
}
