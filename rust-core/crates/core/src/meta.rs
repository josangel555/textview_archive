//! File-metadata detection for the front-ends' status bar / encoding badge —
//! the line-ending style and a coarse text-encoding label. Shared by every
//! front-end (the TUI status line, the web `/view` header) so the badge is
//! computed identically by construction rather than re-derived per front-end.
//!
//! No-dep, sans-IO (the project's posture — same as [`crate::indent`] /
//! [`crate::nav`]): the caller supplies the already-read bytes; this module only
//! inspects them. Encoding detection is a deliberately small BOM sniff (the
//! deterministic, testable subset) plus a UTF-8 default — NOT a full charset
//! guesser.

/// The dominant newline convention in a text buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineEnding {
    /// No line break at all (single line or empty buffer).
    None,
    /// Unix `\n`.
    Lf,
    /// Windows `\r\n`.
    Crlf,
    /// Classic Mac `\r`.
    Cr,
    /// More than one style is present.
    Mixed,
}

impl LineEnding {
    /// Short label for a status bar / badge.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            LineEnding::None => "no-eol",
            LineEnding::Lf => "LF",
            LineEnding::Crlf => "CRLF",
            LineEnding::Cr => "CR",
            LineEnding::Mixed => "mixed",
        }
    }
}

/// Detect the line-ending style of `bytes` (treated as text).
///
/// A `\r\n` pair counts as one CRLF (never double-counted as a lone CR + LF); a
/// `\n` not part of a CRLF is an LF; a `\r` not followed by `\n` is a CR. If
/// exactly one style appears it is returned; more than one yields [`LineEnding::Mixed`];
/// no line breaks at all yields [`LineEnding::None`].
#[must_use]
pub fn line_ending(bytes: &[u8]) -> LineEnding {
    let (mut lf, mut crlf, mut cr) = (0usize, 0usize, 0usize);
    let mut i = 0usize;
    while let Some(&b) = bytes.get(i) {
        match b {
            b'\r' => {
                if bytes.get(i + 1) == Some(&b'\n') {
                    crlf += 1;
                    i += 2;
                    continue;
                }
                cr += 1;
            }
            b'\n' => lf += 1,
            _ => {}
        }
        i += 1;
    }
    let styles = u8::from(lf > 0) + u8::from(crlf > 0) + u8::from(cr > 0);
    match styles {
        0 => LineEnding::None,
        1 if crlf > 0 => LineEnding::Crlf,
        1 if cr > 0 => LineEnding::Cr,
        1 => LineEnding::Lf,
        _ => LineEnding::Mixed,
    }
}

/// A coarse text-encoding label from a leading byte-order mark, defaulting to
/// `"UTF-8"` when no BOM is present. Only the BOMs the viewer cares about are
/// recognised — this is a label for the badge, not a charset decoder.
#[must_use]
pub fn encoding_label(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        "UTF-8 BOM"
    } else if bytes.starts_with(&[0xFF, 0xFE]) {
        "UTF-16 LE"
    } else if bytes.starts_with(&[0xFE, 0xFF]) {
        "UTF-16 BE"
    } else {
        "UTF-8"
    }
}

#[cfg(test)]
mod tests {
    use super::{encoding_label, line_ending, LineEnding};

    #[test]
    fn lf_only() {
        assert_eq!(line_ending(b"a\nb\nc"), LineEnding::Lf);
        assert_eq!(line_ending(b"a\n"), LineEnding::Lf);
    }

    #[test]
    fn crlf_only_not_double_counted() {
        // A CRLF must NOT register as a lone CR plus a lone LF (which would
        // wrongly read as Mixed).
        assert_eq!(line_ending(b"a\r\nb\r\n"), LineEnding::Crlf);
    }

    #[test]
    fn cr_only() {
        assert_eq!(line_ending(b"a\rb\rc"), LineEnding::Cr);
    }

    #[test]
    fn mixed_styles() {
        assert_eq!(line_ending(b"a\r\nb\nc"), LineEnding::Mixed); // CRLF + LF
        assert_eq!(line_ending(b"a\rb\nc"), LineEnding::Mixed); // CR + LF
    }

    #[test]
    fn no_line_break_is_none() {
        assert_eq!(line_ending(b""), LineEnding::None);
        assert_eq!(line_ending(b"single line"), LineEnding::None);
    }

    #[test]
    fn trailing_cr_at_eof_is_cr_not_crlf() {
        // A `\r` as the very last byte has no following `\n`, so it is a lone CR.
        assert_eq!(line_ending(b"a\r"), LineEnding::Cr);
    }

    #[test]
    fn labels_are_stable() {
        assert_eq!(LineEnding::Crlf.as_str(), "CRLF");
        assert_eq!(LineEnding::Lf.as_str(), "LF");
        assert_eq!(LineEnding::Mixed.as_str(), "mixed");
        assert_eq!(LineEnding::None.as_str(), "no-eol");
    }

    #[test]
    fn encoding_bom_sniff() {
        assert_eq!(encoding_label(&[0xEF, 0xBB, 0xBF, b'h', b'i']), "UTF-8 BOM");
        assert_eq!(encoding_label(&[0xFF, 0xFE, 0x68, 0x00]), "UTF-16 LE");
        assert_eq!(encoding_label(&[0xFE, 0xFF, 0x00, 0x68]), "UTF-16 BE");
        assert_eq!(encoding_label(b"plain ascii"), "UTF-8");
        assert_eq!(encoding_label(b""), "UTF-8");
    }
}
