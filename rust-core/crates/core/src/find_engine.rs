//! `FindEngine` port (TSK-630) — the whole-document find with literal/regex
//! modes, the Rust twin of Swift's `FindEngine`. Distinct from [`crate::find`]
//! (the per-line literal matcher the TUI/web front-ends share): this surface
//! reports **UTF-16** ranges + 1-based line/column because its consumer is the
//! macOS host, whose `NSRange`/CodeMirror world indexes UTF-16 code units.
//!
//! **ReDoS is structurally gone.** `regex-lite` is a worst-case-linear-time
//! PikeVM (owner-approved, zero transitive deps, default-features OFF), so the
//! Swift side's two-layer guard (`RegexComplexityGuard.reject` shape analysis
//! plus the `boundedMatches` wall-clock) has no Rust counterpart and
//! `timed_out` is structurally `false`.
//!
//! **Documented divergences from the Swift/ICU twin** (the A/B corpus stays
//! inside the common subset; an adapter falls back to Swift on `InvalidPattern`):
//! - case-insensitive matching is ASCII-only (`regex-lite` does no Unicode
//!   case folding; ICU does) — same stance the front-end matcher documents;
//! - ICU-only constructs (lookaround, backreferences) fail to compile here
//!   and surface as `InvalidPattern` rather than matching.
//!
//! Line/column accounting mirrors the Swift S2-E semantics exactly: bare CR
//! advances a line, CRLF advances once, columns are 1-based UTF-16 units from
//! the first character after the terminator, and a match landing ON the LF of
//! a CRLF pair clamps to column 1 (the CORR-6 contract).

use serde::{Deserialize, Serialize};

/// One match: UTF-16 range + 1-based line/column (UTF-16 columns).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineMatch {
    /// UTF-16 offset of the match start in the whole document.
    pub location: u32,
    /// Match length in UTF-16 code units.
    pub length: u32,
    /// 1-based line.
    pub line: u32,
    /// 1-based column in UTF-16 units (CORR-6: never 0).
    pub column: u32,
}

/// Literal (escaped) vs user regex.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryKind {
    Literal,
    Regex,
}

/// Escape a literal so every char matches itself (the `regex-lite` syntax
/// set: ASCII punctuation that could be meta gets a backslash; everything
/// else passes through). Hand-rolled because regex-lite does not re-export
/// `regex::escape` under our minimal feature set.
fn escape_literal(pattern: &str) -> String {
    let mut out = String::with_capacity(pattern.len() * 2);
    for ch in pattern.chars() {
        if ch.is_ascii() && !ch.is_ascii_alphanumeric() {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

/// A pattern compiled ONCE, reusable across many texts.
///
/// `search()` compiles + searches in one shot (the per-document host path);
/// cross-file callers (`serve::search`) want to compile the user pattern a
/// single time and sweep it over thousands of files, so they build a
/// `CompiledMatcher` up front and call [`CompiledMatcher::search_text`] per
/// file — avoiding a per-file regex (re)compile (TSK-973).
///
/// An empty pattern compiles to a never-matching matcher (mirrors `search()`'s
/// "empty pattern ⇒ no matches" contract).
pub struct CompiledMatcher {
    /// `None` ⇒ empty pattern ⇒ matches nothing (cheap short-circuit).
    re: Option<regex_lite::Regex>,
}

impl CompiledMatcher {
    /// Compile `pattern` once.
    ///
    /// # Errors
    /// `Err(reason)` = the pattern does not compile (invalid syntax, or an
    /// ICU-only construct regex-lite rejects). Reported here, ONCE, so a
    /// cross-file caller never re-discovers a bad pattern per file.
    pub fn compile(
        pattern: &str,
        kind: QueryKind,
        case_sensitive: bool,
        whole_word: bool,
    ) -> Result<Self, String> {
        if pattern.is_empty() {
            return Ok(Self { re: None });
        }
        let mut pat = match kind {
            QueryKind::Literal => escape_literal(pattern),
            QueryKind::Regex => pattern.to_owned(),
        };
        if whole_word {
            pat = format!("\\b{pat}\\b");
        }
        let re = regex_lite::RegexBuilder::new(&pat)
            .case_insensitive(!case_sensitive)
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self { re: Some(re) })
    }

    /// Sweep the (already-compiled) pattern over `text`, returning UTF-16
    /// ranges + 1-based line/column. Cheap to call repeatedly: no compile.
    #[allow(clippy::cast_possible_truncation,
            reason = "TSK-575: the only cast is ch.len_utf16() (always 1 or 2) added to a u32 \
                      position — never truncates")]
    #[must_use]
    pub fn search_text(&self, text: &str) -> Vec<EngineMatch> {
        let Some(re) = self.re.as_ref() else { return Vec::new() };
        single_sweep(re, text)
    }
}

/// Search `text` for `pattern`. `Err(reason)` = the pattern does not compile
/// (invalid syntax, or an ICU-only construct regex-lite rejects); the host
/// maps it to `FindError.invalidRegex` / falls back to the Swift engine.
///
/// One-shot convenience over [`CompiledMatcher`] for the per-document host
/// path; cross-file callers should `compile` once and reuse.
pub fn search(
    text: &str,
    pattern: &str,
    kind: QueryKind,
    case_sensitive: bool,
    whole_word: bool,
) -> Result<Vec<EngineMatch>, String> {
    Ok(CompiledMatcher::compile(pattern, kind, case_sensitive, whole_word)?.search_text(text))
}

/// The single monotonic O(N) sweep: byte ranges → UTF-16 + line/column
/// (the Swift P11 single-sweep shape — O(N), not O(M·N)).
#[allow(clippy::cast_possible_truncation,
        reason = "TSK-575: the only cast is ch.len_utf16() (always 1 or 2) added to a u32 \
                  position — never truncates")]
fn single_sweep(re: &regex_lite::Regex, text: &str) -> Vec<EngineMatch> {
    // Byte ranges first; one monotonic sweep below converts to UTF-16 +
    // line/column (the Swift P11 single-sweep shape — O(N), not O(M·N)).
    let byte_matches: Vec<(usize, usize)> =
        re.find_iter(text).map(|m| (m.start(), m.end())).collect();
    if byte_matches.is_empty() {
        return Vec::new();
    }

    let mut out: Vec<EngineMatch> = Vec::with_capacity(byte_matches.len());
    let mut iter = text.char_indices().peekable();
    let mut utf16_pos: u32 = 0;
    let mut line: u32 = 1;
    let mut line_start_utf16: u32 = 0;
    let mut mi = 0usize;
    // Per-match accumulator: (location, line, column) once the start byte is
    // reached; pushed when the end byte is reached.
    let mut pending: Option<(u32, u32, u32)> = None;

    // Walk every char once; match starts/ends always fall on char boundaries
    // (regex-lite guarantees codepoint-aligned ranges on &str).
    loop {
        let byte_pos = iter.peek().map_or(text.len(), |&(b, _)| b);

        // Close any match ending here (end can equal the next start, so close
        // before opening). Zero-length matches close immediately after opening.
        while let Some((loc, ln, col)) = pending {
            let end_byte = byte_matches.get(mi).map(|&(_, e)| e);
            if end_byte == Some(byte_pos) {
                out.push(EngineMatch {
                    location: loc,
                    length: utf16_pos.saturating_sub(loc),
                    line: ln,
                    column: col,
                });
                pending = None;
                mi = mi.saturating_add(1);
            } else {
                break;
            }
        }
        // Open the next match starting here.
        if pending.is_none()
            && let Some(&(start, end)) = byte_matches.get(mi)
            && start == byte_pos
        {
            let col = utf16_pos
                .saturating_sub(line_start_utf16)
                .saturating_add(1)
                .max(1); // CORR-6 clamp
            if end == byte_pos {
                // Zero-length match (e.g. a bare \b regex).
                out.push(EngineMatch { location: utf16_pos, length: 0, line, column: col });
                mi = mi.saturating_add(1);
            } else {
                pending = Some((utf16_pos, line, col));
            }
        }

        let Some((_, ch)) = iter.next() else { break };
        utf16_pos = utf16_pos.saturating_add(ch.len_utf16() as u32);
        match ch {
            '\r' => {
                line = line.saturating_add(1);
                // CRLF: consume the LF as part of the terminator.
                if let Some(&(_, '\n')) = iter.peek() {
                    iter.next();
                    utf16_pos = utf16_pos.saturating_add(1);
                }
                line_start_utf16 = utf16_pos;
            }
            '\n' => {
                line = line.saturating_add(1);
                line_start_utf16 = utf16_pos;
            }
            _ => {}
        }
        if mi >= byte_matches.len() && pending.is_none() {
            break; // all matches resolved — no need to walk the tail
        }
    }
    // A match ending exactly at EOF closed in the final loop iteration above
    // (byte_pos == text.len()); a still-pending one here is a logic error in
    // the sweep, surfaced as a truncated result rather than a panic.
    out
}

// ---------------------------------------------------------------------------
// Wire layer — `ffi_frame_body!` shape.
// ---------------------------------------------------------------------------

/// Borrowed `text` (TSK-561): the whole document crosses per find request;
/// the pattern/kind fields are query-sized and stay owned.
#[derive(Deserialize)]
struct SearchRequest<'a> {
    #[serde(borrow)]
    text: std::borrow::Cow<'a, str>,
    pattern: String,
    /// "literal" | "regex" — anything else is a wire error (typed enums are
    /// the contract; unknown values must not silently default).
    kind: String,
    case_sensitive: bool,
    whole_word: bool,
}

#[derive(Serialize)]
struct WireEngineMatch {
    location: u32,
    length: u32,
    line: u32,
    column: u32,
}

#[derive(Serialize)]
struct SearchResponse {
    /// Non-null = the pattern didn't compile (host maps to invalidRegex /
    /// Swift-engine fallback). Matches are empty in that case.
    error: Option<String>,
    matches: Vec<WireEngineMatch>,
}

/// `{text, pattern, kind, case_sensitive, whole_word}` request frame →
/// `{error, matches:[{location,length,line,column}]}` response frame.
pub fn search_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: SearchRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let kind = match req.kind.as_str() {
        "literal" => QueryKind::Literal,
        "regex" => QueryKind::Regex,
        other => {
            return crate::wire::encode_frame(&SearchResponse {
                error: Some(format!("unknown find kind '{other}'")),
                matches: Vec::new(),
            });
        }
    };
    let resp = match search(&req.text, &req.pattern, kind, req.case_sensitive, req.whole_word) {
        Ok(matches) => SearchResponse {
            error: None,
            matches: matches
                .into_iter()
                .map(|m| WireEngineMatch {
                    location: m.location,
                    length: m.length,
                    line: m.line,
                    column: m.column,
                })
                .collect(),
        },
        Err(reason) => SearchResponse { error: Some(reason), matches: Vec::new() },
    };
    crate::wire::encode_frame(&resp)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lit(text: &str, pattern: &str) -> Vec<EngineMatch> {
        search(text, pattern, QueryKind::Literal, false, false).unwrap()
    }

    #[test]
    fn empty_pattern_no_matches() {
        assert!(lit("hello", "").is_empty());
    }

    #[test]
    fn literal_basics_and_positions() {
        let m = lit("hello world hello", "hello");
        assert_eq!(m.len(), 2);
        assert_eq!((m[0].location, m[0].length, m[0].line, m[0].column), (0, 5, 1, 1));
        assert_eq!((m[1].location, m[1].line, m[1].column), (12, 1, 13));
    }

    #[test]
    fn literal_escapes_metacharacters() {
        assert_eq!(lit("a.c abc", "a.c").len(), 1, "dot must be literal");
        assert_eq!(lit("x(1) y", "(1)").len(), 1);
    }

    #[test]
    fn compiled_matcher_reused_matches_one_shot_search() {
        // TSK-973: compile once, sweep many — must yield byte-identical
        // results to calling `search()` (which compiles per call) on each text.
        let m = CompiledMatcher::compile("needle", QueryKind::Literal, false, false).unwrap();
        let texts = [
            "needle here\nand a needle again\n",
            "no match\nneedle deep\n",
            "nothing\n",
            "NEEDLE upper", // case-insensitive default
        ];
        for t in texts {
            let reused = m.search_text(t);
            let oneshot = search(t, "needle", QueryKind::Literal, false, false).unwrap();
            assert_eq!(reused, oneshot, "reused matcher must equal a fresh per-text compile");
        }
        // And it actually finds the cross-text hits.
        assert_eq!(m.search_text(texts[0]).len(), 2);
        assert_eq!(m.search_text(texts[3]).len(), 1, "case-insensitive ascii by default");
    }

    #[test]
    fn compiled_matcher_empty_pattern_never_matches() {
        let m = CompiledMatcher::compile("", QueryKind::Literal, false, false).unwrap();
        assert!(m.search_text("anything at all").is_empty());
    }

    #[test]
    fn compiled_matcher_invalid_pattern_fails_at_compile() {
        // The compile error is reported ONCE (at compile), not per text.
        let err = CompiledMatcher::compile("(unclosed", QueryKind::Regex, false, false);
        assert!(err.is_err(), "invalid regex must fail at compile time");
    }

    #[test]
    fn case_insensitive_ascii_default() {
        assert_eq!(lit("Hello HELLO", "hello").len(), 2);
        let cs = search("Hello HELLO", "hello", QueryKind::Literal, true, false).unwrap();
        assert!(cs.is_empty());
    }

    #[test]
    fn lines_and_columns_lf_cr_crlf() {
        // LF
        let m = lit("a\nbb\nXc", "X");
        assert_eq!((m[0].line, m[0].column), (3, 1));
        // CR-only (classic Mac) — bare CR advances the line (the S2-E fix).
        let m = lit("a\rX", "X");
        assert_eq!((m[0].line, m[0].column), (2, 1));
        // CRLF advances ONCE and columns skip both terminator units.
        let m = lit("ab\r\ncX", "X");
        assert_eq!((m[0].line, m[0].column), (2, 2));
    }

    #[test]
    fn utf16_offsets_for_astral_input() {
        // 😀 is 2 UTF-16 units; match after it starts at UTF-16 offset 2.
        let m = lit("😀X", "X");
        assert_eq!((m[0].location, m[0].length, m[0].column), (2, 1, 3));
    }

    #[test]
    fn regex_mode_and_whole_word() {
        let m = search("cat catalog cat", "cat", QueryKind::Literal, false, true).unwrap();
        assert_eq!(m.len(), 2, "whole-word must skip 'catalog'");
        let m = search("a1 b22 c3", r"\d+", QueryKind::Regex, false, false).unwrap();
        assert_eq!(m.len(), 3);
        assert_eq!(m[1].length, 2);
    }

    #[test]
    fn invalid_regex_is_err_not_panic() {
        assert!(search("x", "(unclosed", QueryKind::Regex, false, false).is_err());
        // ICU-only construct → clean Err (the documented fallback channel).
        assert!(search("x", "(?=look)", QueryKind::Regex, false, false).is_err());
    }

    #[test]
    fn match_at_eof_closes() {
        let m = lit("abc", "bc");
        assert_eq!((m[0].location, m[0].length), (1, 2));
    }

    #[test]
    fn wire_round_trip_and_error_channel() {
        #[derive(Serialize)]
        struct Req<'a> {
            text: &'a str,
            pattern: &'a str,
            kind: &'a str,
            case_sensitive: bool,
            whole_word: bool,
        }
        #[derive(Deserialize)]
        struct Resp {
            error: Option<String>,
            matches: Vec<RMatch>,
        }
        #[derive(Deserialize)]
        struct RMatch {
            location: u32,
            length: u32,
            line: u32,
            column: u32,
        }
        let ok = crate::wire::encode_frame(&Req {
            text: "a\nXb", pattern: "x", kind: "literal",
            case_sensitive: false, whole_word: false,
        }).unwrap();
        let resp: Resp = crate::wire::decode_frame(&search_wire(&ok).unwrap()).unwrap();
        assert!(resp.error.is_none());
        assert_eq!(resp.matches.len(), 1);
        assert_eq!(
            (resp.matches[0].location, resp.matches[0].length,
             resp.matches[0].line, resp.matches[0].column),
            (2, 1, 2, 1)
        );

        let bad = crate::wire::encode_frame(&Req {
            text: "x", pattern: "(", kind: "regex",
            case_sensitive: false, whole_word: false,
        }).unwrap();
        let resp: Resp = crate::wire::decode_frame(&search_wire(&bad).unwrap()).unwrap();
        assert!(resp.error.is_some(), "compile failure rides the error field");
        assert!(resp.matches.is_empty());

        let unk = crate::wire::encode_frame(&Req {
            text: "x", pattern: "x", kind: "fancy",
            case_sensitive: false, whole_word: false,
        }).unwrap();
        let resp: Resp = crate::wire::decode_frame(&search_wire(&unk).unwrap()).unwrap();
        assert!(resp.error.unwrap().contains("unknown find kind"));
    }
}
