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
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    #[must_use] 
    pub const fn new(r: u8, g: u8, b: u8) -> Self {
        Rgb { r, g, b }
    }
}

/// Which palette a front-end is painting with. `Light`/`Dark` are explicit,
/// terminal-theme-independent looks (the TUI also has an "adaptive" mode that
/// bypasses the palette and uses the terminal's own ANSI theme — that lives in
/// the front-end, not here).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Light,
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

/// Parse a `#rrggbb` (or bare `rrggbb`) hex color, case-insensitive. Returns
/// `None` for any malformed input (wrong length, non-hex digits, empty) — never
/// panics. Offered for front-ends / future user theme config; the built-in
/// palettes use `Rgb` literals directly.
#[must_use] 
pub fn parse_hex(s: &str) -> Option<Rgb> {
    let body = s.strip_prefix('#').unwrap_or(s);
    if body.len() != 6 || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(body.get(0..2)?, 16).ok()?;
    let g = u8::from_str_radix(body.get(2..4)?, 16).ok()?;
    let b = u8::from_str_radix(body.get(4..6)?, 16).ok()?;
    Some(Rgb::new(r, g, b))
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
    fn parse_hex_rejects_malformed_without_panicking() {
        assert_eq!(parse_hex(""), None);
        assert_eq!(parse_hex("#"), None);
        assert_eq!(parse_hex("#fff"), None); // 3-digit shorthand not supported
        assert_eq!(parse_hex("#1234567"), None); // too long
        assert_eq!(parse_hex("#gggggg"), None); // non-hex
        assert_eq!(parse_hex("rrggbb"), None); // non-hex letters
        assert_eq!(parse_hex("#12 456"), None); // space
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
}
