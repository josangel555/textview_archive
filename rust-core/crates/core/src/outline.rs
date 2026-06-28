//! Markdown document outline — the pure heading scanner shared by every
//! front-end's table-of-contents (the ratatui TUI's `o` overlay, the web tier's
//! `<nav>` outline, and any future tier). Given a markdown file's text it
//! returns the ordered list of [`Heading`]s (level · title · 1-based line), so
//! the front-ends render the same outline *by construction* instead of each
//! re-deriving "what counts as a heading".
//!
//! **No parser.** This is a deliberately line-based scan (no `CommonMark` AST, no
//! new dependency): it recognizes ATX headings (`#`..`######`) and setext
//! headings (a text line underlined by `===` / `---`), and it tracks fenced code
//! blocks so a `#` *inside* a ```` ``` ```` / `~~~` fence is not mistaken for a
//! heading. It is intentionally a high-value subset, not a spec-complete parser:
//! the cases it skips (headings inside block quotes, HTML headings, ATX inside a
//! list item) are rare in the documents an outline is useful for.
//!
//! Sans-IO and allocation-light: the caller supplies the already-read text; this
//! module only walks it. `name` is accepted (so a front-end can pass the file
//! name through) but the scan itself is name-agnostic — the caller decides which
//! files get an outline (typically `*.md` / `*.markdown`).

/// One heading found in a markdown document.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Heading {
    /// Heading level, 1..=6 (`#` → 1, `######` → 6; setext `===` → 1, `---` → 2).
    pub level: u8,
    /// The heading text, trimmed (ATX leading hashes + the optional closing run
    /// of hashes are stripped; surrounding whitespace removed).
    pub title: String,
    /// 1-based line number the heading sits on (the text line for setext).
    pub line: usize,
}

/// Whether `name` looks like a markdown file (drives whether a front-end offers
/// the outline). Case-insensitive; matches the common markdown extensions.
#[must_use]
pub fn is_markdown(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".md")
        || lower.ends_with(".markdown")
        || lower.ends_with(".mdown")
        || lower.ends_with(".mkd")
}

/// Scan `text` (a markdown file named `name`) for headings, returning them in
/// document order. `name` is currently unused by the scan (the recognition is
/// purely content-based) but is part of the signature so a front-end can pass
/// the file name straight through and the rule for *which* files get an outline
/// stays at the call site (see [`is_markdown`]).
///
/// Recognized:
///   - **ATX**: up to 3 leading spaces, then `#`..`######`, then a space (or
///     end-of-line), then the title. A trailing run of `#` (a closing sequence)
///     is stripped. `####### ` (7 hashes) is *not* a heading.
///   - **Setext**: a non-blank text line immediately followed by a line that is
///     all `=` (→ level 1) or all `-` (→ level 2), with up to 3 leading spaces
///     on the underline. The text line is reported (at its own line number).
///
/// Excluded:
///   - Anything inside a fenced code block (```` ``` ```` or `~~~`), so a `#` or
///     an `=`/`-` underline within a code sample is never a false heading.
///   - Indented (4+ space) lines — those are code, not an ATX heading.
///   - A bare `#` with no space and no text (`#` / `##` alone is not a heading;
///     `CommonMark` requires the space-or-EOL after the hashes — `#foo` is text).
#[must_use]
pub fn headings(text: &str, name: &str) -> Vec<Heading> {
    let _ = name; // recognition is content-based; name kept for call-site parity
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<Heading> = Vec::new();
    // Active fence state: `Some((marker_char, run_len))` while inside a fence.
    // A closing fence must use the same marker char and be at least as long.
    let mut fence: Option<(char, usize)> = None;
    // Track whether the PREVIOUS content line could be a setext heading's text
    // (non-blank, not itself ATX, not a fence line, not already consumed).
    let mut prev_setext_text: Option<(usize, String)> = None;

    for (idx, raw) in lines.iter().enumerate() {
        let line_no = idx + 1; // 1-based
        let line = strip_cr(raw);

        // --- Fence open / close tracking (takes precedence over everything) ---
        if let Some((marker, open_len)) = fence {
            if let Some(close_len) = fence_marker(line) {
                let (ch, len) = close_len;
                if ch == marker && len >= open_len {
                    fence = None;
                }
            }
            // Inside a fence: no heading, and a fence line can't be setext text.
            prev_setext_text = None;
            continue;
        }
        if let Some((ch, len)) = fence_marker(line) {
            fence = Some((ch, len));
            prev_setext_text = None;
            continue;
        }

        // --- ATX heading? ---
        if let Some((level, title)) = atx_heading(line) {
            out.push(Heading { level, title, line: line_no });
            prev_setext_text = None;
            continue;
        }

        // --- Setext underline closing the previous text line? ---
        if let Some(level) = setext_underline(line) {
            if let Some((text_line, title)) = prev_setext_text.take() {
                out.push(Heading { level, title, line: text_line });
                continue;
            }
            // An underline with no preceding paragraph text is just a thematic
            // break / plain text — fall through (it can't itself be setext text).
            prev_setext_text = None;
            continue;
        }

        // --- Plain line: remember it as a candidate setext text line ---
        let trimmed = line.trim();
        if trimmed.is_empty() {
            prev_setext_text = None;
        } else {
            prev_setext_text = Some((line_no, trimmed.to_string()));
        }
    }
    out
}

/// Strip a single trailing `\r` (CRLF line endings) from a split line.
fn strip_cr(line: &str) -> &str {
    line.strip_suffix('\r').unwrap_or(line)
}

/// Count the leading spaces in `line` (used to enforce the ≤3-space ATX rule).
/// Tabs are not expanded here — a leading tab makes the line indented code, so
/// it won't pass the `<= 3` test (a tab counts as a non-space byte → `0` spaces
/// then a tab, which `atx_heading` rejects because the next char isn't `#`).
fn leading_spaces(line: &str) -> usize {
    line.bytes().take_while(|&b| b == b' ').count()
}

/// Parse `line` as an ATX heading, returning `(level, title)` when it is one.
/// Up to 3 leading spaces are allowed (4+ is indented code); 1..=6 `#`; then a
/// space or end-of-line; the title has its optional closing `#` run stripped.
fn atx_heading(line: &str) -> Option<(u8, String)> {
    if leading_spaces(line) > 3 {
        return None; // indented code, not a heading
    }
    let rest = line.trim_start_matches(' ');
    let hashes = rest.bytes().take_while(|&b| b == b'#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    let after = rest.get(hashes..)?;
    // `CommonMark`: the hash run must be followed by a space/tab OR end-of-line.
    if !after.is_empty() && !after.starts_with(' ') && !after.starts_with('\t') {
        return None; // e.g. `#foo` is a paragraph, not a heading
    }
    // Strip a trailing closing run of `#` (optionally space-padded): `## H ##`.
    let body = after.trim();
    let title = strip_closing_hashes(body);
    let level = u8::try_from(hashes).unwrap_or(6);
    Some((level, title.to_string()))
}

/// Strip an ATX closing sequence — a trailing run of `#` that is either the
/// whole remainder or separated from the title by whitespace. `"H ##"` → `"H"`,
/// `"H"` → `"H"`, `"###"` → `""` (a heading whose body is only hashes), `"a#b"`
/// → `"a#b"` (an interior `#` is part of the text, not a closing sequence).
fn strip_closing_hashes(body: &str) -> &str {
    let trimmed = body.trim_end();
    let without = trimmed.trim_end_matches('#');
    if without.len() == trimmed.len() {
        return trimmed; // no trailing hashes
    }
    // There WAS a trailing hash run. It's a valid closing sequence only if what
    // precedes it is empty or ends in whitespace (otherwise the `#` is interior
    // text, e.g. `a#`/`C#`).
    if without.is_empty() || without.ends_with([' ', '\t']) {
        without.trim_end()
    } else {
        trimmed
    }
}

/// Whether `line` is a setext underline, returning the implied heading level:
/// a run of `=` (→ 1) or `-` (→ 2), optionally up to 3 leading spaces and any
/// trailing spaces, and nothing else. A single `=`/`-` qualifies. Mixed runs
/// (`=-=`) do not.
fn setext_underline(line: &str) -> Option<u8> {
    if leading_spaces(line) > 3 {
        return None;
    }
    let core = line.trim();
    if core.is_empty() {
        return None;
    }
    if core.bytes().all(|b| b == b'=') {
        Some(1)
    } else if core.bytes().all(|b| b == b'-') {
        Some(2)
    } else {
        None
    }
}

/// Whether `line` opens or closes a code fence, returning `(marker_char, run_len)`
/// for a line that is (up to 3 leading spaces then) a run of ≥3 backticks or ≥3
/// tildes, optionally followed by an info string (for backticks; tildes allow
/// anything). A backtick fence's info string must not contain a backtick
/// (`CommonMark`), which also stops an inline ```` `code` ```` span being read as a
/// fence.
fn fence_marker(line: &str) -> Option<(char, usize)> {
    if leading_spaces(line) > 3 {
        return None;
    }
    let s = line.trim_start_matches(' ');
    let first = s.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let run = s.chars().take_while(|&c| c == first).count();
    if run < 3 {
        return None;
    }
    let info = s.get(run..).unwrap_or("");
    // A backtick fence's info string may not contain a backtick.
    if first == '`' && info.contains('`') {
        return None;
    }
    Some((first, run))
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        /// Any content wrapped in a fenced code block yields NO headings — a `#`
        /// (or any heading-looking line) inside a fence is code, not a heading.
        /// The generated lines contain no fence markers (charset excludes ` and ~)
        /// and no setext underlines (excludes = and -), so the wrapping fence stays
        /// open over all of them; this stresses fence suppression against arbitrary
        /// indented / length-varied `#` lines the example tests can't enumerate.
        #[test]
        fn fenced_content_yields_no_headings(
            lines in proptest::collection::vec("[ #a-z0-9]{0,30}", 0..15),
        ) {
            let mut doc = String::from("```\n");
            for l in &lines {
                doc.push_str(l);
                doc.push('\n');
            }
            doc.push_str("```\n");
            let hs = headings(&doc, "x.md");
            prop_assert!(hs.is_empty(), "fenced content must yield no headings; got {hs:?}");
        }
    }

    fn titles(hs: &[Heading]) -> Vec<&str> {
        hs.iter().map(|h| h.title.as_str()).collect()
    }

    /// Robustness audit (un-fuzzed shipped engine): arbitrary markdown-ish text —
    /// ATX (#..######, over-#, no-space), setext (===/---), fenced code, leading
    /// spaces/tabs, unicode, raw noise — must NEVER panic in headings(), and every
    /// Heading has a level in 1..=6 and a 1-based line. Deterministic LCG, no dep.
    /// Teeth: a level outside 1..=6 or a 0 line fails the assert.
    #[test]
    #[allow(clippy::cast_possible_truncation, reason = "LCG values are modulo-bounded before use")]
    fn headings_fuzz_never_panics_levels_and_lines_valid() {
        const LINES: &[&str] = &[
            "# h1", "## h2", "###### h6", "####### over", "#nospace", "#", "###   ",
            "title", "===", "---", "- - -", "```rust", "```", "~~~", "    indented",
            "\ttab", "> quote", "中文 标题", "## ## nested", "",
        ];
        fn lcg(state: &mut u64) -> u64 {
            *state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *state
        }
        let mut state: u64 = 0x011D_E217_0A7E_0001;
        for _ in 0..3000u32 {
            let n = (lcg(&mut state) % 12) as usize;
            let mut s = String::new();
            for _ in 0..n {
                s.push_str(LINES[(lcg(&mut state) as usize) % LINES.len()]);
                s.push('\n');
            }
            for h in &headings(&s, "f.md") {
                assert!(
                    (1..=6).contains(&h.level),
                    "heading level {} out of 1..=6 for {s:?}",
                    h.level
                );
                assert!(h.line >= 1, "heading line must be 1-based, got {}", h.line);
            }
        }
    }

    #[test]
    fn is_markdown_by_extension() {
        assert!(is_markdown("README.md"));
        assert!(is_markdown("NOTES.MARKDOWN"));
        assert!(is_markdown("a.mdown"));
        assert!(is_markdown("a.mkd"));
        assert!(!is_markdown("a.txt"));
        assert!(!is_markdown("md")); // no dot
    }

    #[test]
    fn atx_levels_one_through_six() {
        let text = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n";
        let hs = headings(text, "doc.md");
        assert_eq!(
            hs,
            vec![
                Heading { level: 1, title: "H1".into(), line: 1 },
                Heading { level: 2, title: "H2".into(), line: 2 },
                Heading { level: 3, title: "H3".into(), line: 3 },
                Heading { level: 4, title: "H4".into(), line: 4 },
                Heading { level: 5, title: "H5".into(), line: 5 },
                Heading { level: 6, title: "H6".into(), line: 6 },
            ]
        );
    }

    #[test]
    fn atx_seven_hashes_is_not_a_heading() {
        // 7+ hashes exceeds the max level → plain text, no heading.
        let hs = headings("####### too deep\n", "doc.md");
        assert!(hs.is_empty(), "{hs:?}");
    }

    #[test]
    fn atx_requires_space_after_hashes() {
        // `#foo` is a paragraph, not a heading (no space after the hash run).
        let hs = headings("#foo\n## bar\n", "doc.md");
        assert_eq!(titles(&hs), vec!["bar"], "{hs:?}");
        assert_eq!(hs[0].line, 2);
    }

    #[test]
    fn atx_strips_closing_hash_run() {
        let hs = headings("## Heading ##\n### Bare ###\n#### keep#sharp\n", "doc.md");
        assert_eq!(titles(&hs), vec!["Heading", "Bare", "keep#sharp"], "{hs:?}");
        // Interior `#` (C#-style) is preserved; only a whitespace-separated
        // trailing run is a closing sequence.
    }

    #[test]
    fn atx_bare_hashes_is_empty_titled_heading() {
        // `#` alone (hash then EOL) is a valid empty heading per `CommonMark`.
        let hs = headings("#\n##   \n", "doc.md");
        assert_eq!(hs.len(), 2, "{hs:?}");
        assert_eq!(hs[0], Heading { level: 1, title: String::new(), line: 1 });
        assert_eq!(hs[1], Heading { level: 2, title: String::new(), line: 2 });
    }

    #[test]
    fn setext_level_one_and_two() {
        let text = "Title One\n=========\n\nSubtitle\n--------\n";
        let hs = headings(text, "doc.md");
        assert_eq!(
            hs,
            vec![
                Heading { level: 1, title: "Title One".into(), line: 1 },
                Heading { level: 2, title: "Subtitle".into(), line: 4 },
            ]
        );
    }

    #[test]
    fn setext_single_underline_char_qualifies() {
        // A single `=` / `-` is a valid setext underline.
        let hs = headings("One\n=\nTwo\n-\n", "doc.md");
        assert_eq!(
            hs,
            vec![
                Heading { level: 1, title: "One".into(), line: 1 },
                Heading { level: 2, title: "Two".into(), line: 3 },
            ]
        );
    }

    #[test]
    fn setext_underline_needs_a_preceding_text_line() {
        // An underline after a blank line (no paragraph text) is NOT a heading.
        let hs = headings("\n=====\n", "doc.md");
        assert!(hs.is_empty(), "{hs:?}");
    }

    #[test]
    fn mixed_underline_is_not_setext() {
        let hs = headings("Title\n==-==\n", "doc.md");
        assert!(hs.is_empty(), "mixed run is not an underline: {hs:?}");
    }

    #[test]
    fn code_fence_excludes_false_headings_backtick() {
        // The `# not a heading` and the `===` underline live inside a fence, so
        // neither is picked up; the real `# Real` outside the fence is.
        let text = "\
# Real
```
# not a heading
fake title
========
```
## After
";
        let hs = headings(text, "doc.md");
        assert_eq!(titles(&hs), vec!["Real", "After"], "{hs:?}");
        assert_eq!(hs[0].line, 1);
        assert_eq!(hs[1].line, 7);
    }

    #[test]
    fn code_fence_excludes_false_headings_tilde() {
        let text = "~~~\n# inside tilde fence\n~~~\n# outside\n";
        let hs = headings(text, "doc.md");
        assert_eq!(titles(&hs), vec!["outside"], "{hs:?}");
    }

    #[test]
    fn fence_with_info_string_is_a_fence() {
        // A ```rust info-string fence still opens a code block.
        let text = "```rust\n# fn main\n```\n# real\n";
        let hs = headings(text, "doc.md");
        assert_eq!(titles(&hs), vec!["real"], "{hs:?}");
    }

    #[test]
    fn longer_closing_fence_closes_block() {
        // Opening with 3 backticks; a 4-backtick line still closes it (>= open).
        let text = "```\n# in\n````\n# out\n";
        let hs = headings(text, "doc.md");
        assert_eq!(titles(&hs), vec!["out"], "{hs:?}");
    }

    #[test]
    fn shorter_marker_does_not_close_fence() {
        // Open with 4 backticks; a 3-backtick line is NOT a valid close (too
        // short), so `# still in` stays inside and the block runs to the 4-tick.
        let text = "````\n```\n# still in\n````\n# out\n";
        let hs = headings(text, "doc.md");
        assert_eq!(titles(&hs), vec!["out"], "{hs:?}");
    }

    #[test]
    fn indented_four_spaces_is_code_not_heading() {
        // 4 leading spaces → indented code block line, not an ATX heading.
        let hs = headings("    # indented code\n# real\n", "doc.md");
        assert_eq!(titles(&hs), vec!["real"], "{hs:?}");
        assert_eq!(hs[0].line, 2);
    }

    #[test]
    fn three_space_indent_is_still_a_heading() {
        // Up to 3 leading spaces is allowed for an ATX heading.
        let hs = headings("   ### tilted\n", "doc.md");
        assert_eq!(hs, vec![Heading { level: 3, title: "tilted".into(), line: 1 }]);
    }

    #[test]
    fn crlf_line_endings_are_handled() {
        let text = "# One\r\n## Two\r\n";
        let hs = headings(text, "doc.md");
        assert_eq!(
            hs,
            vec![
                Heading { level: 1, title: "One".into(), line: 1 },
                Heading { level: 2, title: "Two".into(), line: 2 },
            ]
        );
    }

    #[test]
    fn empty_and_headingless_text_yields_nothing() {
        assert!(headings("", "doc.md").is_empty());
        assert!(headings("just a paragraph\nand another\n", "doc.md").is_empty());
    }

    #[test]
    fn line_numbers_are_one_based_and_accurate() {
        let text = "intro\n\n# First\nbody\n\n## Second\n";
        let hs = headings(text, "doc.md");
        assert_eq!(hs.len(), 2);
        assert_eq!(hs[0].line, 3);
        assert_eq!(hs[1].line, 6);
    }

    #[test]
    fn setext_text_line_after_atx_still_works() {
        // An ATX heading clears the setext-candidate state; a following text +
        // underline pair is still recognized.
        let text = "# Top\nSub\n---\n";
        let hs = headings(text, "doc.md");
        assert_eq!(
            hs,
            vec![
                Heading { level: 1, title: "Top".into(), line: 1 },
                Heading { level: 2, title: "Sub".into(), line: 2 },
            ]
        );
    }
}
