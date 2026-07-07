//! Semantic color tokens shared by the front-ends (TSK-243).
//!
//! The core owns the palette *values* per [`Mode`]; each front-end maps an
//! [`Rgb`] to its own color type (ratatui `Color::Rgb` for the TUI, CSS for
//! the web front-end). The core has no front-end dependency — it only answers
//! "what RGB is role X in mode Y", keeping the one-core/three-front-ends
//! contract (see docs/FEATURE_PORT_PLAN_2026-06-04.md: "colors live per
//! front-end via `core::theme`").
//!
//! Panic-free by construction (the rust-core gate denies panics): palettes are
//! `Rgb` literals, and [`parse_hex`] returns `Option` rather than unwrapping.

/// A 24-bit color. Front-ends map this onto their native color type.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Rgb {
    /// Red channel.
    pub r: u8,
    /// Green channel.
    pub g: u8,
    /// Blue channel.
    pub b: u8,
}

impl Rgb {
    /// Construct from the three channels.
    #[must_use]
    pub const fn new(r: u8, g: u8, b: u8) -> Self {
        Rgb { r, g, b }
    }
}

/// A 24-bit color with an 8-bit alpha channel — the full result of parsing a
/// theme/CSS hex string that may carry transparency (`#rrggbbaa`). The opaque
/// [`parse_hex`] discards the alpha; [`parse_rgba`] preserves it for front-ends
/// that need the channel (theme imports, CSS color tokens).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Rgba {
    /// Red channel.
    pub r: u8,
    /// Green channel.
    pub g: u8,
    /// Blue channel.
    pub b: u8,
    /// 0 = fully transparent, 255 = fully opaque.
    pub a: u8,
}

impl Rgba {
    /// Construct from the four channels.
    #[must_use]
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Rgba { r, g, b, a }
    }

    /// Drop the alpha channel, keeping the RGB triple.
    #[must_use]
    pub const fn rgb(self) -> Rgb {
        Rgb { r: self.r, g: self.g, b: self.b }
    }
}

/// Which palette a front-end is painting with. `Light`/`Dark` are explicit,
/// terminal-theme-independent looks (the TUI also has an "adaptive" mode that
/// bypasses the palette and uses the terminal's own ANSI theme — that lives in
/// the front-end, not here).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// Light appearance.
    Light,
    /// Dark appearance.
    Dark,
}

/// The semantic painting roles a front-end needs. Kept stable so the palette
/// is a fixed contract rather than a grab-bag of raw colors — every color a
/// front-end paints with should resolve to a role here, not a local literal.
///
/// The original ten roles (TSK-243) served the TUI; the web front-end painted
/// ~30 more colors as inline-CSS literals. TSK-573 folded those web-needed
/// concepts in so all front-ends share one contract: the UI-chrome group
/// (`Link`/`Text`/`Background`/`Surface`/`Success`/`Warning`/`Gutter`/`Border`)
/// and the syntax-highlight group (`Syn*`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    /// Primary accent — headers, directory entries, the app badge background.
    Accent,
    /// Secondary heading / hunk-header emphasis.
    Header,
    /// De-emphasized chrome — help text, gutters, separators.
    Muted,
    /// Background of a non-current search/find hit.
    HighlightBg,
    /// Background of the CURRENT search/find hit (distinct from `HighlightBg`).
    CurrentBg,
    /// Foreground drawn ON an accent/highlight fill (must contrast both).
    OnHighlight,
    /// Diff added line.
    Added,
    /// Diff removed line.
    Removed,
    /// Diff hunk marker.
    Hunk,
    /// Diff context line (unchanged).
    Context,

    // --- UI chrome (TSK-573, web front-end) ---
    /// Hyperlink / interactive text (nav entries, breadcrumbs, buttons-as-links).
    Link,
    /// Primary body text.
    Text,
    /// Page background.
    Background,
    /// Panel / nav / card surface (one step off the background).
    Surface,
    /// Positive status — git-clean, directory entries.
    Success,
    /// Caution status — git-dirty, warning banners.
    Warning,
    /// Line-number gutter text.
    Gutter,
    /// Hairline borders / separators.
    Border,

    // --- Syntax highlighting (TSK-573, web front-end) ---
    /// Keyword token.
    SynKeyword,
    /// String literal token.
    SynString,
    /// Numeric literal token.
    SynNumber,
    /// Comment token.
    SynComment,
    /// Function-name token.
    SynFunction,
    /// Type-name token.
    SynType,
    /// Attribute / annotation token.
    SynAttribute,
}

/// A resolved palette for one [`Mode`]. Cheap to copy; `color` is a pure lookup.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Palette {
    mode: Mode,
}

impl Palette {
    /// The palette for `mode`.
    #[must_use] 
    pub const fn for_mode(mode: Mode) -> Self {
        Palette { mode }
    }

    /// The theme's light/dark mode.
    #[must_use] 
    pub const fn mode(&self) -> Mode {
        self.mode
    }

    /// The RGB for `role` in this palette's mode. Values are One Dark / One
    /// Light derived — distinct per role and per mode so a front-end mapping
    /// and a pixel test can both tell them apart.
    #[must_use] 
    pub const fn color(&self, role: Role) -> Rgb {
        match self.mode {
            Mode::Dark => match role {
                Role::Accent => Rgb::new(0x56, 0xb6, 0xc2),
                Role::Header => Rgb::new(0x61, 0xaf, 0xef),
                Role::Muted => Rgb::new(0x5c, 0x63, 0x70),
                Role::HighlightBg => Rgb::new(0xe5, 0xc0, 0x7b),
                Role::CurrentBg => Rgb::new(0xc6, 0x78, 0xdd),
                Role::OnHighlight => Rgb::new(0x28, 0x2c, 0x34),
                // Diff line FOREGROUNDS — the web's tuned diff palette, now the
                // shared contract value (TSK-573). The TUI consumes the same.
                Role::Added => Rgb::new(0x7e, 0xe2, 0xa8),
                Role::Removed => Rgb::new(0xff, 0x9a, 0xa2),
                Role::Hunk => Rgb::new(0xc8, 0xa6, 0xff),
                Role::Context => Rgb::new(0xbb, 0xbb, 0xbb),
                // UI chrome (web front-end).
                Role::Link => Rgb::new(0x5a, 0x9c, 0xf5),
                Role::Text => Rgb::new(0xdd, 0xdd, 0xdd),
                Role::Background => Rgb::new(0x1e, 0x1e, 0x1e),
                Role::Surface => Rgb::new(0x25, 0x25, 0x26),
                Role::Success => Rgb::new(0x7e, 0xe7, 0x87),
                Role::Warning => Rgb::new(0xe3, 0xb3, 0x41),
                Role::Gutter => Rgb::new(0x77, 0x77, 0x77),
                Role::Border => Rgb::new(0x3a, 0x3a, 0x3a),
                // Syntax highlighting (web front-end). One Dark derived.
                Role::SynKeyword => Rgb::new(0xc6, 0x78, 0xdd),
                Role::SynString => Rgb::new(0x98, 0xc3, 0x79),
                Role::SynNumber => Rgb::new(0xd1, 0x9a, 0x66),
                Role::SynComment => Rgb::new(0x7f, 0x84, 0x8e),
                Role::SynFunction => Rgb::new(0x61, 0xaf, 0xef),
                Role::SynType => Rgb::new(0xe5, 0xc0, 0x7b),
                Role::SynAttribute => Rgb::new(0x56, 0xb6, 0xc2),
            },
            Mode::Light => match role {
                Role::Accent => Rgb::new(0x01, 0x84, 0xbc),
                Role::Header => Rgb::new(0x40, 0x78, 0xf2),
                Role::Muted => Rgb::new(0xa0, 0xa1, 0xa7),
                Role::HighlightBg => Rgb::new(0xc1, 0x84, 0x01),
                Role::CurrentBg => Rgb::new(0xa6, 0x26, 0xa4),
                Role::OnHighlight => Rgb::new(0xfa, 0xfa, 0xfa),
                // Diff line FOREGROUNDS — the web's tuned diff palette (TSK-573).
                Role::Added => Rgb::new(0x0a, 0x7d, 0x28),
                Role::Removed => Rgb::new(0xc0, 0x1c, 0x28),
                Role::Hunk => Rgb::new(0x7a, 0x3f, 0xb4),
                Role::Context => Rgb::new(0x44, 0x44, 0x44),
                // UI chrome (web front-end).
                Role::Link => Rgb::new(0x1a, 0x5f, 0xb4),
                Role::Text => Rgb::new(0x22, 0x22, 0x22),
                Role::Background => Rgb::new(0xff, 0xff, 0xff),
                Role::Surface => Rgb::new(0xfa, 0xfa, 0xfa),
                Role::Success => Rgb::new(0x1a, 0x7f, 0x37),
                Role::Warning => Rgb::new(0x8a, 0x6d, 0x00),
                Role::Gutter => Rgb::new(0x99, 0x99, 0x99),
                Role::Border => Rgb::new(0xdd, 0xdd, 0xdd),
                // Syntax highlighting (web front-end). One Light derived.
                Role::SynKeyword => Rgb::new(0xa6, 0x26, 0xa4),
                Role::SynString => Rgb::new(0x50, 0xa1, 0x4f),
                Role::SynNumber => Rgb::new(0xb7, 0x6b, 0x01),
                Role::SynComment => Rgb::new(0xa0, 0xa1, 0xa7),
                Role::SynFunction => Rgb::new(0x40, 0x78, 0xf2),
                Role::SynType => Rgb::new(0xc1, 0x84, 0x01),
                Role::SynAttribute => Rgb::new(0x01, 0x84, 0xbc),
            },
        }
    }
}

/// Parse a hex color in any of the CSS / theme forms the macOS host's Swift
/// `ThemeColor.parse` accepts — `#rgb`, `#rrggbb`, `#rrggbbaa` — case-
/// insensitive, leading `#` optional, surrounding ASCII whitespace trimmed.
/// The alpha channel is **discarded** (the opaque RGB triple); use
/// [`parse_rgba`] when transparency matters. Returns `None` for any malformed
/// input (wrong length, non-hex digits, empty) — never panics.
///
/// TSK-379 (Rust-core migration parity slice): the previous implementation
/// accepted ONLY the 6-digit form, so a VS Code theme / CSS token using the
/// `#abc` shorthand or an `#rrggbbaa` alpha color parsed in the Swift host yet
/// returned `None` here — a Swift↔Rust parity gap in the shared color contract.
/// This brings the Rust twin to parity (oracle: `ViewerCore.ThemeColor.parse`).
#[must_use]
pub fn parse_hex(s: &str) -> Option<Rgb> {
    parse_rgba(s).map(Rgba::rgb)
}

/// Parse a hex color, preserving the alpha channel. Matches Swift's
/// `ThemeColor.parse` accept/reject set exactly:
/// - leading/trailing ASCII whitespace is trimmed; a single leading `#` is
///   stripped; matching is case-insensitive;
/// - `rgb` (3 digits) → each nibble doubled (`#abc` == `#aabbcc`), alpha 255;
/// - `rrggbb` (6 digits) → alpha 255;
/// - `rrggbbaa` (8 digits) → explicit alpha;
/// - any other length, an empty body, or a non-hex digit → `None`.
///
/// Never panics (the no-panic gate denies indexing/unwrap): every byte access
/// goes through `get`/`from_str_radix` and the lengths are checked first.
#[must_use]
pub fn parse_rgba(s: &str) -> Option<Rgba> {
    // Swift trims `.whitespaces` (space + tab, not newlines); mirror that with
    // the ASCII space/tab set so interior or stray whitespace still rejects via
    // the hex-digit check below.
    let trimmed = s.trim_matches(|c| c == ' ' || c == '\t');
    let body = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if body.is_empty() || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    match body.len() {
        3 => {
            // `#abc` → `#aabbcc`: each single hex digit is the value's both nibbles.
            let r = nibble(body.as_bytes().first().copied()?)?;
            let g = nibble(body.as_bytes().get(1).copied()?)?;
            let b = nibble(body.as_bytes().get(2).copied()?)?;
            Some(Rgba::new(r * 17, g * 17, b * 17, 255))
        }
        6 => {
            let r = u8::from_str_radix(body.get(0..2)?, 16).ok()?;
            let g = u8::from_str_radix(body.get(2..4)?, 16).ok()?;
            let b = u8::from_str_radix(body.get(4..6)?, 16).ok()?;
            Some(Rgba::new(r, g, b, 255))
        }
        8 => {
            let r = u8::from_str_radix(body.get(0..2)?, 16).ok()?;
            let g = u8::from_str_radix(body.get(2..4)?, 16).ok()?;
            let b = u8::from_str_radix(body.get(4..6)?, 16).ok()?;
            let a = u8::from_str_radix(body.get(6..8)?, 16).ok()?;
            Some(Rgba::new(r, g, b, a))
        }
        _ => None,
    }
}

/// Map a single ASCII hex digit byte to its 0..=15 value. `None` for a non-hex
/// byte (the caller has already screened the whole body, so this is the
/// belt-and-braces no-panic path, not a hot check).
fn nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Format an [`Rgb`] as a CSS `#rrggbb` string (always 6 lowercase hex digits).
/// The inverse of [`parse_hex`] for the canonical 6-digit form — the web
/// front-end emits its palette CSS through this so every color traces back to a
/// [`Role`] rather than a literal (TSK-573). Round-trips:
/// `parse_hex(&css_hex(c)) == Some(c)`.
#[must_use]
pub fn css_hex(c: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_hex_accepts_valid_forms() {
        assert_eq!(parse_hex("#ffffff"), Some(Rgb::new(255, 255, 255)));
        assert_eq!(parse_hex("000000"), Some(Rgb::new(0, 0, 0)));
        assert_eq!(parse_hex("#56B6C2"), Some(Rgb::new(0x56, 0xb6, 0xc2))); // uppercase
        assert_eq!(parse_hex("12ab34"), Some(Rgb::new(0x12, 0xab, 0x34)));
    }

    #[test]
    fn parse_hex_accepts_the_shorthand_and_alpha_forms() {
        // TSK-379 parity: `#abc` expands each nibble (`a→aa`); 8-digit drops
        // the alpha in the opaque path but still parses the RGB.
        assert_eq!(parse_hex("#abc"), Some(Rgb::new(0xaa, 0xbb, 0xcc)));
        assert_eq!(parse_hex("fff"), Some(Rgb::new(255, 255, 255)));
        assert_eq!(parse_hex("#11223344"), Some(Rgb::new(0x11, 0x22, 0x33)));
        // Surrounding whitespace is trimmed (Swift `.whitespaces`).
        assert_eq!(parse_hex("  #56b6c2  "), Some(Rgb::new(0x56, 0xb6, 0xc2)));
    }

    #[test]
    fn parse_rgba_preserves_alpha_across_forms() {
        assert_eq!(parse_rgba("#abc"), Some(Rgba::new(0xaa, 0xbb, 0xcc, 255)));
        assert_eq!(parse_rgba("#56b6c2"), Some(Rgba::new(0x56, 0xb6, 0xc2, 255)));
        assert_eq!(parse_rgba("#11223344"), Some(Rgba::new(0x11, 0x22, 0x33, 0x44)));
        assert_eq!(parse_rgba("#000000ff"), Some(Rgba::new(0, 0, 0, 255)));
        assert_eq!(parse_rgba("#00000000"), Some(Rgba::new(0, 0, 0, 0)));
        // The opaque accessor drops alpha.
        assert_eq!(parse_rgba("#11223344").map(Rgba::rgb), Some(Rgb::new(0x11, 0x22, 0x33)));
    }

    #[test]
    fn parse_hex_rejects_malformed_without_panicking() {
        assert_eq!(parse_hex(""), None);
        assert_eq!(parse_hex("#"), None);
        assert_eq!(parse_hex("#ff"), None); // 2-digit: no such form
        assert_eq!(parse_hex("#fffff"), None); // 5-digit: no such form
        assert_eq!(parse_hex("#1234567"), None); // 7-digit: between 6 and 8
        assert_eq!(parse_hex("#123456789"), None); // 9-digit: too long
        assert_eq!(parse_hex("#gggggg"), None); // non-hex
        assert_eq!(parse_hex("rrggbb"), None); // non-hex letters
        assert_eq!(parse_hex("#12 456"), None); // interior space → non-hex body
        assert_eq!(parse_rgba("#12g"), None); // 3-digit with a non-hex nibble
    }

    /// EXHAUSTIVE list of every [`Role`]. The `non_exhaustive`-by-omission trap:
    /// when a new role is added it MUST be appended here, or the coverage tests
    /// below silently stop covering it. The compiler can't force it (this is a
    /// runtime array), so the discipline is: add a role ⇒ add it to `ALL_ROLES`.
    const ALL_ROLES: &[Role] = &[
        Role::Accent,
        Role::Header,
        Role::Muted,
        Role::HighlightBg,
        Role::CurrentBg,
        Role::OnHighlight,
        Role::Added,
        Role::Removed,
        Role::Hunk,
        Role::Context,
        Role::Link,
        Role::Text,
        Role::Background,
        Role::Surface,
        Role::Success,
        Role::Warning,
        Role::Gutter,
        Role::Border,
        Role::SynKeyword,
        Role::SynString,
        Role::SynNumber,
        Role::SynComment,
        Role::SynFunction,
        Role::SynType,
        Role::SynAttribute,
    ];

    #[test]
    fn dark_and_light_differ_per_role() {
        let dark = Palette::for_mode(Mode::Dark);
        let light = Palette::for_mode(Mode::Light);
        for &role in ALL_ROLES {
            assert_ne!(
                dark.color(role),
                light.color(role),
                "dark vs light must differ for {role:?}"
            );
        }
    }

    #[test]
    fn css_hex_formats_six_lowercase_digits() {
        assert_eq!(css_hex(Rgb::new(0x1a, 0x5f, 0xb4)), "#1a5fb4");
        assert_eq!(css_hex(Rgb::new(0, 0, 0)), "#000000");
        assert_eq!(css_hex(Rgb::new(255, 255, 255)), "#ffffff");
        // Leading-zero channels must keep their padding (this is the bug a naive
        // `format!("{:x}")` would have: 0x0a -> "a", losing the digit).
        assert_eq!(css_hex(Rgb::new(0x0a, 0x07, 0x00)), "#0a0700");
    }

    #[test]
    fn css_hex_round_trips_through_parse_hex() {
        for mode in [Mode::Dark, Mode::Light] {
            let p = Palette::for_mode(mode);
            for &role in ALL_ROLES {
                let c = p.color(role);
                assert_eq!(
                    parse_hex(&css_hex(c)),
                    Some(c),
                    "css_hex/parse_hex round-trip for {mode:?} {role:?}"
                );
            }
        }
    }

    #[test]
    fn every_role_resolves_in_both_modes() {
        // A trivial total-function check: `color` is `match`-exhaustive at
        // compile time, but this pins that ALL_ROLES is the full set the gate
        // exercises — a missing role here is the only way coverage silently drops.
        for mode in [Mode::Dark, Mode::Light] {
            let p = Palette::for_mode(mode);
            for &role in ALL_ROLES {
                let _ = p.color(role);
            }
        }
        assert_eq!(ALL_ROLES.len(), 25, "role count drifted — update ALL_ROLES");
    }

    #[test]
    fn for_mode_roundtrips_mode() {
        assert_eq!(Palette::for_mode(Mode::Dark).mode(), Mode::Dark);
        assert_eq!(Palette::for_mode(Mode::Light).mode(), Mode::Light);
    }

    #[test]
    fn known_token_values_are_stable() {
        // Pin a couple so an accidental palette edit trips the gate.
        assert_eq!(
            Palette::for_mode(Mode::Dark).color(Role::Accent),
            Rgb::new(0x56, 0xb6, 0xc2)
        );
        assert_eq!(
            Palette::for_mode(Mode::Light).color(Role::OnHighlight),
            Rgb::new(0xfa, 0xfa, 0xfa)
        );
    }

    #[test]
    fn added_and_removed_are_distinct_in_both_modes() {
        for mode in [Mode::Dark, Mode::Light] {
            let p = Palette::for_mode(mode);
            assert_ne!(p.color(Role::Added), p.color(Role::Removed), "{mode:?}");
        }
    }

    // --- Property tests (TSK-585 lane): color parse/format round-trips --------
    use proptest::prelude::*;

    proptest! {
        /// Rgb → css_hex → parse_hex recovers the same color — the documented
        /// inverse for the canonical 6-digit form (parse_hex(&css_hex(c)) == Some(c)).
        #[test]
        fn rgb_css_hex_parse_hex_roundtrips(
            r in any::<u8>(), g in any::<u8>(), b in any::<u8>(),
        ) {
            let c = Rgb::new(r, g, b);
            prop_assert_eq!(parse_hex(&css_hex(c)), Some(c));
        }

        /// `#abc` shorthand expands to `#aabbcc` (each nibble doubled): both forms
        /// parse to the same (valid) color, case-insensitively.
        #[test]
        fn parse_hex_shorthand_expands_each_nibble(d in "[0-9a-fA-F]{3}") {
            let long: String = d.chars().flat_map(|c| [c, c]).collect();
            prop_assert!(parse_hex(&d).is_some());
            prop_assert_eq!(parse_hex(&d), parse_hex(&long));
        }
    }
}
