//! "Show invisibles" — render visible glyphs for whitespace, shared by every
//! front-end's whitespace-markers toggle (the TUI `i` key, the web `?ws=1`).
//! Keeping the substitution in the core means all front-ends mark whitespace
//! identically by construction.
//!
//! No-dep, sans-IO (the project's posture). Pure per-line transform: the caller
//! supplies one already-split display line; this maps each space and tab to a
//! marker glyph and copies everything else verbatim. (Newlines are not present
//! in a single display line, so they are not handled here.)

/// Marker shown for a space (U+00B7 MIDDLE DOT).
pub const SPACE_MARKER: char = '·';
/// Marker shown for a tab (U+2192 RIGHTWARDS ARROW).
pub const TAB_MARKER: char = '→';

/// Return `line` with each space replaced by [`SPACE_MARKER`] and each tab by
/// [`TAB_MARKER`]; all other characters (including multi-byte ones) are copied
/// unchanged. The result has the same character count as the input.
#[must_use]
pub fn reveal(line: &str) -> String {
    line.chars()
        .map(|c| match c {
            ' ' => SPACE_MARKER,
            '\t' => TAB_MARKER,
            other => other,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{reveal, SPACE_MARKER, TAB_MARKER};

    #[test]
    fn spaces_and_tabs_become_markers() {
        assert_eq!(reveal("a b\tc"), format!("a{SPACE_MARKER}b{TAB_MARKER}c"));
    }

    #[test]
    fn leading_and_trailing_whitespace_marked() {
        assert_eq!(reveal("  x "), format!("{SPACE_MARKER}{SPACE_MARKER}x{SPACE_MARKER}"));
    }

    #[test]
    fn no_whitespace_is_unchanged() {
        assert_eq!(reveal("no_ws_here"), "no_ws_here");
        assert_eq!(reveal(""), "");
    }

    #[test]
    fn non_ascii_preserved_and_char_count_stable() {
        // Multi-byte content is copied verbatim; only ' ' and '\t' are swapped,
        // and the char count is unchanged (one marker per whitespace char).
        let input = "café\tx y";
        let out = reveal(input);
        assert_eq!(out, format!("café{TAB_MARKER}x{SPACE_MARKER}y"));
        assert_eq!(out.chars().count(), input.chars().count());
    }
}
