//! Pretty-print (the "Formatted" view mode) — the pure reformatter shared by
//! every front-end (the SwiftUI app's `FormatViewer`, the ratatui TUI's
//! Formatted mode, the web tier). Given a file's text it returns a re-indented
//! copy so the front-ends render identical formatting *by construction* instead
//! of each shelling out to `jq`/`xmllint` or re-deriving the layout.
//!
//! **No parser dependency.** This is a deliberately hand-rolled, std-only
//! reformatter (the project's no-dep stance — same as [`crate::outline`] /
//! [`crate::indent`]): JSON is reformatted by a tiny recursive-descent walk that
//! re-emits with a fixed 2-space indent. It validates as it goes, so malformed
//! input yields `None` and the caller falls back to plain text (the Formatted
//! mode simply isn't offered) rather than emitting garbage.
//!
//! Sans-IO and allocation-light: the caller supplies the already-read text; this
//! module only walks it and builds one output `String`. String *contents* are
//! copied verbatim (escapes preserved) — only structural whitespace is rewritten.
//!
//! Scope: JSON today (the clean, unambiguous case). XML/HTML pretty-print is a
//! separate follow-up slice — its mixed-content / CDATA / attribute rules are a
//! different, much larger problem and deliberately not folded in here.

/// Two spaces per nesting level — matches the SwiftUI `FormatViewer` default.
const INDENT: &str = "  ";

/// Reformat `input` as pretty-printed JSON with a 2-space indent.
///
/// Returns `None` when `input` is not a single well-formed JSON document
/// (malformed, empty, or trailing garbage after the top-level value) so the
/// caller can fall back to showing the raw text. Whitespace between tokens is
/// rewritten; string contents (including escapes) are preserved byte-for-byte.
#[must_use]
pub fn pretty_json(input: &str) -> Option<String> {
    let mut p = Json {
        bytes: input.as_bytes(),
        pos: 0,
        out: String::with_capacity(input.len() + input.len() / 4 + 16),
    };
    p.skip_ws();
    p.value(0)?;
    p.skip_ws();
    // A valid document is exactly one value; anything left over is garbage.
    if p.pos != p.bytes.len() {
        return None;
    }
    Some(p.out)
}

struct Json<'a> {
    bytes: &'a [u8],
    pos: usize,
    out: String,
}

impl Json<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let b = self.peek();
        if b.is_some() {
            self.pos += 1;
        }
        b
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn indent(&mut self, depth: usize) {
        for _ in 0..depth {
            self.out.push_str(INDENT);
        }
    }

    fn value(&mut self, depth: usize) -> Option<()> {
        match self.peek()? {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => self.string(),
            b't' => self.literal("true"),
            b'f' => self.literal("false"),
            b'n' => self.literal("null"),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn literal(&mut self, lit: &str) -> Option<()> {
        let end = self.pos + lit.len();
        if self.bytes.get(self.pos..end) == Some(lit.as_bytes()) {
            self.pos = end;
            self.out.push_str(lit);
            Some(())
        } else {
            None
        }
    }

    fn number(&mut self) -> Option<()> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek()? {
            b'0' => self.pos += 1, // a leading 0 must stand alone (no 0123)
            b'1'..=b'9' => self.eat_digits(),
            _ => return None,
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return None;
            }
            self.eat_digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return None;
            }
            self.eat_digits();
        }
        // Numbers are ASCII, so the slice is always valid UTF-8.
        self.out.push_str(core::str::from_utf8(self.bytes.get(start..self.pos)?).ok()?);
        Some(())
    }

    fn eat_digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
    }

    /// Copy a JSON string token verbatim (from the opening to the closing
    /// quote), skipping escaped characters so an escaped quote/backslash does
    /// not end the token early. Contents — including `\uXXXX`, `\"`, `\\` — are
    /// preserved exactly; only the surrounding structural layout changes.
    fn string(&mut self) -> Option<()> {
        let start = self.pos;
        self.pos += 1; // opening quote (caller verified it)
        loop {
            match self.bump()? {
                b'"' => break,
                b'\\' => {
                    self.bump()?; // consume the escaped byte; \uXXXX hex digits
                                  // are ordinary chars and copy through fine
                }
                _ => {}
            }
        }
        self.out.push_str(core::str::from_utf8(self.bytes.get(start..self.pos)?).ok()?);
        Some(())
    }

    fn object(&mut self, depth: usize) -> Option<()> {
        self.pos += 1; // {
        self.out.push('{');
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            self.out.push('}');
            return Some(());
        }
        loop {
            self.out.push('\n');
            self.indent(depth + 1);
            self.skip_ws();
            if self.peek()? != b'"' {
                return None; // keys must be strings
            }
            self.string()?;
            self.skip_ws();
            if self.bump()? != b':' {
                return None;
            }
            self.out.push_str(": ");
            self.skip_ws();
            self.value(depth + 1)?;
            self.skip_ws();
            match self.bump()? {
                b',' => {
                    self.out.push(',');
                    continue;
                }
                b'}' => {
                    self.out.push('\n');
                    self.indent(depth);
                    self.out.push('}');
                    return Some(());
                }
                _ => return None,
            }
        }
    }

    fn array(&mut self, depth: usize) -> Option<()> {
        self.pos += 1; // [
        self.out.push('[');
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            self.out.push(']');
            return Some(());
        }
        loop {
            self.out.push('\n');
            self.indent(depth + 1);
            self.skip_ws();
            self.value(depth + 1)?;
            self.skip_ws();
            match self.bump()? {
                b',' => {
                    self.out.push(',');
                    continue;
                }
                b']' => {
                    self.out.push('\n');
                    self.indent(depth);
                    self.out.push(']');
                    return Some(());
                }
                _ => return None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::pretty_json;

    #[test]
    fn compact_object_is_indented() {
        let out = pretty_json(r#"{"a":1,"b":2}"#).expect("valid json");
        assert_eq!(out, "{\n  \"a\": 1,\n  \"b\": 2\n}");
    }

    #[test]
    fn nested_object_and_array() {
        let out = pretty_json(r#"{"x":[1,2,{"y":true}]}"#).expect("valid json");
        assert_eq!(
            out,
            "{\n  \"x\": [\n    1,\n    2,\n    {\n      \"y\": true\n    }\n  ]\n}"
        );
    }

    #[test]
    fn empty_containers_stay_on_one_line() {
        assert_eq!(pretty_json("{}").unwrap(), "{}");
        assert_eq!(pretty_json("[]").unwrap(), "[]");
        assert_eq!(pretty_json(r#"{"a":{},"b":[]}"#).unwrap(), "{\n  \"a\": {},\n  \"b\": []\n}");
    }

    #[test]
    fn string_escapes_and_braces_are_preserved() {
        // A brace / bracket / comma INSIDE a string must not drive indentation,
        // and an escaped quote must not end the string early.
        let out = pretty_json(r#"{"k":"a {b} [c], \"q\" \\ end"}"#).expect("valid json");
        assert_eq!(out, "{\n  \"k\": \"a {b} [c], \\\"q\\\" \\\\ end\"\n}");
    }

    #[test]
    fn scalars_round_trip_verbatim() {
        assert_eq!(pretty_json("-12.5e+3").unwrap(), "-12.5e+3");
        assert_eq!(pretty_json("  true ").unwrap(), "true");
        assert_eq!(pretty_json("null").unwrap(), "null");
        assert_eq!(pretty_json(r#""hié""#).unwrap(), r#""hié""#);
    }

    #[test]
    fn already_pretty_input_reformats_stably() {
        let pretty = "{\n  \"a\": 1\n}";
        // Re-formatting an already-pretty document is idempotent.
        assert_eq!(pretty_json(pretty).unwrap(), pretty);
    }

    #[test]
    fn malformed_input_returns_none() {
        assert!(pretty_json("").is_none(), "empty");
        assert!(pretty_json("{").is_none(), "unterminated object");
        assert!(pretty_json(r#"{"a":}"#).is_none(), "missing value");
        assert!(pretty_json(r#"{"a" 1}"#).is_none(), "missing colon");
        assert!(pretty_json("[1,]").is_none(), "trailing comma");
        assert!(pretty_json("{1:2}").is_none(), "non-string key");
        assert!(pretty_json("nul").is_none(), "truncated literal");
        assert!(pretty_json("01").is_none(), "leading-zero number");
        assert!(pretty_json("{} junk").is_none(), "trailing garbage");
        assert!(pretty_json("not json at all").is_none(), "plain text");
    }
}
