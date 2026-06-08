import Foundation

/// The result of a JSON syntax check.
public enum JSONSyntaxResult: Equatable, Sendable {
    case valid
    /// First structural error: 1-based line and column, plus a human message.
    case invalid(line: Int, column: Int, message: String)
}

/// A pure, dependency-free RFC-8259 JSON *validator that reports the position*
/// of the first syntax error (TSK-513). Foundation's `JSONSerialization` only
/// says "the data couldn't be read" with no line/column; this lets the JSON
/// viewer point at exactly where invalid JSON breaks.
///
/// It validates structure (it does not build a value): objects, arrays,
/// strings (with `\"\\/bfnrt` and `\uXXXX` escapes; unescaped control chars
/// rejected), numbers (RFC grammar — no leading zeros, no bare `-`/`1.`/`1e`),
/// and the `true`/`false`/`null` literals, then requires EOF. Recursion is
/// depth-capped (the `pretty_json` / cmark unbounded-recursion lesson) so a
/// pathological `[[[…]]]` reports an error instead of overflowing the stack.
public enum JSONSyntaxChecker {

    public static let maxDepth = 512

    public static func check(_ text: String) -> JSONSyntaxResult {
        var p = Parser(scalars: Array(text.unicodeScalars))
        do {
            p.skipWhitespace()
            if p.atEnd { throw p.error("empty input — expected a JSON value") }
            try p.parseValue(depth: 0)
            p.skipWhitespace()
            if !p.atEnd { throw p.error("unexpected trailing content after the JSON value") }
            return .valid
        } catch let e as JSONParseError {
            return .invalid(line: e.line, column: e.column, message: e.message)
        } catch {
            return .invalid(line: 1, column: 1, message: "\(error)")
        }
    }
}

private struct JSONParseError: Error {
    let line: Int
    let column: Int
    let message: String
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var i = 0
    var line = 1
    var column = 1

    var atEnd: Bool { i >= scalars.count }
    var peek: Unicode.Scalar? { atEnd ? nil : scalars[i] }

    func error(_ message: String) -> JSONParseError {
        JSONParseError(line: line, column: column, message: message)
    }

    mutating func advance() -> Unicode.Scalar {
        let c = scalars[i]
        i += 1
        if c == "\n" { line += 1; column = 1 } else { column += 1 }
        return c
    }

    mutating func skipWhitespace() {
        while let c = peek, c == " " || c == "\t" || c == "\n" || c == "\r" { _ = advance() }
    }

    mutating func parseValue(depth: Int) throws {
        if depth > JSONSyntaxChecker.maxDepth {
            throw error("JSON nested too deeply (>\(JSONSyntaxChecker.maxDepth))")
        }
        guard let c = peek else { throw error("expected a JSON value but reached end of input") }
        switch c {
        case "{": try parseObject(depth: depth)
        case "[": try parseArray(depth: depth)
        case "\"": try parseString()
        case "t": try parseLiteral("true")
        case "f": try parseLiteral("false")
        case "n": try parseLiteral("null")
        case "-", "0"..."9": try parseNumber()
        default: throw error("unexpected character '\(c)' — expected a JSON value")
        }
    }

    mutating func parseObject(depth: Int) throws {
        _ = advance()   // consume '{'
        skipWhitespace()
        if peek == "}" { _ = advance(); return }
        while true {
            skipWhitespace()
            guard peek == "\"" else { throw error("expected a string key in object") }
            try parseString()
            skipWhitespace()
            guard peek == ":" else { throw error("expected ':' after object key") }
            _ = advance()
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            switch peek {
            case ",": _ = advance()      // continue to next pair
            case "}": _ = advance(); return
            default:  throw error("expected ',' or '}' in object")
            }
        }
    }

    mutating func parseArray(depth: Int) throws {
        _ = advance()   // consume '['
        skipWhitespace()
        if peek == "]" { _ = advance(); return }
        while true {
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            switch peek {
            case ",": _ = advance()      // continue to next element
            case "]": _ = advance(); return
            default:  throw error("expected ',' or ']' in array")
            }
        }
    }

    mutating func parseString() throws {
        _ = advance()   // consume opening '"'
        while true {
            guard let c = peek else { throw error("unterminated string (reached end of input)") }
            if c == "\"" { _ = advance(); return }
            if c == "\\" {
                _ = advance()
                guard let esc = peek else { throw error("unterminated escape in string") }
                switch esc {
                case "\"", "\\", "/", "b", "f", "n", "r", "t": _ = advance()
                case "u":
                    _ = advance()
                    for _ in 0..<4 {
                        guard let h = peek, isHexDigit(h) else {
                            throw error("\\u escape needs 4 hex digits")
                        }
                        _ = advance()
                    }
                default:
                    throw error("invalid string escape '\\\(esc)'")
                }
            } else if c.value < 0x20 {
                throw error("unescaped control character in string (0x\(String(c.value, radix: 16)))")
            } else {
                _ = advance()
            }
        }
    }

    mutating func parseNumber() throws {
        if peek == "-" { _ = advance() }
        // int part: '0' alone, or [1-9][0-9]*
        guard let d = peek, d >= "0" && d <= "9" else {
            throw error("invalid number — expected a digit")
        }
        if d == "0" {
            _ = advance()
            if let n = peek, n >= "0" && n <= "9" {
                throw error("invalid number — leading zeros are not allowed")
            }
        } else {
            while let n = peek, n >= "0" && n <= "9" { _ = advance() }
        }
        // optional fraction
        if peek == "." {
            _ = advance()
            guard let f = peek, f >= "0" && f <= "9" else {
                throw error("invalid number — a fraction needs at least one digit")
            }
            while let n = peek, n >= "0" && n <= "9" { _ = advance() }
        }
        // optional exponent
        if let e = peek, e == "e" || e == "E" {
            _ = advance()
            if let s = peek, s == "+" || s == "-" { _ = advance() }
            guard let x = peek, x >= "0" && x <= "9" else {
                throw error("invalid number — an exponent needs at least one digit")
            }
            while let n = peek, n >= "0" && n <= "9" { _ = advance() }
        }
    }

    mutating func parseLiteral(_ word: String) throws {
        for expected in word.unicodeScalars {
            guard let c = peek, c == expected else {
                throw error("invalid literal — expected '\(word)'")
            }
            _ = advance()
        }
    }

    private func isHexDigit(_ c: Unicode.Scalar) -> Bool {
        (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }
}
