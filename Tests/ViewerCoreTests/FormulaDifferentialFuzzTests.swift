import XCTest
import RustCore
@testable import ViewerCore

/// TSK-1125 / TSK-586 — DIFFERENTIAL fuzz for the formula engine. A std-only seeded
/// RNG generates random ARITHMETIC formulas (cell refs + non-negative integer
/// literals + `+ - * /` + parens + parenthesised unary minus) over a random integer
/// grid, and asserts the Swift `FormulaEngine` and the Rust port produce the SAME
/// `FormulaValue`. Random inputs catch precedence / associativity / evaluation-order
/// drift that the hand-written `FormulaParityTests` cases can miss — the golden-corpus
/// ticket (TSK-586) wanted "differential parity fuzzing, fixed seeds in the merge gate."
///
/// Design choices that keep it a deterministic, dependency-free, NON-flaky gate test:
/// - Seeded xorshift64 (no Foundation RNG) → byte-reproducible across runs/platforms.
/// - Arithmetic ONLY → both engines evaluate in f64 with identical ops/order, so the
///   comparison is EXACT (no float-format noise; we compare the `FormulaValue`, not a
///   display string). Scoping to arithmetic also avoids Rust's beyond-Swift functions
///   (wildcards, COUNTIFS, …) which would be a legitimate, not a bug, divergence.
/// - Non-negative literals + only parenthesised unary minus → no `5--3` adjacent-minus
///   tokens whose parse is ambiguous; divisions by a zero cell/literal yield #DIV/0!
///   in BOTH engines (equal), not NaN.
final class FormulaDifferentialFuzzTests: XCTestCase {

    /// Deterministic xorshift64* — reproducible, no Foundation dependency.
    private struct Xorshift {
        var s: UInt64
        mutating func next() -> UInt64 {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return s
        }
        mutating func int(_ lo: Int, _ hi: Int) -> Int {
            precondition(hi >= lo)
            return lo + Int(next() % UInt64(hi - lo + 1))
        }
    }

    private let cellNames = ["A1", "B1", "C1", "A2", "B2", "C2", "A3", "B3", "C3"]

    private func randomGrid(_ rng: inout Xorshift) -> [String: String] {
        var cells: [String: String] = [:]
        for name in cellNames { cells[name] = String(rng.int(-20, 20)) }
        return cells
    }

    /// Random arithmetic expression (no leading `=`), bounded by `depth`.
    private func randomExpr(_ rng: inout Xorshift, depth: Int) -> String {
        if depth <= 0 || rng.int(0, 2) == 0 {
            if rng.int(0, 1) == 0 { return cellNames[rng.int(0, cellNames.count - 1)] }
            return String(rng.int(0, 20)) // non-negative literal (no adjacent-minus)
        }
        let ops = ["+", "-", "*", "/"]
        let op = ops[rng.int(0, ops.count - 1)]
        let lhs = randomExpr(&rng, depth: depth - 1)
        let rhs = randomExpr(&rng, depth: depth - 1)
        let inner = "\(lhs)\(op)\(rhs)"
        switch rng.int(0, 3) {
        case 0: return "(\(inner))"
        case 1: return "-(\(inner))"          // parenthesised unary minus
        default: return inner
        }
    }

    func test_swift_rust_arithmetic_parity_random() throws {
        for seed in UInt64(1)...UInt64(40) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 { // 40 seeds × 25 = 1000 random cases
                let cells = randomGrid(&rng)
                let formula = "=" + randomExpr(&rng, depth: 4)
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
                XCTAssertEqual(rustResult, swiftResult,
                               "parity diverged: \(formula) over \(cells)")
            }
        }
    }

    /// A random rectangular A1 range within the 3×3 grid (start <= end on both axes).
    private func randomRange(_ rng: inout Xorshift) -> String {
        let cols = ["A", "B", "C"]
        var c1 = rng.int(0, 2)
        var c2 = rng.int(0, 2)
        if c1 > c2 { swap(&c1, &c2) }
        var r1 = rng.int(1, 3)
        var r2 = rng.int(1, 3)
        if r1 > r2 { swap(&r1, &r2) }
        return "\(cols[c1])\(r1):\(cols[c2])\(r2)"
    }

    /// Differential fuzz over the shared AGGREGATE functions (a distinct eval path
    /// from arithmetic: function dispatch + range collection). Integer grid values
    /// are exactly representable in f64, so the sum/product is order-independent —
    /// no float-associativity false divergence; equality stays exact.
    func test_swift_rust_aggregate_parity_random() throws {
        let funcs = ["SUM", "AVERAGE", "MIN", "MAX", "COUNT", "PRODUCT"]
        for seed in UInt64(101)...UInt64(140) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 { // 40 seeds × 25 = 1000 random aggregate cases
                let cells = randomGrid(&rng)
                let fn = funcs[rng.int(0, funcs.count - 1)]
                let formula = "=\(fn)(\(randomRange(&rng)))"
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
                XCTAssertEqual(rustResult, swiftResult,
                               "aggregate parity diverged: \(formula) over \(cells)")
            }
        }
    }

    /// A short random ASCII LETTERS string, sometimes with a leading/trailing SPACE
    /// (for TRIM + whitespace-coercion coverage). Whitespace was briefly excluded
    /// while TSK-1218 was open: this fuzz found the RUST port coerced a whitespace-
    /// only cell to Blank (LEN=0, UPPER="") vs Swift/Excel's text " ". Now FIXED
    /// (coerce_cell judges emptiness on the original string), so whitespace is
    /// re-enabled here to GUARD the fix against regression.
    private func randomAsciiCell(_ rng: inout Xorshift) -> String {
        var s = rng.int(0, 3) == 0 ? " " : ""
        for _ in 0..<rng.int(0, 8) {
            let c = rng.int(0, 51)
            let code = c < 26 ? (65 + c) : (97 + c - 26) // A–Z or a–z
            s.append(Character(UnicodeScalar(UInt8(code))))
        }
        if rng.int(0, 3) == 0 { s += " " }
        return s
    }

    /// Differential fuzz over the shared, index-free TEXT functions (a third eval
    /// path: string ops). UPPER/LOWER/LEN/TRIM/CONCAT over random ASCII cells
    /// (incl. whitespace — guards the TSK-1218 coerce_cell fix). Excludes LEFT/RIGHT/
    /// MID (index-arg clamping is its own surface) and PROPER (Rust defers ICU
    /// `.capitalized`). ASCII keeps the comparison exact.
    func test_swift_rust_text_parity_random() throws {
        let unary = ["UPPER", "LOWER", "LEN", "TRIM"]
        for seed in UInt64(201)...UInt64(240) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 { // 40 seeds × 25 = 1000 random text cases
                var cells: [String: String] = [:]
                for name in cellNames { cells[name] = randomAsciiCell(&rng) }
                let r1 = cellNames[rng.int(0, cellNames.count - 1)]
                let formula: String
                if rng.int(0, 4) == 0 {
                    let r2 = cellNames[rng.int(0, cellNames.count - 1)]
                    formula = "=CONCAT(\(r1),\(r2))"
                } else {
                    formula = "=\(unary[rng.int(0, unary.count - 1)])(\(r1))"
                }
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
                XCTAssertEqual(rustResult, swiftResult,
                               "text parity diverged: \(formula) over \(cells)")
            }
        }
    }

    /// Differential fuzz over the shared DATE functions — the highest-risk parity
    /// surface, since the two engines use INDEPENDENT calendar implementations
    /// (Swift UTC Gregorian `Calendar` vs the Rust hand-rolled Hinnant civil-date).
    /// Random valid ISO dates through YEAR/MONTH/DAY/WEEKDAY, DATEDIF (ordered span,
    /// D/M/Y — the day-boundary logic is subtle), EDATE/EOMONTH (±months, month-end
    /// clamping + leap years), and DATE() with month/day rollover.
    func test_swift_rust_date_parity_random() throws {
        func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        func iso(_ rng: inout Xorshift) -> String {
            // day 1–28 keeps every (year, month) valid without a days-in-month table.
            "\(rng.int(2000, 2035))-\(pad2(rng.int(1, 12)))-\(pad2(rng.int(1, 28)))"
        }
        for seed in UInt64(301)...UInt64(340) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 { // 40 seeds × 25 = 1000 random date cases
                let a = iso(&rng)
                let b = iso(&rng)
                let cells = ["A1": min(a, b), "A2": max(a, b)] // ISO sorts chronologically
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let formula: String
                switch rng.int(0, 6) {
                case 0: // DATE() with month/day rollover
                    formula = "=DATE(\(rng.int(2000, 2035)),\(rng.int(1, 15)),\(rng.int(1, 35)))"
                case 1: formula = "=YEAR(A1)"
                case 2: formula = "=MONTH(A1)"
                case 3: formula = "=DAY(A1)"
                case 4:
                    let t = ["", ",2"][rng.int(0, 1)] // the parity-pinned WEEKDAY types
                    formula = "=WEEKDAY(A1\(t))"
                case 5:
                    let unit = ["D", "M", "Y"][rng.int(0, 2)]
                    formula = "=DATEDIF(A1,A2,\"\(unit)\")"
                default:
                    let fn = rng.int(0, 1) == 0 ? "EDATE" : "EOMONTH"
                    formula = "=\(fn)(A1,\(rng.int(-24, 24)))"
                }
                let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
                XCTAssertEqual(rustResult, swiftResult,
                               "date parity diverged: \(formula) over \(cells)")
            }
        }
    }

    /// Number-coercion edge parity: whether a cell value is classified as a NUMBER.
    /// Excel + the Swift engine char-restrict number detection to `[0-9.+-eE]`, so
    /// `inf`/`nan`/`infinity` are TEXT — but Rust's `f64::parse` accepts them. Pins
    /// the boundary so the two engines agree on what is (and isn't) a number.
    func test_swift_rust_number_coercion_edges() throws {
        let edges = ["inf", "-inf", "nan", "NaN", "Infinity", "infinity",
                     "5", "+5", "-5", ".5", "5.", "1e3", "1E3", "0x10", "abc", " 7 ", ""]
        for v in edges {
            let cells = ["A1": v]
            let resolver: CellResolver = { ref in cells[ref.a1] }
            let formula = "=ISNUMBER(A1)"
            let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
            let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
            XCTAssertEqual(rustResult, swiftResult,
                           "number-coercion parity diverged: ISNUMBER over A1=\(v.debugDescription)")
        }
    }

    /// Number FORMATTING parity (Number → text via CONCAT/value_text/formatNumber) —
    /// the display path, never pinned by the value-equality fuzz. Integers,
    /// terminating + NON-terminating decimals, small magnitudes (scientific),
    /// negatives. Guards the TSK-1221 fix: Rust `format_number` now mirrors Swift's
    /// `%.10g` + integer special-case (replacing `f64::to_string`'s 16-digit output,
    /// e.g. 1/3 was "0.3333333333333333", now "0.3333333333").
    func test_swift_rust_number_format_edges() throws {
        let formulas = ["=CONCAT(5,\"\")", "=CONCAT(-5,\"\")", "=CONCAT(0,\"\")",
                        "=CONCAT(1000000,\"\")", "=CONCAT(0.5,\"\")", "=CONCAT(0.1,\"\")",
                        "=CONCAT(1.5,\"\")", "=CONCAT(123.456,\"\")", "=CONCAT((10/4),\"\")",
                        "=CONCAT(100000000,\"\")", "=CONCAT(0.0001,\"\")", "=CONCAT((1/8),\"\")",
                        "=CONCAT((7/2),\"\")", "=CONCAT((-1/4),\"\")", "=CONCAT(1000000000000,\"\")",
                        "=CONCAT((1/3),\"\")", "=CONCAT((2/3),\"\")",
                        "=CONCAT((1/1000000000000),\"\")"]
        for f in formulas {
            let resolver: CellResolver = { _ in nil }
            let swiftResult = FormulaEngine.evaluate(raw: f, resolve: resolver)
            let rustResult = try RustFormulaAdapter.rustEvaluate(f, cells: [:])
            XCTAssertEqual(rustResult, swiftResult, "number-format parity diverged: \(f)")
        }
    }

    /// `&` string-concat operator parity (TSK-1220, now implemented in the Rust port).
    /// Mixed text/number operands, chaining, and precedence (`&` looser than +/*,
    /// tighter than comparison). Integer numerics only (avoids the TSK-1221 long-
    /// decimal formatNumber gap).
    func test_swift_rust_concat_operator_parity() throws {
        let cells = ["A1": "foo", "B1": "bar", "C1": "5"]
        let resolver: CellResolver = { ref in cells[ref.a1] }
        let formulas = ["=A1&B1", "=A1&\" \"&B1", "=\"x\"&C1", "=C1&\"!\"", "=A1&B1&C1",
                        "=1+2&3", "=2&3*4", "=\"\"&A1", "=C1&C1"]
        for f in formulas {
            let swiftResult = FormulaEngine.evaluate(raw: f, resolve: resolver)
            let rustResult = try RustFormulaAdapter.rustEvaluate(f, cells: cells)
            XCTAssertEqual(rustResult, swiftResult, "concat-operator parity diverged: \(f)")
        }
    }

    /// Comparison-operator parity over MIXED operand types — number/number,
    /// case-insensitive text/text, text-vs-number (Excel ranks any text above any
    /// number), and blank coercion. Exercises the value_text path touched by the
    /// TSK-1221 fix; completes the core-operator parity coverage.
    func test_swift_rust_comparison_parity() throws {
        let pairs = [("5", "10"), ("10", "5"), ("5", "5"), ("abc", "ABC"), ("abc", "abd"),
                     ("5", "abc"), ("abc", "5"), ("", "0"), ("0", ""), ("1", "1.0"),
                     ("2.5", "2.5"), ("TRUE", "TRUE")]
        let ops = ["=", "<>", "<", ">", "<=", ">="]
        for (a, b) in pairs {
            let cells = ["A1": a, "B1": b]
            let resolver: CellResolver = { ref in cells[ref.a1] }
            for op in ops {
                let f = "=A1\(op)B1"
                let swiftResult = FormulaEngine.evaluate(raw: f, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(f, cells: cells)
                XCTAssertEqual(rustResult, swiftResult,
                               "comparison parity diverged: \(f) over A1=\(a.debugDescription) B1=\(b.debugDescription)")
            }
        }
    }

    /// COUNTIF/SUMIF criteria-parsing parity over NUMERIC criteria (operator +
    /// threshold, and the bare-value implicit-equals form). Wildcards/text criteria
    /// are excluded — those are a Rust-only extension (TSK-1216), a legitimate (not
    /// bug) divergence. Exercises the criterion-operator parser, lightly hand-tested.
    func test_swift_rust_countif_criteria_parity() throws {
        let ops = [">", "<", ">=", "<=", "<>", "=", ""] // "" = bare value (implicit =)
        for seed in UInt64(401)...UInt64(440) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 {
                let cells = randomGrid(&rng)
                let op = ops[rng.int(0, ops.count - 1)]
                let threshold = rng.int(-20, 20)
                let fn = ["COUNTIF", "SUMIF"][rng.int(0, 1)]
                let formula = "=\(fn)(A1:C3,\"\(op)\(threshold)\")"
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let swiftResult = FormulaEngine.evaluate(raw: formula, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(formula, cells: cells)
                XCTAssertEqual(rustResult, swiftResult,
                               "criteria parity diverged: \(formula) over \(cells)")
            }
        }
    }

    /// RECALC parity — the app's actual formula display path (EditableCSVModel.
    /// recalcAllFormulas), distinct from single-eval: formula cells reference OTHER
    /// cells, forming chains and (randomly) cycles. A/B via the gate env toggle.
    /// Arithmetic-only refs keep cells comma-free (CSV-safe) and parity-clean.
    func test_swift_rust_recalc_parity_random() throws {
        let cols = ["A", "B", "C"]
        for seed in UInt64(501)...UInt64(530) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<10 { // 30 seeds × 10 = 300 random formula grids
                var rows: [[String]] = []
                for _ in 0..<3 {
                    var row: [String] = []
                    for _ in 0..<3 {
                        if rng.int(0, 2) == 0 {
                            let ref1 = "\(cols[rng.int(0, 2)])\(rng.int(1, 3))"
                            if rng.int(0, 1) == 0 {
                                row.append("=\(ref1)+\(rng.int(1, 9))")
                            } else {
                                let ref2 = "\(cols[rng.int(0, 2)])\(rng.int(1, 3))"
                                let op = ["+", "-", "*"][rng.int(0, 2)]
                                row.append("=\(ref1)\(op)\(ref2)")
                            }
                        } else {
                            row.append("\(rng.int(0, 20))")
                        }
                    }
                    rows.append(row)
                }
                let csv = "a,b,c\n" + rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
                let model = EditableCSVModel(parsing: csv)
                let rust = model.recalcAllFormulas(environment: ["MDV_RUST_FORMULA": "1"])
                let swift = model.recalcAllFormulas(environment: ["MDV_RUST_FORMULA": "0"])
                XCTAssertEqual(rust, swift, "recalc parity diverged:\n\(csv)")
            }
        }
    }

    /// LOGICAL-function parity (IF / AND / OR / NOT + nesting) over numeric
    /// conditions — exercises truthiness coercion and branch selection, a path the
    /// arithmetic / comparison / criteria fuzzes don't cover. Conditions are numeric
    /// comparisons (shared semantics); IF branches return cell values or arithmetic.
    func test_swift_rust_logical_parity_random() throws {
        let ops = ["<", ">", "<=", ">=", "=", "<>"]
        for seed in UInt64(701)...UInt64(740) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 {
                let cells = randomGrid(&rng)
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let op1 = ops[rng.int(0, ops.count - 1)]
                let op2 = ops[rng.int(0, ops.count - 1)]
                let formulas = [
                    "=IF(A1\(op1)B1, A1, B1)",
                    "=AND(A1\(op1)B1, C1\(op2)A2)",
                    "=OR(A1\(op1)B1, C1\(op2)A2)",
                    "=NOT(A1\(op1)B1)",
                    "=IF(AND(A1\(op1)B1, C1\(op2)A2), A1+B1, A1-B1)",
                    "=IF(OR(A1\(op1)B1, C1\(op2)A2), 1, 0)",
                ]
                let f = formulas[rng.int(0, formulas.count - 1)]
                let swiftResult = FormulaEngine.evaluate(raw: f, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(f, cells: cells)
                XCTAssertEqual(rustResult, swiftResult, "logical parity diverged: \(f) over \(cells)")
            }
        }
    }

    /// LOOKUP-function parity (VLOOKUP / HLOOKUP / MATCH / INDEX) over a random grid.
    /// EXACT-match only (FALSE / 0) + in-bounds INDEX: approximate match assumes
    /// sorted data (undefined on random input — a parity-lock zone), excluded like the
    /// criteria fuzz's wildcards. The lookup value is sometimes a real grid cell (a
    /// hit) and sometimes random (an #N/A miss), so both branches are exercised.
    func test_swift_rust_lookup_parity_random() throws {
        for seed in UInt64(801)...UInt64(840) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 {
                let cells = randomGrid(&rng)
                let resolver: CellResolver = { ref in cells[ref.a1] }
                let val = (rng.int(0, 1) == 0) ? (cells["A1"] ?? "0") : "\(rng.int(0, 30))"
                let row = rng.int(1, 3)
                let col = rng.int(1, 3)
                let formulas = [
                    "=VLOOKUP(\(val), A1:C3, \(col), FALSE)",
                    "=HLOOKUP(\(val), A1:C3, \(row), FALSE)",
                    "=MATCH(\(val), A1:A3, 0)",
                    "=INDEX(A1:C3, \(row), \(col))",
                ]
                let f = formulas[rng.int(0, formulas.count - 1)]
                let swiftResult = FormulaEngine.evaluate(raw: f, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(f, cells: cells)
                XCTAssertEqual(rustResult, swiftResult, "lookup parity diverged: \(f) over \(cells)")
            }
        }
    }

    /// MATH-function parity (ROUND/ROUNDUP/ROUNDDOWN/TRUNC/INT/ABS/SQRT/MOD/POWER/
    /// CEILING/FLOOR) over random decimals + negatives. Edge-prone: MOD's sign
    /// convention (result takes the DIVISOR's sign in Excel, not Rust `%`'s dividend
    /// sign), rounding direction, and CEILING/FLOOR with negatives + fractional
    /// significance. Literals (not cells) so both engines parse the SAME f64 — any
    /// divergence is a real algorithm difference, not parse noise. Errors (MOD by 0)
    /// must match too.
    func test_swift_rust_math_func_parity_random() throws {
        let resolver: CellResolver = { _ in nil }
        for seed in UInt64(901)...UInt64(940) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 {
                let a = Double(rng.int(-500, 500)) / 10.0  // -50.0…50.0, one decimal
                let b = rng.int(-12, 12)                   // MOD divisor / POWER exponent (may be 0)
                let d = rng.int(0, 3)                      // round digits
                let sig = Double(rng.int(1, 5)) / 2.0      // CEILING/FLOOR significance 0.5…2.5
                let formulas = [
                    "=ROUND(\(a), \(d))",
                    "=ROUNDUP(\(a), \(d))",
                    "=ROUNDDOWN(\(a), \(d))",
                    "=TRUNC(\(a), \(d))",
                    "=INT(\(a))",
                    "=ABS(\(a))",
                    "=SQRT(\(abs(a)))",
                    "=MOD(\(a), \(b))",
                    "=POWER(\(b), \(d))",
                    "=CEILING(\(a), \(sig))",
                    "=FLOOR(\(a), \(sig))",
                ]
                let f = formulas[rng.int(0, formulas.count - 1)]
                let swiftResult = FormulaEngine.evaluate(raw: f, resolve: resolver)
                let rustResult = try RustFormulaAdapter.rustEvaluate(f, cells: [:])
                XCTAssertEqual(rustResult, swiftResult, "math-func parity diverged: \(f)")
            }
        }
    }
}
