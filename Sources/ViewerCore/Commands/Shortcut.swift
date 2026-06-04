import Foundation

/// Keyboard modifier flags for a `Shortcut`. An `OptionSet` so a binding
/// can carry any combination (`⌘⇧`, `⌥⌘`, …) in a single value.
///
/// **FFI-shaped by intent:** backed by `UInt8`, value-typed, `Sendable`.
/// The raw bits are NOT a wire contract today (config is parsed from
/// human strings, never serialised numerically), but keeping it a plain
/// bitset means the eventual Rust core can mirror it as a `u8` without a
/// translation table.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    /// Canonical token order used when rendering back to a string, so a
    /// round-trip (`parse` → `displayString`) is stable regardless of the
    /// order the user typed the tokens in.
    private static let renderOrder: [(KeyModifiers, String)] = [
        (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
    ]

    /// Lowercase canonical token order for stable equality / rendering.
    fileprivate func tokens() -> [String] {
        Self.renderOrder.compactMap { contains($0.0) ? $0.1 : nil }
    }
}

/// A parsed keyboard shortcut: a base key plus zero or more modifiers.
///
/// The `key` is normalised to a single lowercased character for ordinary
/// letters/digits/punctuation, or a lowercase symbolic name for special
/// keys (`"left"`, `"right"`, `"up"`, `"down"`, `"tab"`, `"space"`,
/// `"escape"`, `"return"`, `"delete"`, `"backslash"`). This mirrors the
/// `keyEquivalent` strings AppKit's `NSMenuItem` consumes (the menu
/// builder maps the symbolic names onto the AppKit unicode constants).
///
/// Pure value type — no AppKit. The UI layer translates a `Shortcut`
/// into `(NSMenuItem.keyEquivalent, NSEvent.ModifierFlags)` at the
/// boundary; this type stays headless-testable.
public struct Shortcut: Sendable, Hashable {
    public let key: String
    public let modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Symbolic key-name aliases the parser accepts (case-insensitive).
    /// Anything not in this table is treated as a literal single
    /// character (lowercased).
    private static let symbolicKeys: Set<String> = [
        "left", "right", "up", "down",
        "tab", "space", "escape", "esc", "return", "enter",
        "delete", "backspace", "backslash", "home", "end",
        "pageup", "pagedown",
    ]

    /// Modifier token aliases → `KeyModifiers`. Accepts the common
    /// spellings so a user editing the JSON by hand doesn't trip over
    /// `cmd` vs `command` vs `meta`.
    private static let modifierAliases: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "meta": .command, "super": .command,
        "shift": .shift,
        "alt": .option, "opt": .option, "option": .option,
        "ctrl": .control, "control": .control,
    ]

    /// Parse a `"cmd+shift+f"`-style string. Tokens are split on `+`,
    /// trimmed, and lowercased; everything but the LAST token must be a
    /// modifier alias, and the last token is the base key.
    ///
    /// Returns `nil` (rather than throwing) for malformed input — an
    /// unknown modifier, an empty string, a missing base key, or a
    /// multi-character base key that isn't a known symbolic name. Callers
    /// log + ignore a `nil` so one bad line never aborts the whole config
    /// load. A literal `"+"` key is supported via a trailing empty token
    /// (`"cmd++"`), which is why we split keeping empties and special-case
    /// the trailing-plus shape.
    public static func parse(_ raw: String) -> Shortcut? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split on '+' but keep empty tokens so "cmd++" → ["cmd","",""]
        // can be recognised as the literal '+' key with the Command
        // modifier (the final empty pair encodes the '+').
        var tokens = trimmed.lowercased().split(
            separator: "+", omittingEmptySubsequences: false
        ).map(String.init)

        // Trailing literal '+': a pair of trailing empties means the base
        // key is "+". Collapse them back to a single "+" token.
        if tokens.count >= 2, tokens.last == "", tokens[tokens.count - 2] == "" {
            tokens.removeLast(2)
            tokens.append("+")
        }

        guard let keyToken = tokens.popLast() else { return nil }

        var mods: KeyModifiers = []
        for token in tokens {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let mod = modifierAliases[t] else { return nil }
            mods.insert(mod)
        }

        let key = keyToken.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        // Base key: either a known symbolic name, a single literal
        // character, or the literal "+". Multi-character non-symbolic
        // tokens are rejected.
        let normalisedKey: String
        if symbolicKeys.contains(key) {
            normalisedKey = canonicalSymbol(key)
        } else if key.count == 1 {
            normalisedKey = key
        } else {
            return nil
        }
        return Shortcut(key: normalisedKey, modifiers: mods)
    }

    /// Fold accepted spelling variants of a symbolic key onto one
    /// canonical name so two configs that spell the same key differently
    /// still compare equal.
    private static func canonicalSymbol(_ s: String) -> String {
        switch s {
        case "esc": return "escape"
        case "enter": return "return"
        case "backspace": return "delete"
        default: return s
        }
    }

    /// Render back to the canonical `"cmd+shift+f"` form. Stable token
    /// order (ctrl, alt, shift, cmd) regardless of how it was parsed.
    public var displayString: String {
        (modifiers.tokens() + [key]).joined(separator: "+")
    }
}
