import AppKit
import Foundation

/// VS Code theme import (TSK-642) — parses a VS Code color-theme JSON into
/// the TSK-641 `ThemeDefinition` contract: the cheapest ecosystem win
/// (thousands of published themes become usable directly).
///
/// Format notes that matter:
///   • Theme files are JSONC: `//` and `/* */` comments plus trailing
///     commas are LEGAL. A string-aware stripper runs before
///     JSONSerialization (comment-looking text inside string literals
///     must survive).
///   • `tokenColors[].scope` is a TextMate scope (string OR array; VS Code
///     also tolerates comma-separated strings). Mapping to our coarse
///     `TokenKind` set uses a longest-prefix specificity table — per kind
///     the MOST SPECIFIC matching scope wins, which coarsely mirrors
///     VS Code's own specificity semantics.
///   • `type` ("dark"/"light") may be absent — fall back to background
///     luminance.
public enum VSCodeThemeImporter {

    public enum ImportError: Error, Equatable {
        case notJSON(String)
        case missingEditorColors
    }

    /// Parse VS Code theme JSON(C) into a definition. `fallbackName` seeds
    /// the display name when the file has no `name` field (use the
    /// filename stem).
    public static func parse(_ data: Data, fallbackName: String) throws -> ThemeDefinition {
        let stripped = stripJSONC(String(decoding: data, as: UTF8.self))
        guard let obj = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
            throw ImportError.notJSON("not a JSON object after JSONC stripping")
        }
        let colors = obj["colors"] as? [String: Any] ?? [:]
        guard let background = colors["editor.background"] as? String,
              let foreground = colors["editor.foreground"] as? String else {
            throw ImportError.missingEditorColors
        }

        let name = (obj["name"] as? String) ?? fallbackName
        let isDark: Bool
        if let type = obj["type"] as? String {
            isDark = type.lowercased() == "dark"
        } else {
            isDark = (ThemeColor.parse(background)?.luminance ?? 1) < 0.5
        }

        var tokens: [String: String] = [:]
        var specificity: [String: Int] = [:]   // TokenKind.rawValue → matched-scope length
        for entry in (obj["tokenColors"] as? [[String: Any]]) ?? [] {
            guard let settings = entry["settings"] as? [String: Any],
                  let fg = settings["foreground"] as? String else { continue }
            for scope in scopes(of: entry["scope"]) {
                for (kind, matchedLen) in kinds(forScope: scope) {
                    if matchedLen > (specificity[kind.rawValue] ?? -1) {
                        specificity[kind.rawValue] = matchedLen
                        tokens[kind.rawValue] = fg
                    }
                }
            }
        }

        return ThemeDefinition(
            id: slug(name),
            displayName: name,
            isDark: isDark,
            background: background,
            foreground: foreground,
            gutterText: (colors["editorLineNumber.foreground"] as? String) ?? foreground,
            gutterBackground: (colors["editorGutter.background"] as? String) ?? background,
            tokens: tokens,
            accent: colors["focusBorder"] as? String,
            selectionBackground: colors["editor.selectionBackground"] as? String
        )
    }

    /// Import a theme file and install it into `store`.
    @discardableResult
    public static func importFile(at url: URL, into store: ThemeStore = .shared) throws -> ThemeDefinition {
        let data = try Data(contentsOf: url)
        let def = try parse(data, fallbackName: url.deletingPathExtension().lastPathComponent)
        try store.saveUserTheme(def)
        return def
    }

    // MARK: scope mapping

    /// TextMate scope prefix → TokenKind. Longest-prefix wins per kind.
    /// Order here is irrelevant (specificity decides); keep prefixes
    /// SPECIFIC-FIRST only for readability.
    static let scopeTable: [(prefix: String, kind: TokenKind)] = [
        ("constant.character.escape", .escape),
        ("constant.numeric", .number),
        ("constant", .constant),
        ("entity.name.function", .function),
        ("entity.name.type", .type),
        ("entity.name.tag", .tag),
        ("entity.other.attribute-name", .tagAttribute),
        ("keyword.operator", .operator),
        ("keyword", .keyword),
        ("storage.type", .keyword),
        ("storage", .keyword),
        ("string.regexp", .regex),
        ("string", .string),
        ("comment", .comment),
        ("variable", .variable),
        ("support.function", .function),
        ("support.type", .type),
        ("support", .builtin),
        ("punctuation", .punctuation),
        ("markup.heading", .heading),
        ("markup.italic", .emphasis),
        ("markup.bold", .strong),
        ("markup.underline.link", .link),
        ("meta.attribute", .attribute),
    ]

    /// All kinds a scope matches, with the matched prefix length (the
    /// specificity). `keyword.control.flow` matches ("keyword", 7).
    static func kinds(forScope scope: String) -> [(TokenKind, Int)] {
        var best: [TokenKind: Int] = [:]
        for (prefix, kind) in scopeTable {
            guard scope == prefix || scope.hasPrefix(prefix + ".") else { continue }
            if prefix.count > (best[kind] ?? -1) {
                best[kind] = prefix.count
            }
        }
        return best.map { ($0.key, $0.value) }
    }

    /// `scope` may be a string, an array, or a comma-separated string.
    static func scopes(of raw: Any?) -> [String] {
        if let s = raw as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let arr = raw as? [String] {
            return arr.flatMap { scopes(of: $0) }
        }
        return []
    }

    // MARK: JSONC stripping (string-aware)

    /// Remove `//`/`/* */` comments and trailing commas WITHOUT touching
    /// string-literal contents. Single pass, quote-state machine.
    static func stripJSONC(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
                i += 1
            case "/" where i + 1 < chars.count && chars[i + 1] == "/":
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "/" where i + 1 < chars.count && chars[i + 1] == "*":
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
            default:
                out.append(c)
                i += 1
            }
        }
        // Trailing commas: `, }` / `, ]` (whitespace-tolerant).
        var result = String()
        result.reserveCapacity(out.count)
        chars = Array(out)
        i = 0
        inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if c == "\\", i + 1 < chars.count {
                    result.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1   // drop the comma; the closer is appended later
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "imported-theme" : out
    }
}

extension NSColor {
    /// Relative luminance (sRGB, rough) — drives dark/light inference.
    var luminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}
