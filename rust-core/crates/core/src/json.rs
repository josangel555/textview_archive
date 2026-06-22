//! Hand-rolled JSON subset parser (TSK-632) — owner decision 2026-06-11:
//! NO `serde_json`; a recursive-descent parser well inside the 1000-line
//! rule (precedent: the hand-rolled MessagePack codecs on both sides of the
//! wire). Consumer: the Claude transcript (JSONL) projection — tolerant
//! line framing where a torn tail line during live append must never fail
//! the file.
//!
//! Scope (full JSON value grammar, conservative semantics):
//! - objects/arrays/strings/numbers/bool/null; strings with all escapes
//!   including `\uXXXX` surrogate pairs (lone surrogates are an ERROR, like
//!   Foundation's JSONSerialization — never silently U+FFFD);
//! - numbers parse as `i64` when integral-in-range, else `f64`; NaN/Inf
//!   tokens are rejected (JSON has none);
//! - objects preserve pair order in a `Vec`; `get` returns the LAST
//!   occurrence of a duplicated key (Foundation-dictionary semantics, so
//!   the Swift twin and this port agree on hostile duplicate-key docs);
//! - hard depth cap (no stack overflow on `[[[[…`), strict
//!   trailing-garbage rejection per document.
//!
//! No-panic discipline: byte-cursor parser, zero `[]` indexing, zero
//! unwrap; every failure is a typed [`JsonError`] with a byte offset.

/// Maximum nesting depth — far beyond legitimate transcripts, far below
/// stack limits.
pub const MAX_DEPTH: u32 = 128;

/// A parsed JSON value.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    /// Integral number that fits i64.
    Int(i64),
    /// Any other finite number.
    Float(f64),
    Str(String),
    Array(Vec<JsonValue>),
    /// Pair order preserved; duplicates kept (see [`JsonValue::get`]).
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    /// Object member lookup — LAST occurrence wins (Foundation semantics).
    #[must_use]
    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        match self {
            JsonValue::Object(pairs) => {
                pairs.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v)
            }
            _ => None,
        }
    }

    /// String payload, if this is a string.
    #[must_use]
    pub fn as_str(&self) -> Option<&str> {
        match self {
            JsonValue::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }

    /// Array items, if this is an array.
    #[must_use]
    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            JsonValue::Array(items) => Some(items.as_slice()),
            _ => None,
        }
    }
}

/// Parse failure: what + byte offset (into the document).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonError {
    pub message: String,
    pub offset: usize,
}

struct Parser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn err<T>(&self, message: impl Into<String>) -> Result<T, JsonError> {
        Err(JsonError { message: message.into(), offset: self.i })
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.i).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let b = self.peek();
        if b.is_some() {
            self.i = self.i.saturating_add(1);
        }
        b
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i = self.i.saturating_add(1);
        }
    }

    fn expect_keyword(&mut self, kw: &str, value: JsonValue) -> Result<JsonValue, JsonError> {
        let end = self.i.saturating_add(kw.len());
        if self.text.get(self.i..end) == Some(kw) {
            self.i = end;
            Ok(value)
        } else {
            self.err(format!("expected '{kw}'"))
        }
    }

    fn value(&mut self, depth: u32) -> Result<JsonValue, JsonError> {
        if depth > MAX_DEPTH {
            return self.err("nesting too deep");
        }
        self.skip_ws();
        match self.peek() {
            Some(b'n') => self.expect_keyword("null", JsonValue::Null),
            Some(b't') => self.expect_keyword("true", JsonValue::Bool(true)),
            Some(b'f') => self.expect_keyword("false", JsonValue::Bool(false)),
            Some(b'"') => self.string().map(JsonValue::Str),
            Some(b'[') => self.array(depth),
            Some(b'{') => self.object(depth),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => self.err("unexpected character"),
            None => self.err("unexpected end of input"),
        }
    }

    fn array(&mut self, depth: u32) -> Result<JsonValue, JsonError> {
        self.bump(); // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.bump();
            return Ok(JsonValue::Array(items));
        }
        loop {
            items.push(self.value(depth.saturating_add(1))?);
            self.skip_ws();
            match self.bump() {
                Some(b',') => continue,
                Some(b']') => return Ok(JsonValue::Array(items)),
                _ => return self.err("expected ',' or ']'"),
            }
        }
    }

    fn object(&mut self, depth: u32) -> Result<JsonValue, JsonError> {
        self.bump(); // '{'
        let mut pairs = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.bump();
            return Ok(JsonValue::Object(pairs));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return self.err("expected object key string");
            }
            let key = self.string()?;
            self.skip_ws();
            if self.bump() != Some(b':') {
                return self.err("expected ':'");
            }
            let val = self.value(depth.saturating_add(1))?;
            pairs.push((key, val));
            self.skip_ws();
            match self.bump() {
                Some(b',') => continue,
                Some(b'}') => return Ok(JsonValue::Object(pairs)),
                _ => return self.err("expected ',' or '}'"),
            }
        }
    }

    fn string(&mut self) -> Result<String, JsonError> {
        self.bump(); // opening '"'
        let mut out = String::new();
        let mut seg_start = self.i;
        loop {
            match self.peek() {
                None => return self.err("unterminated string"),
                Some(b'"') => {
                    if let Some(seg) = self.text.get(seg_start..self.i) {
                        out.push_str(seg);
                    }
                    self.bump();
                    return Ok(out);
                }
                Some(b'\\') => {
                    if let Some(seg) = self.text.get(seg_start..self.i) {
                        out.push_str(seg);
                    }
                    self.bump(); // '\'
                    match self.bump() {
                        Some(b'"') => out.push('"'),
                        Some(b'\\') => out.push('\\'),
                        Some(b'/') => out.push('/'),
                        Some(b'b') => out.push('\u{0008}'),
                        Some(b'f') => out.push('\u{000C}'),
                        Some(b'n') => out.push('\n'),
                        Some(b'r') => out.push('\r'),
                        Some(b't') => out.push('\t'),
                        Some(b'u') => out.push(self.unicode_escape()?),
                        _ => return self.err("invalid escape"),
                    }
                    seg_start = self.i;
                }
                Some(b) if b < 0x20 => return self.err("raw control character in string"),
                Some(_) => {
                    self.i = self.i.saturating_add(1);
                }
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, JsonError> {
        let end = self.i.saturating_add(4);
        let Some(hex) = self.text.get(self.i..end) else {
            return self.err("truncated \\u escape");
        };
        match u32::from_str_radix(hex, 16) {
            Ok(v) if hex.len() == 4 => {
                self.i = end;
                Ok(v)
            }
            _ => self.err("invalid \\u escape"),
        }
    }

    /// `\uXXXX`, with surrogate-pair handling. A lone surrogate is an ERROR
    /// (Foundation parity) — never a silent U+FFFD substitution.
    fn unicode_escape(&mut self) -> Result<char, JsonError> {
        let hi = self.hex4()?;
        if (0xD800..=0xDBFF).contains(&hi) {
            // High surrogate: require \uXXXX low surrogate.
            if self.bump() != Some(b'\\') || self.bump() != Some(b'u') {
                return self.err("lone high surrogate");
            }
            let lo = self.hex4()?;
            if !(0xDC00..=0xDFFF).contains(&lo) {
                return self.err("invalid low surrogate");
            }
            let cp = 0x10000u32
                .saturating_add(hi.saturating_sub(0xD800) << 10)
                .saturating_add(lo.saturating_sub(0xDC00));
            char::from_u32(cp).map_or_else(|| self.err("invalid surrogate pair"), Ok)
        } else if (0xDC00..=0xDFFF).contains(&hi) {
            self.err("lone low surrogate")
        } else {
            char::from_u32(hi).map_or_else(|| self.err("invalid codepoint"), Ok)
        }
    }

    /// Parse a number per the JSON grammar (RFC 8259 §6), matching what
    /// Foundation's `JSONSerialization` accepts so the Swift twin and this
    /// port agree on every transcript record (TSK-983). The hand-rolled loops
    /// previously permitted ZERO digits and had no leading-zero rule, so this
    /// port accepted `0123`, `1.`, `-.5`, `01.5` — all of which Foundation
    /// REJECTS, silently dropping the JSONL record on the Swift side. Each
    /// component now enforces its digit requirement and the leading-zero rule
    /// up front, returning [`Self::err`] on violation.
    fn number(&mut self) -> Result<JsonValue, JsonError> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.bump();
        }
        // Integer part: a single `0`, OR `1-9` followed by any digits. A
        // leading `0` may NOT be followed by another digit (reject `01`,
        // `0123`); at least one digit is required (reject a bare `-`/`.`).
        match self.peek() {
            Some(b'0') => {
                self.bump();
            }
            Some(b'1'..=b'9') => {
                self.bump();
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.bump();
                }
            }
            _ => return self.err("expected digit in number"),
        }
        let mut integral = true;
        // Fractional part: `.` MUST be followed by ≥1 digit (reject `1.`).
        if self.peek() == Some(b'.') {
            integral = false;
            self.bump();
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return self.err("expected digit after decimal point");
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.bump();
            }
        }
        // Exponent: `e`/`E`, optional sign, then ≥1 digit (reject `1e`,
        // `1e+`).
        if matches!(self.peek(), Some(b'e' | b'E')) {
            integral = false;
            self.bump();
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.bump();
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return self.err("expected digit in exponent");
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.bump();
            }
        }
        let Some(tok) = self.text.get(start..self.i) else {
            return self.err("bad number token");
        };
        if integral && let Ok(v) = tok.parse::<i64>() {
            return Ok(JsonValue::Int(v));
        }
        match tok.parse::<f64>() {
            Ok(v) if v.is_finite() => Ok(JsonValue::Float(v)),
            _ => self.err("invalid number"),
        }
    }
}

/// Parse ONE complete JSON document; trailing non-whitespace is an error
/// (strict — JSONL framing splits lines before this runs).
pub fn parse(text: &str) -> Result<JsonValue, JsonError> {
    let mut p = Parser { text, bytes: text.as_bytes(), i: 0 };
    let v = p.value(0)?;
    p.skip_ws();
    if p.i != p.bytes.len() {
        return p.err("trailing garbage after document");
    }
    Ok(v)
}

/// One JSONL line's outcome: parsed, skipped (malformed — the tolerant
/// transcript contract), or blank.
#[derive(Debug, PartialEq)]
pub enum JsonlLine {
    Value(JsonValue),
    /// Malformed line — the consumer SKIPS it (a torn tail line during a
    /// live append must never fail the whole transcript).
    Skipped(JsonError),
    Blank,
}

/// Tolerant JSONL framing: one outcome per `\n`-separated line (a trailing
/// `\r` is stripped so CRLF transcripts parse identically).
#[must_use]
pub fn parse_jsonl(text: &str) -> Vec<JsonlLine> {
    text.split('\n')
        .map(|raw| {
            let line = raw.strip_suffix('\r').unwrap_or(raw);
            if line.trim().is_empty() {
                JsonlLine::Blank
            } else {
                match parse(line) {
                    Ok(v) => JsonlLine::Value(v),
                    Err(e) => JsonlLine::Skipped(e),
                }
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Robustness fuzz (TSK-1232, completing the TSK-1223 engine-fuzz coverage):
    /// the hand-rolled recursive-descent parser must NEVER panic on adversarial
    /// input — random concatenations of structural tokens, unterminated strings,
    /// bad `\uXXXX` escapes (incl. lone surrogates), huge/malformed numbers, raw
    /// garbage, and pathological nesting. Deterministic LCG, no dep. Teeth: a
    /// panic (unbounded recursion, a slice past the cursor, an escape mis-handle)
    /// fails it; `parse` always returns Ok|Err, and `parse_jsonl` yields exactly
    /// one outcome per `\n`-separated line.
    #[test]
    #[allow(clippy::cast_possible_truncation, reason = "LCG output is modulo-bounded before indexing")]
    fn parse_fuzz_never_panics_and_jsonl_is_line_aligned() {
        const TOKENS: &[&str] = &[
            "{", "}", "[", "]", ":", ",", "\"", "\\", "\\u", "\\uD800", "\\n",
            "true", "false", "null", "0", "-0", "1e999", "9999999999999999999",
            "1.5e-", "\"k\"", "  ", "\n", "\t", "\u{4e2d}", "\u{0}", ".", "+", "NaN",
        ];
        fn lcg(state: &mut u64) -> u64 {
            *state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *state
        }
        let mut state: u64 = 0x4A53_4F4E_0001_0001;
        for _ in 0..4000u32 {
            let n = (lcg(&mut state) % 60) as usize;
            let mut s = String::new();
            for _ in 0..n {
                s.push_str(TOKENS[(lcg(&mut state) % TOKENS.len() as u64) as usize]);
            }
            // No-panic discipline: parse returns Ok|Err for ANY input.
            let _ = parse(&s);
            // JSONL framing: exactly one outcome per '\n'-separated line.
            assert_eq!(
                parse_jsonl(&s).len(),
                s.split('\n').count(),
                "parse_jsonl must yield one outcome per line for {s:?}"
            );
        }
        // Pathological nesting must hit the MAX_DEPTH cap as an Err, never a
        // stack overflow (pins the depth guard on the fuzz path too).
        assert!(
            parse(&"[".repeat(10_000)).is_err(),
            "deep nesting must error at the depth cap, not overflow the stack"
        );
    }

    #[test]
    fn scalars() {
        assert_eq!(parse("null").unwrap(), JsonValue::Null);
        assert_eq!(parse("true").unwrap(), JsonValue::Bool(true));
        assert_eq!(parse("false").unwrap(), JsonValue::Bool(false));
        assert_eq!(parse("42").unwrap(), JsonValue::Int(42));
        assert_eq!(parse("-7").unwrap(), JsonValue::Int(-7));
        assert_eq!(parse("1.5").unwrap(), JsonValue::Float(1.5));
        assert_eq!(parse("2e3").unwrap(), JsonValue::Float(2000.0));
        assert_eq!(parse("\"hi\"").unwrap(), JsonValue::Str("hi".into()));
    }

    #[test]
    fn i64_bounds_and_overflow_to_float() {
        assert_eq!(parse("9223372036854775807").unwrap(), JsonValue::Int(i64::MAX));
        // One past i64::MAX: integral but out of range → f64, not a trap
        // (the S3 audit class: out-of-Int64 JSON must never crash).
        let overflowed = parse("9223372036854775808").unwrap();
        assert!(
            matches!(overflowed, JsonValue::Float(f) if f > 9.2e18),
            "expected float, got {overflowed:?}"
        );
    }

    #[test]
    fn number_grammar_matches_foundation() {
        // TSK-983: the hand-rolled loops used to accept these malformed forms
        // (returning 123, 1.0, -0.5, 1.5 respectively), but Foundation's
        // JSONSerialization REJECTS all of them — silently dropping the whole
        // JSONL record on the Swift side (an A/B parity divergence). They must
        // now be errors here too.
        for bad in ["0123", "1.", "-.5", "01.5"] {
            assert!(
                parse(bad).is_err(),
                "{bad:?} is malformed per the JSON grammar — must be rejected (Foundation parity)"
            );
        }
        // Additional malformed forms that share the same grammar violations.
        assert!(parse("00").is_err(), "leading-zero rule: 00");
        assert!(parse("-01").is_err(), "leading-zero rule applies after sign");
        assert!(parse(".5").is_err(), "bare fraction has no integer part");
        assert!(parse("1e").is_err(), "exponent needs a digit");
        assert!(parse("1e+").is_err(), "exponent sign still needs a digit");
        assert!(parse("1.e3").is_err(), "decimal point needs a digit before exponent");

        // Valid forms still parse to the right value/type.
        assert_eq!(parse("0").unwrap(), JsonValue::Int(0));
        assert_eq!(parse("-0").unwrap(), JsonValue::Int(0));
        assert_eq!(parse("10").unwrap(), JsonValue::Int(10));
        assert_eq!(parse("-0.5").unwrap(), JsonValue::Float(-0.5));
        assert_eq!(parse("1.5").unwrap(), JsonValue::Float(1.5));
        assert_eq!(parse("0.0").unwrap(), JsonValue::Float(0.0));
        assert_eq!(parse("1e3").unwrap(), JsonValue::Float(1000.0));
        assert_eq!(parse("1E-3").unwrap(), JsonValue::Float(0.001));
        assert_eq!(parse("0.5e2").unwrap(), JsonValue::Float(50.0));
    }

    #[test]
    fn strings_escapes_and_surrogates() {
        assert_eq!(
            parse(r#""a\n\t\"\\bA""#).unwrap(),
            JsonValue::Str("a\n\t\"\\bA".into())
        );
        // Surrogate pair → 😀
        assert_eq!(
            parse(r#""😀""#).unwrap(),
            JsonValue::Str("😀".into())
        );
        // Lone surrogates are ERRORS (Foundation parity), not U+FFFD.
        assert!(parse(r#""\uD83D""#).is_err());
        assert!(parse(r#""\uDE00""#).is_err());
        // Raw control char rejected; escaped is fine.
        assert!(parse("\"a\u{01}b\"").is_err());
    }

    #[test]
    fn objects_preserve_order_and_get_is_last_wins() {
        let v = parse(r#"{"a":1,"b":2,"a":3}"#).unwrap();
        assert_eq!(v.get("a"), Some(&JsonValue::Int(3)), "duplicate key: last wins");
        assert_eq!(v.get("b"), Some(&JsonValue::Int(2)));
        assert_eq!(v.get("zz"), None);
    }

    #[test]
    fn nested_structures() {
        let v = parse(r#"{"msg":{"content":[{"type":"text","text":"hi"}]}}"#).unwrap();
        let text = v
            .get("msg")
            .and_then(|m| m.get("content"))
            .and_then(JsonValue::as_array)
            .and_then(<[JsonValue]>::first)
            .and_then(|b| b.get("text"))
            .and_then(JsonValue::as_str);
        assert_eq!(text, Some("hi"));
    }

    #[test]
    fn hostile_inputs_error_cleanly() {
        // Deep nesting beyond the cap: error, not stack overflow.
        let deep = "[".repeat(5000);
        assert!(parse(&deep).is_err());
        // Truncated structures.
        assert!(parse(r#"{"a":"#).is_err());
        assert!(parse(r#"["#).is_err());
        assert!(parse(r#""unterminated"#).is_err());
        // Trailing garbage.
        assert!(parse("1 trailing").is_err());
        // JSON has no NaN/Infinity tokens.
        assert!(parse("NaN").is_err());
        assert!(parse("Infinity").is_err());
        // Bare minus / malformed numbers.
        assert!(parse("-").is_err());
        // Empty input.
        assert!(parse("").is_err());
    }

    #[test]
    fn error_carries_offset() {
        let e = parse(r#"{"a": @}"#).unwrap_err();
        assert_eq!(e.offset, 6);
    }

    #[test]
    fn jsonl_tolerant_framing() {
        let lines = parse_jsonl("{\"a\":1}\r\n\nGARBAGE\n{\"b\":2}\n{\"torn\":");
        assert_eq!(lines.len(), 5);
        assert!(matches!(lines.first(), Some(JsonlLine::Value(_))), "CRLF line parses");
        assert!(matches!(lines.get(1), Some(JsonlLine::Blank)));
        assert!(matches!(lines.get(2), Some(JsonlLine::Skipped(_))), "garbage skipped");
        assert!(matches!(lines.get(3), Some(JsonlLine::Value(_))));
        assert!(
            matches!(lines.get(4), Some(JsonlLine::Skipped(_))),
            "torn tail line (live append) is skipped, never fatal"
        );
    }

    #[test]
    fn unicode_passthrough_unescaped() {
        // Raw multibyte UTF-8 inside strings copies through segment-wise.
        assert_eq!(parse("\"héllo 😀\"").unwrap(), JsonValue::Str("héllo 😀".into()));
    }
}
