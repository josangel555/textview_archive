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

/// The semantic painting roles a front-end needs. Kept small + stable so the
/// palette is a fixed contract rather than a grab-bag of raw colors.
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
}

/// A resolved palette for one [`Mode`]. Cheap to copy; `color` is a pure lookup.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Palette {
    mode: Mode,
}

impl Palette {
    /// The palette for `mode`.
    pub const fn for_mode(mode: Mode) -> Self {
        Palette { mode }
    }

    pub const fn mode(&self) -> Mode {
        self.mode
    }

    /// The RGB for `role` in this palette's mode. Values are One Dark / One
    /// Light derived — distinct per role and per mode so a front-end mapping
    /// and a pixel test can both tell them apart.
    pub const fn color(&self, role: Role) -> Rgb {
        match self.mode {
            Mode::Dark => match role {
                Role::Accent => Rgb::new(0x56, 0xb6, 0xc2),
                Role::Header => Rgb::new(0x61, 0xaf, 0xef),
                Role::Muted => Rgb::new(0x5c, 0x63, 0x70),
                Role::HighlightBg => Rgb::new(0xe5, 0xc0, 0x7b),
                Role::CurrentBg => Rgb::new(0xc6, 0x78, 0xdd),
                Role::OnHighlight => Rgb::new(0x28, 0x2c, 0x34),
                Role::Added => Rgb::new(0x98, 0xc3, 0x79),
                Role::Removed => Rgb::new(0xe0, 0x6c, 0x75),
                Role::Hunk => Rgb::new(0xc6, 0x78, 0xdd),
                Role::Context => Rgb::new(0xab, 0xb2, 0xbf),
            },
            Mode::Light => match role {
                Role::Accent => Rgb::new(0x01, 0x84, 0xbc),
                Role::Header => Rgb::new(0x40, 0x78, 0xf2),
                Role::Muted => Rgb::new(0xa0, 0xa1, 0xa7),
                Role::HighlightBg => Rgb::new(0xc1, 0x84, 0x01),
                Role::CurrentBg => Rgb::new(0xa6, 0x26, 0xa4),
                Role::OnHighlight => Rgb::new(0xfa, 0xfa, 0xfa),
                Role::Added => Rgb::new(0x50, 0xa1, 0x4f),
                Role::Removed => Rgb::new(0xe4, 0x56, 0x49),
                Role::Hunk => Rgb::new(0xa6, 0x26, 0xa4),
                Role::Context => Rgb::new(0x38, 0x3a, 0x42),
            },
        }
    }
}

/// Parse a `#rrggbb` (or bare `rrggbb`) hex color, case-insensitive. Returns
/// `None` for any malformed input (wrong length, non-hex digits, empty) — never
/// panics. Offered for front-ends / future user theme config; the built-in
/// palettes use `Rgb` literals directly.
pub fn parse_hex(s: &str) -> Option<Rgb> {
    let body = s.strip_prefix('#').unwrap_or(s);
    if body.len() != 6 || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(&body[0..2], 16).ok()?;
    let g = u8::from_str_radix(&body[2..4], 16).ok()?;
    let b = u8::from_str_radix(&body[4..6], 16).ok()?;
    Some(Rgb::new(r, g, b))
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

    #[test]
    fn dark_and_light_differ_per_role() {
        let dark = Palette::for_mode(Mode::Dark);
        let light = Palette::for_mode(Mode::Light);
        for role in [
            Role::Accent,
            Role::Header,
            Role::Muted,
            Role::HighlightBg,
            Role::CurrentBg,
            Role::OnHighlight,
            Role::Added,
            Role::Removed,
            Role::Context,
        ] {
            assert_ne!(
                dark.color(role),
                light.color(role),
                "dark vs light must differ for {role:?}"
            );
        }
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
