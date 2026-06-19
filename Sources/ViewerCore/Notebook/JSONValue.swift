import Foundation

/// An order-preserving JSON value model.
///
/// `Foundation.JSONSerialization` deserializes objects into unordered
/// `NSDictionary`, so it cannot round-trip a `.ipynb` while preserving the
/// on-disk key order — and Jupyter's nbformat writer emits a *stable*,
/// alphabetically-keyed shape that tooling is expected to reproduce. To make
/// notebook editing safe (open → edit one cell → save → re-open yields the
/// same bytes for everything we did NOT touch), we need to retain unrecognized
/// fields (`kernelspec`, `language_info`, arbitrary `metadata`, code-cell
/// `outputs`, `execution_count`, …) *with their structure intact*.
///
/// `JSONValue` is that retention layer: a recursive value that keeps object
/// member order, and serializes deterministically. It is pure + host-testable
/// and uses only Foundation primitives (no project engine, migration-safe).
///
/// Number handling: JSON numbers are kept as their original text token
/// (`.number(raw:)`) so that integers stay integers, `1.0` stays `1.0`, and we
/// never reformat a value we did not edit. We parse via `JSONSerialization`
/// only to *validate* and to recover string/bool/null leaves; the number raw
/// text is recovered from a single-pass tokenizer so formatting is preserved.
public indirect enum JSONValue: Equatable, Sendable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    /// A numeric literal, retained as its original source token (e.g. "1",
    /// "1.0", "1e10", "-0") so serialization never reformats it.
    case number(raw: String)
    case bool(Bool)
    case null

    // MARK: Equatable (object member order is significant)

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(l), .object(r)):
            guard l.count == r.count else { return false }
            for (a, b) in zip(l, r) where a.0 != b.0 || a.1 != b.1 { return false }
            return true
        case let (.array(l), .array(r)): return l == r
        case let (.string(l), .string(r)): return l == r
        case let (.number(l), .number(r)): return l == r
        case let (.bool(l), .bool(r)): return l == r
        case (.null, .null): return true
        default: return false
        }
    }

    // MARK: Convenience accessors

    public var objectMembers: [(String, JSONValue)]? {
        if case let .object(members) = self { return members }
        return nil
    }

    public var arrayElements: [JSONValue]? {
        if case let .array(elements) = self { return elements }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Look up an object member by key (first match), or nil if not an object
    /// / key absent.
    public subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(members) = self else { return nil }
            return members.first(where: { $0.0 == key })?.1
        }
        set {
            guard case var .object(members) = self else { return }
            if let index = members.firstIndex(where: { $0.0 == key }) {
                if let newValue { members[index].1 = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append((key, newValue))
            }
            self = .object(members)
        }
    }
}

// MARK: - Parsing

public extension JSONValue {
    enum ParseError: Error, Equatable {
        case invalidJSON
        case unexpectedEnd
        case unexpectedCharacter(Int)
    }

    /// Parse JSON text into an order-preserving `JSONValue`. Throws on malformed
    /// input. This is a single-pass recursive-descent parser (RFC 8259) — we
    /// roll our own rather than use `JSONSerialization` because the latter
    /// discards object key order and reformats numbers, both of which we must
    /// preserve for byte-stable notebook round-trips.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError.unexpectedCharacter(parser.index) }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var isAtEnd: Bool { index >= scalars.count }
        var current: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

        mutating func skipWhitespace() {
            while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" {
                index += 1
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard let c = current else { throw ParseError.unexpectedEnd }
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t", "f": return .bool(try parseBool())
            case "n": try parseNull(); return .null
            case "-", "0"..."9": return .number(raw: try parseNumber())
            default: throw ParseError.unexpectedCharacter(index)
            }
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1 // consume '{'
            var members: [(String, JSONValue)] = []
            skipWhitespace()
            if current == "}" { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard current == "\"" else { throw ParseError.unexpectedCharacter(index) }
                let key = try parseString()
                skipWhitespace()
                guard current == ":" else { throw ParseError.unexpectedCharacter(index) }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                members.append((key, value))
                skipWhitespace()
                switch current {
                case ",": index += 1
                case "}": index += 1; return .object(members)
                default: throw ParseError.unexpectedCharacter(index)
                }
            }
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1 // consume '['
            var elements: [JSONValue] = []
            skipWhitespace()
            if current == "]" { index += 1; return .array(elements) }
            while true {
                skipWhitespace()
                elements.append(try parseValue())
                skipWhitespace()
                switch current {
                case ",": index += 1
                case "]": index += 1; return .array(elements)
                default: throw ParseError.unexpectedCharacter(index)
                }
            }
        }

        mutating func parseString() throws -> String {
            index += 1 // consume opening quote
            var result = String.UnicodeScalarView()
            while let c = current {
                index += 1
                if c == "\"" { return String(result) }
                if c == "\\" {
                    guard let esc = current else { throw ParseError.unexpectedEnd }
                    index += 1
                    switch esc {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append(Unicode.Scalar(0x08))
                    case "f": result.append(Unicode.Scalar(0x0C))
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u": result.append(try parseUnicodeEscape())
                    default: throw ParseError.unexpectedCharacter(index)
                    }
                } else {
                    result.append(c)
                }
            }
            throw ParseError.unexpectedEnd
        }

        /// Parse a `\uXXXX` escape (the leading `\u` is already consumed),
        /// combining a high+low surrogate pair into one scalar.
        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let high = try parseHex4()
            if high >= 0xD800 && high <= 0xDBFF {
                // Expect a following \uXXXX low surrogate.
                guard current == "\\" else { throw ParseError.unexpectedCharacter(index) }
                index += 1
                guard current == "u" else { throw ParseError.unexpectedCharacter(index) }
                index += 1
                let low = try parseHex4()
                guard low >= 0xDC00 && low <= 0xDFFF else { throw ParseError.unexpectedCharacter(index) }
                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw ParseError.invalidJSON }
                return scalar
            }
            guard let scalar = Unicode.Scalar(high) else { throw ParseError.invalidJSON }
            return scalar
        }

        mutating func parseHex4() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard let c = current, let digit = JSONValue.hexValue(c) else {
                    throw ParseError.unexpectedCharacter(index)
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws -> String {
            let start = index
            if current == "-" { index += 1 }
            while let c = current, ("0"..."9").contains(c) { index += 1 }
            if current == "." {
                index += 1
                while let c = current, ("0"..."9").contains(c) { index += 1 }
            }
            if current == "e" || current == "E" {
                index += 1
                if current == "+" || current == "-" { index += 1 }
                while let c = current, ("0"..."9").contains(c) { index += 1 }
            }
            guard index > start else { throw ParseError.unexpectedCharacter(index) }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }

        mutating func parseBool() throws -> Bool {
            if matches("true") { return true }
            if matches("false") { return false }
            throw ParseError.unexpectedCharacter(index)
        }

        mutating func parseNull() throws {
            guard matches("null") else { throw ParseError.unexpectedCharacter(index) }
        }

        mutating func matches(_ literal: String) -> Bool {
            let lit = Array(literal.unicodeScalars)
            guard index + lit.count <= scalars.count else { return false }
            for (offset, scalar) in lit.enumerated() where scalars[index + offset] != scalar {
                return false
            }
            index += lit.count
            return true
        }
    }
}

// MARK: - Serialization

public extension JSONValue {
    /// Serialize back to JSON text.
    ///
    /// Format matches Jupyter's nbformat writer conventions closely enough for
    /// a stable round-trip: 1-space indent per level, `": "` after object keys,
    /// `","` separators, no trailing newline (callers add the notebook's
    /// trailing newline). The exact indentation is configurable via `indent`.
    func serialized(indent: Int = 1) -> String {
        var output = ""
        write(into: &output, depth: 0, indent: indent)
        return output
    }

    private func write(into output: inout String, depth: Int, indent: Int) {
        switch self {
        case let .object(members):
            if members.isEmpty { output += "{}"; return }
            output += "{\n"
            let pad = String(repeating: " ", count: indent * (depth + 1))
            for (offset, member) in members.enumerated() {
                output += pad
                output += JSONValue.encodeString(member.0)
                output += ": "
                member.1.write(into: &output, depth: depth + 1, indent: indent)
                if offset < members.count - 1 { output += "," }
                output += "\n"
            }
            output += String(repeating: " ", count: indent * depth)
            output += "}"
        case let .array(elements):
            if elements.isEmpty { output += "[]"; return }
            output += "[\n"
            let pad = String(repeating: " ", count: indent * (depth + 1))
            for (offset, element) in elements.enumerated() {
                output += pad
                element.write(into: &output, depth: depth + 1, indent: indent)
                if offset < elements.count - 1 { output += "," }
                output += "\n"
            }
            output += String(repeating: " ", count: indent * depth)
            output += "]"
        case let .string(value):
            output += JSONValue.encodeString(value)
        case let .number(raw):
            output += raw
        case let .bool(value):
            output += value ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    /// JSON-escape and quote a string per RFC 8259. Only the mandatory escapes
    /// (`"`, `\`, control chars < 0x20) are emitted; printable Unicode is left
    /// as-is, matching Jupyter's `ensure_ascii=False` writer default.
    /// Hex digit value of a scalar (0-9, a-f, A-F), or nil. `Unicode.Scalar`
    /// has no `hexDigitValue` (that's on `Character`), so we compute it.
    static func hexValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value - 0x30)
        case "a"..."f": return Int(scalar.value - 0x61 + 10)
        case "A"..."F": return Int(scalar.value - 0x41 + 10)
        default: return nil
        }
    }

    static func encodeString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case Unicode.Scalar(0x08): result += "\\b"
            case Unicode.Scalar(0x0C): result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
