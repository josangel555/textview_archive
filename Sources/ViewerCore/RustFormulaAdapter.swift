import Foundation
import RustCore

/// Bridges the Rust core's formula evaluator (TSK-1213) into the app's
/// `FormulaValue`, so the CSV `=` cell path can route through Rust behind
/// `RustFormulaGate` without changing its rendering. Mirrors `RustCSVAdapter`:
/// fail-safe — any bridge throw (decode error, caught FFI panic, a future status
/// the Swift side doesn't know) falls back to the Swift `FormulaEngine`, so a
/// bridge fault degrades to today's behavior rather than blanking a cell.
public enum RustFormulaAdapter {

    /// Map a RustCore `CoreFormulaValue` onto the app's `FormulaValue`.
    public static func mapValue(_ core: CoreFormulaValue) -> FormulaValue {
        switch core {
        case .number(let n): return .number(n)
        case .text(let s): return .text(s)
        case .boolean(let b): return .boolean(b)
        case .blank: return .blank
        case .error(let code): return .error(formulaError(fromCode: code))
        }
    }

    /// Map Rust's lowercase error code (`FormulaError`'s serde rename) onto the
    /// Swift `FormulaError`. An unknown code degrades to `#VALUE!`.
    static func formulaError(fromCode code: String) -> FormulaError {
        switch code {
        case "dividebyzero": return .divideByZero
        case "value": return .value
        case "ref": return .ref
        case "name": return .name
        case "num": return .num
        case "cycle": return .cycle
        case "parse": return .parse
        case "na": return .na
        default: return .value
        }
    }

    /// Force the Rust path: evaluate `formula` against the `cells` snapshot
    /// (A1 → raw text), mapped to `FormulaValue`. Throws on a bridge fault.
    /// Bypasses the gate — for the A/B harness and parity tests.
    public static func rustEvaluate(_ formula: String, cells: [String: String]) throws -> FormulaValue {
        // Mirror FormulaEngine's raw contract: a leading `=` marks a formula and
        // the Rust evaluator parses the body, so strip it before sending.
        let body = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        guard let first = try mdvCoreEvaluateFormulas([body], cells: cells).first else {
            throw CoreError.decode("formula_evaluate returned no value")
        }
        return mapValue(first)
    }

    /// Recalculate a whole grid through the Rust core: A1 → raw text in, the
    /// computed `FormulaValue` of every formula cell out (keyed by `CellReference`).
    /// References to other formula cells resolve to their computed value (the
    /// recursion the stateless per-cell path can't do). Throws on a bridge fault.
    public static func recalc(cells: [String: String]) throws -> [CellReference: FormulaValue] {
        let raw = try mdvCoreRecalc(cells: cells)
        var out: [CellReference: FormulaValue] = [:]
        out.reserveCapacity(raw.count)
        for (a1, value) in raw {
            guard let ref = CellReference(a1: a1) else { continue }
            out[ref] = mapValue(value)
        }
        return out
    }

    /// Gated evaluate: route through the Rust core when `RustFormulaGate` is on
    /// AND the bridge succeeds; otherwise run `swiftEval` (the incumbent
    /// `FormulaEngine` path, which keeps its own lazy cell resolver). Fail-safe.
    public static func evaluate(
        _ formula: String,
        cells: [String: String],
        environment: [String: String]? = nil,
        swiftEval: () -> FormulaValue
    ) -> FormulaValue {
        guard RustFormulaGate.isEnabled(environment: environment) else { return swiftEval() }
        do {
            let result = try rustEvaluate(formula, cells: cells)
            // A #NAME! from Rust can mean a Swift-only function the port doesn't
            // implement (e.g. PROPER, whose Foundation `.capitalized` ICU word
            // semantics aren't safely reproducible in Rust). Fall back so we never
            // regress an existing function. Sound: the Rust function set is a
            // subset of Swift's, so a genuine #NAME! matches in both engines.
            if case .error(.name) = result { return swiftEval() }
            return result
        } catch {
            return swiftEval()
        }
    }
}
