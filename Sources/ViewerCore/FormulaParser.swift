import Foundation

/// TSK-673 — tokenizer + recursive-descent parser for the formula engine.
///
/// Kept in its own file from `FormulaEngine` (the evaluator) so the grammar is
/// readable on its own. The grammar (lowest → highest precedence):
///
///   expr        := compare
///   compare     := concat ( (= <> < <= > >=) concat )*
///   concat      := additive ( '&' additive )*
///   additive    := multiplicative ( (+ -) multiplicative )*
///   multiplicative := unary ( (* /) unary )*
///   unary       := (+ -) unary | power            // sign binds looser than ^
///   power       := postfix ( '^' unary )?         // right-assoc; -2^2 == -4
///   postfix     := primary '%'*                    // percent
///   primary     := number | string | bool
///                | NAME '(' args? ')'              // function call
///                | ref (':' ref)?                  // cell or range
///                | '(' expr ')'
///   args        := expr (',' expr)*
///
/// All of it is pure value logic — fully host-testable, no UI, no I/O. All
/// types are `Formula`-prefixed to avoid colliding with the module's existing
/// `Parser` (SwiftTreeSitter), `Token`, and `Expr` names.

// MARK: - AST

enum FormulaExpr {
    case number(Double)
    case string(String)
    case bool(Bool)
    indirect case ref(CellReference)
    indirect case range(CellReference, CellReference)
    indirect case unary(FormulaUnaryOp, FormulaExpr)
    indirect case binary(FormulaBinaryOp, FormulaExpr, FormulaExpr)
    indirect case call(String, [FormulaExpr])
}

enum FormulaUnaryOp { case negate, plus, percent }

enum FormulaBinaryOp {
    case add, sub, mul, div, pow
    case concat
    case eq, ne, lt, le, gt, ge
}

// MARK: - Tokens

enum FormulaToken: Equatable {
    case number(Double)
    case string(String)
    case identifier(String)       // function name or cell-ref letters+digits
    case op(String)               // + - * / ^ & = <> < <= > >= % ( ) , :
}

// MARK: - Lexer

enum FormulaLexer {
    /// Tokenize a formula body. Unknown characters become a sentinel that makes
    /// the parser fail with `.parse` — we never throw from the lexer so the
    /// parser owns all error reporting.
    static func tokenize(_ input: String) -> [FormulaToken] {
        var tokens = [FormulaToken]()
        let chars = Array(input)
        var i = 0
        let n = chars.count

        func peek(_ ahead: Int = 0) -> Character? {
            let idx = i + ahead
            return idx < n ? chars[idx] : nil
        }

        while i < n {
            let c = chars[i]

            // Whitespace
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
                continue
            }

            // String literal "…" with "" as an escaped quote.
            if c == "\"" {
                i += 1
                var s = ""
                while i < n {
                    if chars[i] == "\"" {
                        if peek(1) == "\"" { s.append("\""); i += 2; continue }
                        i += 1
                        break
                    }
                    s.append(chars[i]); i += 1
                }
                tokens.append(.string(s))
                continue
            }

            // Number: digits with optional decimal and exponent. A leading dot
            // (".5") is supported.
            if c.isASCIIDigit || (c == "." && (peek(1)?.isASCIIDigit ?? false)) {
                var s = ""
                while i < n, chars[i].isASCIIDigit || chars[i] == "." {
                    s.append(chars[i]); i += 1
                }
                // Exponent
                if i < n, chars[i] == "e" || chars[i] == "E" {
                    s.append(chars[i]); i += 1
                    if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                    while i < n, chars[i].isASCIIDigit { s.append(chars[i]); i += 1 }
                }
                tokens.append(.number(Double(s) ?? .nan))
                continue
            }

            // Identifier: a run of letters then optional digits (cell ref like
            // A1, or a function/keyword like SUM/TRUE). Letters-then-digits or
            // pure letters both land here; the parser disambiguates.
            if c.isLetterASCII {
                var s = ""
                while i < n, chars[i].isLetterASCII || chars[i].isASCIIDigit || chars[i] == "_" {
                    s.append(chars[i]); i += 1
                }
                tokens.append(.identifier(s))
                continue
            }

            // Two-char operators first.
            if c == "<" && peek(1) == "=" { tokens.append(.op("<=")); i += 2; continue }
            if c == ">" && peek(1) == "=" { tokens.append(.op(">=")); i += 2; continue }
            if c == "<" && peek(1) == ">" { tokens.append(.op("<>")); i += 2; continue }

            // Single-char operators / punctuation.
            if "+-*/^&=<>%(),:".contains(c) {
                tokens.append(.op(String(c))); i += 1
                continue
            }

            // Anything else: an unknown char. Emit a poison op the parser
            // rejects so the whole formula resolves to #ERROR!.
            tokens.append(.op("\u{0}"))
            i += 1
        }
        return tokens
    }
}

// MARK: - Parser

struct FormulaParser {
    private let tokens: [FormulaToken]
    private var pos = 0

    init(tokens: [FormulaToken]) { self.tokens = tokens }

    private func peek() -> FormulaToken? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func advance() -> FormulaToken? {
        guard pos < tokens.count else { return nil }
        defer { pos += 1 }
        return tokens[pos]
    }

    private func isOp(_ s: String) -> Bool {
        if case .op(let o)? = peek() { return o == s }
        return false
    }

    @discardableResult
    private mutating func consumeOp(_ s: String) -> Bool {
        if isOp(s) { pos += 1; return true }
        return false
    }

    /// After a full parse, assert there are no trailing tokens (a trailing
    /// token means malformed input like `1 2`).
    mutating func expectEnd() throws {
        if peek() != nil { throw FormulaError.parse }
    }

    // expr := compare
    mutating func parseExpression() throws -> FormulaExpr { try parseCompare() }

    private mutating func parseCompare() throws -> FormulaExpr {
        var lhs = try parseConcat()
        while case .op(let o)? = peek(), ["=", "<>", "<", "<=", ">", ">="].contains(o) {
            pos += 1
            let rhs = try parseConcat()
            let op: FormulaBinaryOp
            switch o {
            case "=":  op = .eq
            case "<>": op = .ne
            case "<":  op = .lt
            case "<=": op = .le
            case ">":  op = .gt
            default:   op = .ge
            }
            lhs = .binary(op, lhs, rhs)
        }
        return lhs
    }

    private mutating func parseConcat() throws -> FormulaExpr {
        var lhs = try parseAdditive()
        while consumeOp("&") {
            let rhs = try parseAdditive()
            lhs = .binary(.concat, lhs, rhs)
        }
        return lhs
    }

    private mutating func parseAdditive() throws -> FormulaExpr {
        var lhs = try parseMultiplicative()
        while case .op(let o)? = peek(), o == "+" || o == "-" {
            pos += 1
            let rhs = try parseMultiplicative()
            lhs = .binary(o == "+" ? .add : .sub, lhs, rhs)
        }
        return lhs
    }

    private mutating func parseMultiplicative() throws -> FormulaExpr {
        var lhs = try parseUnary()
        while case .op(let o)? = peek(), o == "*" || o == "/" {
            pos += 1
            let rhs = try parseUnary()
            lhs = .binary(o == "*" ? .mul : .div, lhs, rhs)
        }
        return lhs
    }

    // Unary sign binds LOOSER than `^`, so `-2^2` parses as `-(2^2)` = -4
    // (standard math / Google Sheets convention; Excel differs).
    private mutating func parseUnary() throws -> FormulaExpr {
        if case .op(let o)? = peek(), o == "-" || o == "+" {
            pos += 1
            let operand = try parseUnary()
            return .unary(o == "-" ? .negate : .plus, operand)
        }
        return try parsePower()
    }

    // power is right-associative: 2^3^2 == 2^(3^2). Its rhs is a full unary so
    // `2^-3` (negative exponent) parses.
    private mutating func parsePower() throws -> FormulaExpr {
        let lhs = try parsePostfix()
        if consumeOp("^") {
            let rhs = try parseUnary()
            return .binary(.pow, lhs, rhs)
        }
        return lhs
    }

    private mutating func parsePostfix() throws -> FormulaExpr {
        var e = try parsePrimary()
        while consumeOp("%") {
            e = .unary(.percent, e)
        }
        return e
    }

    private mutating func parsePrimary() throws -> FormulaExpr {
        guard let tok = advance() else { throw FormulaError.parse }
        switch tok {
        case .number(let n):
            guard !n.isNaN else { throw FormulaError.parse }
            return .number(n)

        case .string(let s):
            return .string(s)

        case .op("("):
            let e = try parseExpression()
            guard consumeOp(")") else { throw FormulaError.parse }
            return e

        case .op("\u{0}"):
            throw FormulaError.parse

        case .identifier(let name):
            return try parseIdentifier(name)

        default:
            throw FormulaError.parse
        }
    }

    /// An identifier is one of: a function call (`NAME(`), a boolean literal
    /// (`TRUE`/`FALSE`), or a cell reference (`A1`), optionally the start of a
    /// range (`A1:B3`).
    private mutating func parseIdentifier(_ name: String) throws -> FormulaExpr {
        // Function call?
        if isOp("(") {
            pos += 1
            var args = [FormulaExpr]()
            if !isOp(")") {
                args.append(try parseExpression())
                while consumeOp(",") {
                    args.append(try parseExpression())
                }
            }
            guard consumeOp(")") else { throw FormulaError.parse }
            return .call(name.uppercased(), args)
        }

        // Boolean literal?
        let upper = name.uppercased()
        if upper == "TRUE" { return .bool(true) }
        if upper == "FALSE" { return .bool(false) }

        // Cell reference (possibly the start of a range).
        guard let ref = CellReference(a1: name) else {
            // A bare name that's neither a function nor a valid ref → #NAME?.
            throw FormulaError.name
        }
        if consumeOp(":") {
            guard case .identifier(let endName)? = advance(),
                  let endRef = CellReference(a1: endName) else {
                throw FormulaError.parse
            }
            return .range(ref, endRef)
        }
        return .ref(ref)
    }
}
