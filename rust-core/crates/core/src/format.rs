//! Pretty-print (the "Formatted" view mode) — the pure reformatter shared by
//! every front-end (the `SwiftUI` app's `FormatViewer`, the ratatui TUI's
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

/// Two spaces per nesting level — matches the `SwiftUI` `FormatViewer` default.
const INDENT: &str = "  ";

/// Max container nesting the recursive walk will descend before bailing. The
/// parser is recursive (`value`→`object`/`array`→`value`), so an adversarial
/// deeply-nested document (e.g. `[[[[…]]]]`) would otherwise overflow the stack
/// and abort the process (release builds are `panic = "abort"`). Past this the
/// reformat returns `None` and the caller falls back to showing the raw text —
/// the same defense class as the cmark deep-nesting guard. 128 matches
/// `serde_json`'s default recursion limit; real JSON never nests this deep.
const MAX_DEPTH: usize = 128;

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
        // Bound recursion: `depth` is the container nesting level, so this caps
        // the recursive descent and prevents a stack overflow on pathological
        // input (returns None → caller shows raw text).
        if depth > MAX_DEPTH {
            return None;
        }
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

// ---------------------------------------------------------------------------
// XML / HTML-ish pretty-print (TSK-496) — the deferred sibling of `pretty_json`.
// Std-only, no parser dep. Tokenize → balance-check → re-emit with a 2-space
// indent. Content (text, attribute values, comments, CDATA, processing
// instructions, DOCTYPE) is preserved verbatim; only inter-node structural
// whitespace is rewritten. Malformed / unbalanced input → `None` so the caller
// falls back to raw text (never garbled output). Emission is ITERATIVE (a depth
// counter, not recursion), so even pathological nesting can't overflow the stack.

/// One lexical node of an XML document.
enum Tok {
    /// A start tag `<t …>` (not self-closing): the verbatim text + the tag name.
    Open { raw: String, name: String },
    /// An end tag `</t>`: the tag name.
    Close { name: String },
    /// A self-closing element `<t …/>`, kept verbatim (depth-neutral).
    Leaf(String),
    /// A comment / processing-instruction / CDATA / DOCTYPE, kept verbatim
    /// (depth-neutral — these don't open a scope).
    Other(String),
    /// Significant text between tags (whitespace-trimmed; empty runs dropped).
    Text(String),
}

/// Reformat `input` as pretty-printed XML/HTML markup with a 2-space indent.
///
/// Returns `None` when `input` isn't well-enough-formed to reflow safely
/// (unterminated tag/comment/CDATA, mismatched/unbalanced tags, or no element at
/// all) so the caller can fall back to the raw text. A text-only element stays
/// inline (`<t>x</t>`); an element with child elements puts them on their own
/// indented lines.
#[must_use]
pub fn pretty_xml(input: &str) -> Option<String> {
    let toks = xml_tokenize(input)?;
    if !xml_balanced(&toks) {
        return None;
    }
    Some(xml_emit(&toks))
}

/// Index just past `needle` starting the search at `from`, or `None`.
fn find_after(haystack: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    let mut i = from;
    loop {
        match haystack.get(i..i + needle.len()) {
            Some(w) if w == needle => return Some(i + needle.len()),
            Some(_) => i += 1,
            None => return None,
        }
    }
}

/// From a `<` at `start`, return the index just past the closing `>` of a normal
/// start/end/empty tag, honouring `"`/`'` quoted attribute values (so a `>`
/// inside an attribute doesn't end the tag early). `None` if unterminated.
fn scan_tag_end(b: &[u8], start: usize) -> Option<usize> {
    let mut i = start + 1;
    let mut quote: Option<u8> = None;
    while let Some(&c) = b.get(i) {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                }
            }
            None => match c {
                b'"' | b'\'' => quote = Some(c),
                b'>' => return Some(i + 1),
                _ => {}
            },
        }
        i += 1;
    }
    None
}

/// From a `<!` declaration at `start` (DOCTYPE), return the index past its `>`,
/// honouring quotes AND a `[ … ]` internal subset (whose `>`s don't end it).
fn scan_decl_end(b: &[u8], start: usize) -> Option<usize> {
    let mut i = start + 2;
    let mut quote: Option<u8> = None;
    let mut bracket: i32 = 0;
    while let Some(&c) = b.get(i) {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                }
            }
            None => match c {
                b'"' | b'\'' => quote = Some(c),
                b'[' => bracket += 1,
                b']' => bracket -= 1,
                b'>' if bracket <= 0 => return Some(i + 1),
                _ => {}
            },
        }
        i += 1;
    }
    None
}

/// Tag name of a start/empty tag `<name …>` — up to the first whitespace/`/`/`>`.
fn open_name(raw: &str) -> Option<String> {
    let s = raw.strip_prefix('<')?;
    let name: String =
        s.chars().take_while(|c| !c.is_whitespace() && *c != '>' && *c != '/').collect();
    (!name.is_empty()).then_some(name)
}

/// Tag name of an end tag `</name>`.
fn close_name(raw: &str) -> Option<String> {
    let inner = raw.strip_prefix("</")?.strip_suffix('>')?.trim();
    (!inner.is_empty()).then(|| inner.to_string())
}

/// Whether a start-ish tag is actually self-closing (`… />`), quote-safe (a `/`
/// inside an attribute value doesn't count — it's stripped with the value).
fn tag_is_selfclose(raw: &str) -> bool {
    raw.trim_end().strip_suffix('>').is_some_and(|s| s.trim_end().ends_with('/'))
}

fn xml_tokenize(input: &str) -> Option<Vec<Tok>> {
    let b = input.as_bytes();
    let mut i = 0;
    let mut out: Vec<Tok> = Vec::new();
    while i < b.len() {
        if b.get(i) == Some(&b'<') {
            let rest = input.get(i..)?;
            let end = if rest.starts_with("<!--") {
                find_after(b, i + 4, b"-->")?
            } else if rest.starts_with("<![CDATA[") {
                find_after(b, i + 9, b"]]>")?
            } else if rest.starts_with("<?") {
                find_after(b, i + 2, b"?>")?
            } else if rest.starts_with("<!") {
                scan_decl_end(b, i)?
            } else {
                scan_tag_end(b, i)?
            };
            let raw = input.get(i..end)?;
            if rest.starts_with("<!--") || rest.starts_with("<![CDATA[") || rest.starts_with("<?")
                || rest.starts_with("<!")
            {
                out.push(Tok::Other(raw.to_string()));
            } else if rest.starts_with("</") {
                out.push(Tok::Close { name: close_name(raw)? });
            } else if tag_is_selfclose(raw) {
                out.push(Tok::Leaf(raw.to_string()));
            } else {
                out.push(Tok::Open { raw: raw.to_string(), name: open_name(raw)? });
            }
            i = end;
        } else {
            let start = i;
            while matches!(b.get(i), Some(&c) if c != b'<') {
                i += 1;
            }
            let text = input.get(start..i)?.trim();
            if !text.is_empty() {
                out.push(Tok::Text(text.to_string()));
            }
        }
    }
    Some(out)
}

/// Every `Open` has a matching `Close` (LIFO), no stray closes, and there is at
/// least one element (so plain text / a lone comment isn't treated as XML).
fn xml_balanced(toks: &[Tok]) -> bool {
    let mut stack: Vec<&str> = Vec::new();
    let mut saw_element = false;
    for t in toks {
        match t {
            Tok::Open { name, .. } => {
                stack.push(name);
                saw_element = true;
            }
            Tok::Leaf(_) => saw_element = true,
            Tok::Close { name } => match stack.pop() {
                Some(open) if open == name => {}
                _ => return false,
            },
            Tok::Other(_) | Tok::Text(_) => {}
        }
    }
    stack.is_empty() && saw_element
}

fn xml_emit(toks: &[Tok]) -> String {
    let mut out = String::new();
    let mut depth: usize = 0;
    let mut i = 0;
    let push_line = |out: &mut String, depth: usize, s: &str| {
        for _ in 0..depth {
            out.push_str(INDENT);
        }
        out.push_str(s);
        out.push('\n');
    };
    while let Some(t) = toks.get(i) {
        match t {
            Tok::Open { raw, name } => {
                // Inline a text-only or empty element on one line:
                //   <t>x</t>   /   <t></t>
                let inline_child = match toks.get(i + 1) {
                    Some(Tok::Text(x) | Tok::Other(x)) => Some(x.as_str()),
                    _ => None,
                };
                if let (Some(x), Some(Tok::Close { name: cn })) = (inline_child, toks.get(i + 2))
                    && cn == name {
                        push_line(&mut out, depth, &format!("{raw}{x}</{name}>"));
                        i += 3;
                        continue;
                    }
                if let Some(Tok::Close { name: cn }) = toks.get(i + 1)
                    && cn == name {
                        push_line(&mut out, depth, &format!("{raw}</{name}>"));
                        i += 2;
                        continue;
                    }
                push_line(&mut out, depth, raw);
                depth += 1;
                i += 1;
            }
            Tok::Close { name } => {
                depth = depth.saturating_sub(1);
                push_line(&mut out, depth, &format!("</{name}>"));
                i += 1;
            }
            Tok::Leaf(raw) | Tok::Other(raw) | Tok::Text(raw) => {
                push_line(&mut out, depth, raw);
                i += 1;
            }
        }
    }
    out.trim_end().to_string()
}

/// Human-readable byte size — `512 B`, `1.5 KB`, `3.0 MB`. Shared by the file
/// browser / metadata surfaces of every front-end (was duplicated verbatim in the
/// TUI and web tiers; TSK-570). Sans-IO; one short `String`.
#[must_use]
pub fn human_size(bytes: usize) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

#[cfg(test)]
mod tests {
    use super::{human_size, pretty_json, pretty_xml};

    #[test]
    fn compact_object_is_indented() {
        let out = pretty_json(r#"{"a":1,"b":2}"#).expect("valid json");
        assert_eq!(out, "{\n  \"a\": 1,\n  \"b\": 2\n}");
    }

    /// Robustness audit (un-fuzzed shipped engine — completes the engine-fuzz
    /// sweep): arbitrary JSON/XML-ish text — deep nesting (exercising the
    /// MAX_DEPTH=128 recursion cap), malformed structures, raw noise, unicode —
    /// must NEVER panic in pretty_json OR pretty_xml. And the formatters must be
    /// IDEMPOTENT: formatting already-formatted output returns it unchanged.
    /// Deterministic LCG, no dep. Teeth: a non-idempotent reformat or a panic on
    /// a degenerate input fails the assert.
    #[test]
    #[allow(clippy::cast_possible_truncation, reason = "LCG values are modulo-bounded before use")]
    fn pretty_fuzz_never_panics_and_is_idempotent() {
        const JSON_TOK: &[&str] = &[
            "{", "}", "[", "]", ":", ",", "\"k\"", "\"v\"", "1", "-2.5e3", "true",
            "false", "null", " ", "\n", "\t", "{}", "[]", "\"\\u00e9\"", "中",
        ];
        const XML_TOK: &[&str] = &[
            "<a>", "</a>", "<b/>", "text", "<c x=\"1\">", "</c>", "<!--x-->",
            "<![CDATA[y]]>", "<", ">", "&amp;", "\n", " ", "中",
        ];
        fn lcg(state: &mut u64) -> u64 {
            *state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *state
        }
        let mut state: u64 = 0xF02A_7ED1_C0FF_EE01;
        for _ in 0..3000u32 {
            // JSON-ish input.
            let n = (lcg(&mut state) % 30) as usize;
            let mut j = String::new();
            for _ in 0..n {
                j.push_str(JSON_TOK[(lcg(&mut state) as usize) % JSON_TOK.len()]);
            }
            // Sometimes prepend a deep nest that exceeds MAX_DEPTH (cap → None, no overflow).
            if lcg(&mut state).is_multiple_of(5) {
                let d = (lcg(&mut state) % 300) as usize;
                j = format!("{}{j}", "[".repeat(d));
            }
            if let Some(y) = pretty_json(&j) {
                assert_eq!(
                    pretty_json(&y).as_deref(),
                    Some(y.as_str()),
                    "pretty_json not idempotent for {j:?}"
                );
            }
            // XML-ish input.
            let m = (lcg(&mut state) % 20) as usize;
            let mut x = String::new();
            for _ in 0..m {
                x.push_str(XML_TOK[(lcg(&mut state) as usize) % XML_TOK.len()]);
            }
            if let Some(y) = pretty_xml(&x) {
                assert_eq!(
                    pretty_xml(&y).as_deref(),
                    Some(y.as_str()),
                    "pretty_xml not idempotent for {x:?}"
                );
            }
        }
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
    fn deeply_nested_input_is_bounded_not_overflowed() {
        // Balanced, *valid* deeply-nested JSON: the only reason to reject it is
        // the recursion cap. Without the cap this would recurse ~100k frames and
        // abort the process; with it, pretty_json returns None (→ raw-text
        // fallback) and the call simply completes.
        let deep = format!("{}{}", "[".repeat(100_000), "]".repeat(100_000));
        assert!(pretty_json(&deep).is_none(), "over-deep nesting bails to None, no overflow");
        // A modest nesting well under the cap still formats fine.
        let ok = format!("{}1{}", "[".repeat(10), "]".repeat(10));
        assert!(pretty_json(&ok).is_some(), "normal nesting still pretty-prints");
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

    // --- XML (TSK-496) ---

    #[test]
    fn xml_nests_elements_and_inlines_text_leaves() {
        let out = pretty_xml("<a><b>hi</b><c>bye</c></a>").expect("valid xml");
        assert_eq!(out, "<a>\n  <b>hi</b>\n  <c>bye</c>\n</a>");
    }

    #[test]
    fn xml_deeper_nesting_indents_per_level() {
        let out = pretty_xml("<a><b><c>x</c></b></a>").expect("valid");
        assert_eq!(out, "<a>\n  <b>\n    <c>x</c>\n  </b>\n</a>");
    }

    #[test]
    fn xml_preserves_attributes_and_self_closing() {
        let out = pretty_xml(r#"<root><img src="a.png"/><p class="x">t</p></root>"#).expect("valid");
        assert_eq!(out, "<root>\n  <img src=\"a.png\"/>\n  <p class=\"x\">t</p>\n</root>");
    }

    #[test]
    fn xml_gt_inside_attribute_value_does_not_end_the_tag() {
        // The `>` inside the quoted title must not terminate the start tag early.
        let out = pretty_xml(r#"<a title="x > y"><b>1</b></a>"#).expect("valid");
        assert_eq!(out, "<a title=\"x > y\">\n  <b>1</b>\n</a>");
    }

    #[test]
    fn xml_keeps_declaration_comment_and_cdata_verbatim() {
        let src = "<?xml version=\"1.0\"?><r><!-- c --><d><![CDATA[a<b>c]]></d></r>";
        let out = pretty_xml(src).expect("valid");
        assert_eq!(
            out,
            "<?xml version=\"1.0\"?>\n<r>\n  <!-- c -->\n  <d><![CDATA[a<b>c]]></d>\n</r>"
        );
    }

    #[test]
    fn xml_empty_element_stays_inline() {
        assert_eq!(pretty_xml("<a><b></b></a>").unwrap(), "<a>\n  <b></b>\n</a>");
    }

    #[test]
    fn xml_already_pretty_is_idempotent() {
        let pretty = "<a>\n  <b>x</b>\n</a>";
        assert_eq!(pretty_xml(pretty).unwrap(), pretty);
    }

    #[test]
    fn xml_svg_self_closing_root_formats() {
        let out = pretty_xml(r#"<svg><rect x="0"/><circle r="1"/></svg>"#).expect("valid");
        assert_eq!(out, "<svg>\n  <rect x=\"0\"/>\n  <circle r=\"1\"/>\n</svg>");
    }

    #[test]
    fn human_size_formats_each_magnitude_band() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(1023), "1023 B"); // just under the KB threshold
        assert_eq!(human_size(1024), "1.0 KB");
        assert_eq!(human_size(1536), "1.5 KB");
        assert_eq!(human_size(1024 * 1024 - 1), "1024.0 KB"); // just under the MB threshold
        assert_eq!(human_size(1024 * 1024), "1.0 MB");
        assert_eq!(human_size(5 * 1024 * 1024), "5.0 MB");
    }

    #[test]
    fn xml_malformed_or_unbalanced_returns_none() {
        assert!(pretty_xml("").is_none(), "empty");
        assert!(pretty_xml("plain text").is_none(), "no element");
        assert!(pretty_xml("<a><b></a>").is_none(), "mismatched close");
        assert!(pretty_xml("<a></b>").is_none(), "wrong close name");
        assert!(pretty_xml("<a>").is_none(), "unclosed element");
        assert!(pretty_xml("</a>").is_none(), "stray close");
        assert!(pretty_xml("<a><unterminated").is_none(), "unterminated tag");
        assert!(pretty_xml("<a><!-- no end").is_none(), "unterminated comment");
        assert!(pretty_xml("<!-- just a comment -->").is_none(), "no element, only comment");
    }
}
