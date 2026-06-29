import Foundation

/// TSK-723 — parse a small, tree-sitter-inspired structural-query DSL into a
/// `StructuralQuery`. The host engine + matcher already exist
/// (`StructuralSearchEngine.structuralSearch`); this is the user-facing PATTERN
/// GRAMMAR — the string a user types in the (future) structural-search bar
/// (TSK-1161 UI). Pure + dependency-free + TOTAL: the input is untrusted, so `parse`
/// must never panic — malformed queries throw `ParseError`, never trap.
///
/// ## Grammar (v1)
/// ```
///   query    := kindSpec capture? term*
///   kindSpec := IDENT ('|' IDENT)*        // OR set of node kinds
///             | '*'                       // wildcard — match ANY kind
///   capture  := '@' IDENT                 // capture the whole matched node as $IDENT
///   term     := field | child
///   field    := IDENT '='  ('$' IDENT | rhs)   // field text equals rhs, OR bind capture $IDENT
///             | IDENT '~'  rhs                  // field text contains rhs
///             | IDENT ':'  IDENT               // field's node KIND equals IDENT
///   child    := '(' query ')'             // a DESCENDANT must match this subquery
///   rhs      := '"' chars '"' | BAREWORD
/// ```
/// Examples:
///   `function_declaration name=$X`            — functions, capturing the name as $X
///   `call_expression name="print"`            — calls to print
///   `if_statement|guard_statement`            — either kind
///   `function_declaration @func (return_statement)` — a function (captured) containing a return
///   `assignment value:integer_literal`        — assignments whose value is an integer literal
public enum StructuralQueryParser {

    public struct ParseError: Error, Equatable {
        public let message: String
        public let position: Int
        public init(_ message: String, at position: Int) {
            self.message = message
            self.position = position
        }
    }

    /// Parse `source` into a `StructuralQuery`. Throws `ParseError` on malformed input.
    public static func parse(_ source: String) throws -> StructuralQuery {
        let toks = tokenize(source)
        var i = 0
        let q = try parseQuery(toks, &i, end: toks.count)
        if i < toks.count {
            throw ParseError("unexpected '\(toks[i].text)'", at: toks[i].pos)
        }
        return q
    }

    // MARK: - Tokens

    enum Kind: Equatable { case ident, string, pipe, at, eq, tilde, colon, dollar, star, lparen, rparen }
    struct Token: Equatable { let kind: Kind; let text: String; let pos: Int }

    static func tokenize(_ s: String) -> [Token] {
        var toks: [Token] = []
        let chars = Array(s)
        let n = chars.count
        var i = 0
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." }
        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "|": toks.append(Token(kind: .pipe, text: "|", pos: i)); i += 1
            case "@": toks.append(Token(kind: .at, text: "@", pos: i)); i += 1
            case "=": toks.append(Token(kind: .eq, text: "=", pos: i)); i += 1
            case "~": toks.append(Token(kind: .tilde, text: "~", pos: i)); i += 1
            case ":": toks.append(Token(kind: .colon, text: ":", pos: i)); i += 1
            case "$": toks.append(Token(kind: .dollar, text: "$", pos: i)); i += 1
            case "*": toks.append(Token(kind: .star, text: "*", pos: i)); i += 1
            case "(": toks.append(Token(kind: .lparen, text: "(", pos: i)); i += 1
            case ")": toks.append(Token(kind: .rparen, text: ")", pos: i)); i += 1
            case "\"":
                let start = i; i += 1
                var str = ""
                while i < n, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < n { str.append(chars[i + 1]); i += 2 }
                    else { str.append(chars[i]); i += 1 }
                }
                if i < n { i += 1 }   // closing quote (unterminated → take the rest, lenient)
                toks.append(Token(kind: .string, text: str, pos: start))
            default:
                if isIdent(c) {
                    let start = i
                    var id = ""
                    while i < n, isIdent(chars[i]) { id.append(chars[i]); i += 1 }
                    toks.append(Token(kind: .ident, text: id, pos: start))
                } else {
                    // Unknown punctuation — skip it (lenient), don't trap.
                    i += 1
                }
            }
        }
        return toks
    }

    // MARK: - Parser

    private static func parseQuery(_ toks: [Token], _ i: inout Int, end: Int) throws -> StructuralQuery {
        guard i < end else { throw ParseError("expected a node kind", at: toks.last?.pos ?? 0) }

        // kindSpec
        var kinds: Set<String> = []
        if toks[i].kind == .star {
            i += 1   // wildcard — empty kinds
        } else if toks[i].kind == .ident {
            kinds.insert(toks[i].text); i += 1
            while i < end, toks[i].kind == .pipe {
                i += 1
                guard i < end, toks[i].kind == .ident else {
                    throw ParseError("expected a node kind after '|'", at: i < end ? toks[i].pos : 0)
                }
                kinds.insert(toks[i].text); i += 1
            }
        } else {
            throw ParseError("expected a node kind or '*'", at: toks[i].pos)
        }

        // capture
        var captureAs: String?
        if i < end, toks[i].kind == .at {
            i += 1
            guard i < end, toks[i].kind == .ident else {
                throw ParseError("expected a name after '@'", at: i < end ? toks[i].pos : 0)
            }
            captureAs = toks[i].text; i += 1
        }

        // terms
        var fields: [StructuralFieldConstraint] = []
        var children: [StructuralQuery] = []
        while i < end {
            switch toks[i].kind {
            case .lparen:
                i += 1
                let child = try parseQuery(toks, &i, end: end)
                guard i < end, toks[i].kind == .rparen else {
                    throw ParseError("expected ')'", at: i < end ? toks[i].pos : 0)
                }
                i += 1
                children.append(child)
            case .ident:
                fields.append(try parseField(toks, &i, end: end))
            case .rparen:
                return StructuralQuery(kinds: kinds, fieldConstraints: fields,
                                       childPatterns: children, captureAs: captureAs)
            default:
                throw ParseError("unexpected '\(toks[i].text)'", at: toks[i].pos)
            }
        }
        return StructuralQuery(kinds: kinds, fieldConstraints: fields,
                               childPatterns: children, captureAs: captureAs)
    }

    private static func parseField(_ toks: [Token], _ i: inout Int, end: Int) throws -> StructuralFieldConstraint {
        let field = toks[i].text; i += 1
        guard i < end else { throw ParseError("expected '=', '~', or ':' after field '\(field)'", at: toks[i - 1].pos) }
        let op = toks[i]
        switch op.kind {
        case .eq:
            i += 1
            if i < end, toks[i].kind == .dollar {
                i += 1
                guard i < end, toks[i].kind == .ident else {
                    throw ParseError("expected a capture name after '$'", at: i < end ? toks[i].pos : op.pos)
                }
                let name = toks[i].text; i += 1
                return .capture(field, as: name)
            }
            return .equals(field, try value(toks, &i, end: end, op: op))
        case .tilde:
            i += 1
            return .contains(field, try value(toks, &i, end: end, op: op))
        case .colon:
            i += 1
            guard i < end, toks[i].kind == .ident else {
                throw ParseError("expected a node kind after ':'", at: i < end ? toks[i].pos : op.pos)
            }
            let kind = toks[i].text; i += 1
            return .kind(field, is: kind)
        default:
            throw ParseError("expected '=', '~', or ':' after field '\(field)'", at: op.pos)
        }
    }

    private static func value(_ toks: [Token], _ i: inout Int, end: Int, op: Token) throws -> String {
        guard i < end, toks[i].kind == .string || toks[i].kind == .ident else {
            throw ParseError("expected a value after '\(op.text)'", at: i < end ? toks[i].pos : op.pos)
        }
        let v = toks[i].text; i += 1
        return v
    }
}
