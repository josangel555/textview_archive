//! App-contract highlight runs (TSK-660): the SwiftUI host's `HighlightRun`
//! shape — UTF-16 code-unit offsets + the app's 20-kind `TokenKind`
//! vocabulary (rawValue strings) — produced from the same tree-sitter
//! grammars the TUI path uses.
//!
//! Two deliberate contract choices:
//!   * **Kinds are the Swift `TokenKind` rawValues** (`"keyword"`,
//!     `"builtin"`, `"tagAttribute"`, …) and the capture→kind table MIRRORS
//!     `Sources/ViewerCore/Highlight/CaptureMap.swift` — contract parity by
//!     construction, not by post-hoc comparison. The mapping is finer than
//!     the TUI's coarse [`crate::TokenKind`] (it distinguishes
//!     builtin/escape/regex/tagAttribute).
//!   * **Offsets are UTF-16 code units** (`NSRange`'s model), converted once
//!     here (the find-port sweep pattern) so the host applies runs directly
//!     without a per-run bridge walk.
//!
//! Unlike the Swift engine, `tree-sitter-highlight` EVALUATES `#match?` /
//! `#eq?` query predicates — the class of TS/JS identifier mis-coloring
//! tracked as TSK-410 is structurally absent on this path (pinned in tests).

use serde::{Deserialize, Serialize};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

use crate::Lang;

/// Capture-name → app `TokenKind` rawValue. MIRRORS `CaptureMap.table` in
/// `Sources/ViewerCore/Highlight/CaptureMap.swift` — keep the two in sync
/// (the Swift table is the contract of record until the twin retires).
///
/// `tree-sitter-highlight`'s `configure` resolves each query capture to the
/// LONGEST recognized name that is a dot-boundary prefix of the capture —
/// the same semantics as CaptureMap's right-to-left dotted walk, evaluated
/// once at configure time instead of per capture hit.
const APP_CAPTURES: &[(&str, &str)] = &[
    // Keywords
    ("keyword", "keyword"),
    ("conditional", "keyword"),
    ("repeat", "keyword"),
    ("include", "keyword"),
    ("import", "keyword"),
    ("exception", "keyword"),
    // Strings / characters
    ("string", "string"),
    ("character", "string"),
    ("string.special.key", "tagAttribute"), // JSON keys → tagAttribute-ish
    ("string.escape", "escape"),
    ("escape", "escape"),
    ("string.regexp", "regex"),
    // Comments
    ("comment", "comment"),
    // Numbers / constants
    ("number", "number"),
    ("float", "number"),
    ("boolean", "builtin"),
    ("constant", "constant"),
    ("constant.builtin", "builtin"),
    // Types / classes
    ("type", "type"),
    ("type.builtin", "builtin"),
    ("class", "type"),
    // Functions / methods
    ("function", "function"),
    ("method", "function"),
    ("function.call", "function"),
    ("function.builtin", "builtin"),
    ("function.macro", "function"),
    // Variables / parameters
    ("variable", "variable"),
    ("parameter", "variable"),
    ("property", "variable"),
    ("field", "variable"),
    // Attributes / annotations
    ("attribute", "attribute"),
    ("annotation", "attribute"),
    // Operators / punctuation
    ("operator", "operator"),
    ("punctuation", "punctuation"),
    ("punctuation.bracket", "punctuation"),
    ("punctuation.delimiter", "punctuation"),
    ("punctuation.special", "punctuation"),
    // Markup (markdown, etc.)
    ("text.title", "heading"),
    ("markup.heading", "heading"),
    ("text.uri", "link"),
    ("markup.link", "link"),
    ("markup.link.url", "link"),
    ("text.emphasis", "emphasis"),
    ("markup.italic", "emphasis"),
    ("text.strong", "strong"),
    ("markup.bold", "strong"),
    // XML / HTML
    ("tag", "tag"),
    ("tag.attribute", "tagAttribute"),
];

/// One highlighted run in the HOST's text model: `start`/`len` are UTF-16
/// code-unit offsets into the source, `kind` is a Swift `TokenKind` rawValue.
/// Runs are non-overlapping and in source order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Run {
    pub start: usize,
    pub len: usize,
    pub kind: String,
}

/// Wire request: `{text, lang}` where `lang` is the host's
/// `HighlightLanguage` rawValue (`"swift"`, `"json"`, `"csharp"`, …).
#[derive(Debug, Serialize, Deserialize)]
pub struct RunsRequest {
    pub text: String,
    pub lang: String,
}

/// Wire response. `supported == false` means this build has no grammar for
/// the requested `lang` — the host falls back to its own engine (an EMPTY
/// `runs` with `supported == true` is a real "no tokens" answer).
#[derive(Debug, Serialize, Deserialize)]
pub struct RunsResponse {
    pub supported: bool,
    pub runs: Vec<Run>,
}

/// Tokenise `src` as `lang` into app-contract runs (UTF-16 offsets, app
/// kind vocabulary). Best-effort like [`crate::highlight`]: grammar/query
/// failure yields an empty vec, never an error.
#[must_use]
pub fn runs_utf16(src: &str, lang: Lang) -> Vec<Run> {
    let (language, query) = lang.grammar();
    let mut config = match HighlightConfiguration::new(language, lang.name(), &query, "", "") {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let names: Vec<&str> = APP_CAPTURES.iter().map(|(n, _)| *n).collect();
    config.configure(&names);

    let mut hl = Highlighter::new();
    let events = match hl.highlight(&config, src.as_bytes(), None, |_| None) {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };

    let mut runs: Vec<Run> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    // Source events arrive in source order and partition the text, so a
    // single forward cursor converts byte offsets to UTF-16 in O(n) total.
    let mut cur_byte = 0usize;
    let mut cur_u16 = 0usize;
    for event in events {
        match event {
            Ok(HighlightEvent::HighlightStart(h)) => stack.push(h.0),
            Ok(HighlightEvent::HighlightEnd) => {
                stack.pop();
            }
            Ok(HighlightEvent::Source { start, end }) => {
                if start >= end {
                    continue;
                }
                // Advance the cursor to `start` (gap text), then measure the
                // span. Defensive `get`: a non-char-boundary offset (never
                // produced by a sane grammar) drops the span, not the doc.
                let Some(gap) = src.get(cur_byte..start) else { continue };
                cur_u16 += utf16_len(gap);
                cur_byte = start;
                let Some(body) = src.get(cur_byte..end) else { continue };
                let body_u16 = utf16_len(body);
                if let Some(&idx) = stack.last() {
                    if let Some(&(_, kind)) = APP_CAPTURES.get(idx) {
                        // Coalesce: tree-sitter may split one capture into
                        // several adjacent Source events.
                        match runs.last_mut() {
                            Some(prev)
                                if prev.kind == kind
                                    && prev.start + prev.len == cur_u16 =>
                            {
                                prev.len += body_u16;
                            }
                            _ => runs.push(Run {
                                start: cur_u16,
                                len: body_u16,
                                kind: kind.to_string(),
                            }),
                        }
                    }
                }
                cur_u16 += body_u16;
                cur_byte = end;
            }
            Err(_) => break,
        }
    }
    runs
}

fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// Wire entry: `{text, lang}` request frame → `{supported, runs}` response
/// frame. Exposed by `mdvcore_highlight_runs` (FFI) and `highlight_runs`
/// (mdv-serve) — capability bit `MDV_CAP_HIGHLIGHT`.
pub fn runs_wire(req_frame: &[u8]) -> Result<Vec<u8>, mdvcore_core::wire::WireFault> {
    let req: RunsRequest = mdvcore_core::wire::decode_frame(req_frame)?;
    let resp = match Lang::from_name(&req.lang) {
        Some(lang) => RunsResponse { supported: true, runs: runs_utf16(&req.text, lang) },
        None => RunsResponse { supported: false, runs: Vec::new() },
    };
    mdvcore_core::wire::encode_frame(&resp)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Independent UTF-16 oracle: std's encoder, NOT the module's
    /// `utf16_len` helper — the tests must fail if the helper regresses
    /// (the first teeth run caught a self-referential false green here).
    fn u16(s: &str) -> usize {
        s.encode_utf16().count()
    }

    /// The run covering the UTF-16 position of `needle` in `src`, by kind.
    fn kind_at(runs: &[Run], src: &str, needle: &str) -> Option<String> {
        let byte_at = src.find(needle)?;
        let u16_at = u16(&src[..byte_at]);
        runs.iter()
            .find(|r| r.start <= u16_at && u16_at < r.start + r.len)
            .map(|r| r.kind.clone())
    }

    #[test]
    fn app_vocabulary_distinguishes_builtin_from_constant() {
        // tree-sitter-rust tags integer literals @constant.builtin; the app
        // table maps that to "builtin" (CaptureMap parity) while a plain
        // @constant stays "constant" — the distinction the coarse TUI
        // TokenKind drops.
        let src = "fn main() { let x = 7; }";
        let runs = runs_utf16(src, Lang::Rust);
        assert!(!runs.is_empty());
        assert_eq!(kind_at(&runs, src, "7").as_deref(), Some("builtin"));
        assert_eq!(kind_at(&runs, src, "fn").as_deref(), Some("keyword"));
        assert_eq!(kind_at(&runs, src, "main").as_deref(), Some("function"));
    }

    #[test]
    fn runs_are_utf16_offsets_not_bytes() {
        // "é" = 2 bytes / 1 UTF-16 unit; "😀" = 4 bytes / 2 UTF-16 units.
        // If offsets were bytes, the string token would land 1+2 units late.
        let src = "const s = \"héllo 😀 x\";";
        let runs = runs_utf16(src, Lang::JavaScript);
        let string_run = runs
            .iter()
            .find(|r| r.kind == "string")
            .expect("the string literal must produce a run");
        // HARDCODED on purpose (teeth): "const s = " = 10 units; the
        // literal \"héllo 😀 x\" = 12 UTF-16 units but 15 BYTES (é=2B/1u,
        // 😀=4B/2u) — byte-offset output fails both asserts.
        assert_eq!(string_run.start, 10);
        assert_eq!(string_run.len, 12);
        // And the whole list stays ordered + non-overlapping in UTF-16 space.
        for w in runs.windows(2) {
            assert!(w[0].start + w[0].len <= w[1].start, "ordered, disjoint: {w:?}");
        }
    }

    #[test]
    fn runs_never_exceed_utf16_length_of_source() {
        let src = "let s = \"☕☕☕\" // café\n";
        let total = src.encode_utf16().count();
        for r in runs_utf16(src, Lang::Rust) {
            assert!(r.start + r.len <= total, "{r:?} exceeds {total}");
        }
    }

    /// TSK-410 class: the Swift engine never evaluates `#match?`/`#eq?`
    /// predicates, so TS/JS queries that constrain e.g. constructors to
    /// `^[A-Z]` mis-classified ordinary lowercase identifiers. The
    /// tree-sitter-highlight path DOES evaluate them.
    #[test]
    fn ts_lowercase_identifier_is_not_a_type_or_constructor() {
        let src = "const myThing = otherThing;";
        let runs = runs_utf16(src, Lang::TypeScript);
        let kind = kind_at(&runs, src, "myThing");
        assert_ne!(kind.as_deref(), Some("type"), "predicate must gate ^[A-Z]");
        assert_ne!(kind.as_deref(), Some("function"));
        // The uppercase-start identifier IS allowed to classify specially.
        let src2 = "const x = new Thing();";
        let runs2 = runs_utf16(src2, Lang::TypeScript);
        let kind2 = kind_at(&runs2, src2, "Thing");
        assert!(
            matches!(kind2.as_deref(), Some("function" | "type" | "constant")),
            "uppercase identifier should classify via the predicate path, got {kind2:?}"
        );
    }

    #[test]
    fn wire_round_trip_supported_language() {
        let frame = mdvcore_core::wire::encode_frame(&RunsRequest {
            text: "fn main() {}".into(),
            lang: "rust".into(),
        })
        .expect("encode");
        let out = runs_wire(&frame).expect("runs_wire");
        let resp: RunsResponse = mdvcore_core::wire::decode_frame(&out).expect("decode");
        assert!(resp.supported);
        assert!(!resp.runs.is_empty());
        assert!(resp.runs.iter().any(|r| r.kind == "keyword"));
    }

    #[test]
    fn wire_unsupported_language_reports_unsupported_not_empty() {
        let frame = mdvcore_core::wire::encode_frame(&RunsRequest {
            text: "anything".into(),
            lang: "plain".into(),
        })
        .expect("encode");
        let out = runs_wire(&frame).expect("runs_wire");
        let resp: RunsResponse = mdvcore_core::wire::decode_frame(&out).expect("decode");
        assert!(!resp.supported, "'plain' is the forever-unsupported host rawValue");
        assert!(resp.runs.is_empty());
    }

    #[test]
    fn wire_malformed_frame_is_a_fault_not_a_panic() {
        assert!(runs_wire(&[0xFF, 0x00]).is_err());
    }

    #[test]
    fn lang_from_name_accepts_host_raw_values() {
        assert_eq!(Lang::from_name("swift"), Some(Lang::Swift));
        assert_eq!(Lang::from_name("csharp"), Some(Lang::CSharp));
        assert_eq!(Lang::from_name("c_sharp"), Some(Lang::CSharp));
        assert_eq!(Lang::from_name("TSX"), Some(Lang::Tsx));
        // Stage 3 additions resolve; "shell" is the host's rawValue.
        assert_eq!(Lang::from_name("yaml"), Some(Lang::Yaml));
        assert_eq!(Lang::from_name("shell"), Some(Lang::Bash));
        assert_eq!(Lang::from_name("markdown"), Some(Lang::Markdown));
        assert_eq!(Lang::from_name("plain"), None);
    }
}
