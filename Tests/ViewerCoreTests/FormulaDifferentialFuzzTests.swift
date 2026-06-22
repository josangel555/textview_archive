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
            var rng = Xorshift(s: (seed &* 0x9E37_79B9_7F4A_7C15) | 1)
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
}
