//! Code-fold region computation (TSK-1202 — port of the Swift
//! `TreeSitterEngine+Folds.swift`, slice 1: the engine + non-markdown languages).
//!
//! The Swift engine runs a per-language fold `.scm` query and emits one region
//! per match. Those queries are PURE node-kind matches (no predicates, no field
//! constraints — see `Sources/ViewerCore/Highlight/Queries/*-folds.scm`), so we
//! replicate them as a Rust `(lang, node_kind) -> FoldKind` map and a single
//! pre-order tree walk. That deliberately avoids the `tree-sitter` raw `Query` /
//! `StreamingIterator` path (and its extra dep) for an equivalent, simpler port.
//!
//! Markdown's heading-span folds are a separate post-pass (slice 2); markdown is
//! intentionally NOT in the kind map yet.

use crate::Lang;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use tree_sitter::{Node, Parser};

/// The fold category, mirroring `FoldRegion.Kind` on the Swift side. Only the
/// kinds reachable from the languages ported so far are listed; markdown's
/// `heading`/`codeFence` and any `other` land with their languages.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FoldKind {
    Object,
    Array,
    Function,
    Type,
    Element,
    StringLiteral,
    Comment,
    /// A markdown ``` fenced code block.
    CodeFence,
    /// A markdown heading → span to the next heading of equal-or-lower level.
    Heading,
    /// A generic ≥2-line container we recognise (control-flow blocks, etc.).
    Other,
}

impl FoldKind {
    /// The Swift `FoldRegion.Kind` rawValue — the wire contract string. Kept in
    /// exact sync with `Sources/ViewerCore/Highlight/FoldRegion.swift`.
    fn raw_value(self) -> &'static str {
        match self {
            FoldKind::Object => "object",
            FoldKind::Array => "array",
            FoldKind::Function => "function",
            FoldKind::Type => "type",
            FoldKind::Element => "element",
            FoldKind::StringLiteral => "stringLiteral",
            FoldKind::Comment => "comment",
            FoldKind::CodeFence => "codeFence",
            FoldKind::Heading => "heading",
            FoldKind::Other => "other",
        }
    }

    /// Inverse of [`FoldKind::raw_value`]; `None` for an unknown rawValue.
    fn from_raw(s: &str) -> Option<FoldKind> {
        Some(match s {
            "object" => FoldKind::Object,
            "array" => FoldKind::Array,
            "function" => FoldKind::Function,
            "type" => FoldKind::Type,
            "element" => FoldKind::Element,
            "stringLiteral" => FoldKind::StringLiteral,
            "comment" => FoldKind::Comment,
            "codeFence" => FoldKind::CodeFence,
            "heading" => FoldKind::Heading,
            "other" => FoldKind::Other,
            _ => return None,
        })
    }
}

/// A foldable region: a 1-based, inclusive line span (matching the Swift
/// `FoldRegion`) plus its kind. Single-line nodes never produce a region.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoldRegion {
    pub start_line: usize,
    pub end_line: usize,
    pub kind: FoldKind,
}

// Wire shape: a positional `(start_line, end_line, kind_rawvalue)` tuple — the
// same compact, teeth-y contract as `runs::Run` (NOT a named map).
impl Serialize for FoldRegion {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeTuple;
        let mut t = serializer.serialize_tuple(3)?;
        t.serialize_element(&self.start_line)?;
        t.serialize_element(&self.end_line)?;
        t.serialize_element(self.kind.raw_value())?;
        t.end()
    }
}

impl<'de> Deserialize<'de> for FoldRegion {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let (start_line, end_line, kind) =
            <(usize, usize, String)>::deserialize(deserializer)?;
        let kind = FoldKind::from_raw(&kind)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown fold kind: {kind}")))?;
        Ok(FoldRegion { start_line, end_line, kind })
    }
}

/// Maps a `(language, node)` to a fold kind — the Rust encoding of the
/// per-language fold `.scm` queries. Most rules are pure node-kind matches; the
/// Swift control-flow rules are parent-constrained (a `statements` node folds
/// only inside if/for/while/do), which is why this takes the `Node` (for
/// `parent()`), not just its kind. `None` = the node is not foldable.
fn fold_kind(lang: Lang, node: Node) -> Option<FoldKind> {
    let kind = node.kind();
    match lang {
        // json-folds.scm
        Lang::Json => match kind {
            "object" => Some(FoldKind::Object),
            "array" => Some(FoldKind::Array),
            _ => None,
        },
        // javascript-folds.scm (JS / JSX)
        Lang::JavaScript => match kind {
            "statement_block" => Some(FoldKind::Function),
            "class_body" => Some(FoldKind::Type),
            "object" | "object_pattern" => Some(FoldKind::Object),
            "array" | "array_pattern" => Some(FoldKind::Array),
            "jsx_element" => Some(FoldKind::Element),
            "template_string" => Some(FoldKind::StringLiteral),
            "comment" => Some(FoldKind::Comment),
            _ => None,
        },
        // typescript-folds.scm (TS; tree-sitter-typescript also backs TSX)
        Lang::TypeScript => match kind {
            "statement_block" => Some(FoldKind::Function),
            "class_body" | "interface_body" | "object_type" | "enum_body" => {
                Some(FoldKind::Type)
            }
            "object" | "object_pattern" => Some(FoldKind::Object),
            "array" | "array_pattern" => Some(FoldKind::Array),
            "template_string" => Some(FoldKind::StringLiteral),
            "comment" => Some(FoldKind::Comment),
            _ => None,
        },
        // xml-folds.scm
        Lang::Xml => match kind {
            "element" => Some(FoldKind::Element),
            _ => None,
        },
        // swift-folds.scm
        Lang::Swift => match kind {
            "function_body" => Some(FoldKind::Function),
            "class_body" | "enum_class_body" | "protocol_body" => Some(FoldKind::Type),
            "switch_statement" => Some(FoldKind::Other),
            "multiline_string_literal" => Some(FoldKind::StringLiteral),
            "comment" => Some(FoldKind::Comment),
            // A `statements` block folds only inside a control-flow construct
            // (otherwise it double-folds function/closure bodies, etc.).
            "statements" => match node.parent().map(|p| p.kind()) {
                Some("if_statement" | "for_statement" | "while_statement" | "do_statement") => {
                    Some(FoldKind::Other)
                }
                _ => None,
            },
            _ => None,
        },
        // markdown-folds.scm (atx_heading is the special span post-pass below)
        Lang::Markdown => match kind {
            "fenced_code_block" => Some(FoldKind::CodeFence),
            _ => None,
        },
        _ => None,
    }
}

/// Computes the fold regions for `text` in `lang`. Returns an empty vec for a
/// language with no fold support or a parse failure.
pub fn fold_regions(text: &str, lang: Lang) -> Vec<FoldRegion> {
    let mut parser = Parser::new();
    if parser.set_language(&lang.grammar().0).is_err() {
        return Vec::new();
    }
    let Some(tree) = parser.parse(text, None) else {
        return Vec::new();
    };

    // Total line count for the trailing-fold clamp (matches the Swift counter:
    // newlines + 1, so a file not ending in `\n` still counts its last chunk).
    let total_lines = text.bytes().filter(|&b| b == b'\n').count() + 1;

    let mut out = Vec::new();
    // Markdown headings are single-line nodes folded as a span to the next
    // heading of equal-or-lower level — collected here, materialised below.
    let mut headings: Vec<(usize, usize)> = Vec::new();

    let mut cursor = tree.root_node().walk();
    'walk: loop {
        let node = cursor.node();
        if lang == Lang::Markdown && node.kind() == "atx_heading" {
            let line = node.start_position().row + 1;
            headings.push((line, atx_level(text, line)));
        } else if let Some(kind) = fold_kind(lang, node) {
            let start = node.start_position().row + 1;
            let mut end = node.end_position().row + 1;
            // When the node ends exactly at a line boundary (column 0), the row
            // points one past the node's last visual line — back off so a `}` at
            // the start of line N+1 doesn't claim it (mirrors the Swift fix-up).
            if node.end_position().column == 0 && end > start {
                end -= 1;
            }
            if end > start {
                out.push(FoldRegion {
                    start_line: start,
                    end_line: end.min(total_lines),
                    kind,
                });
            }
        }
        // Pre-order DFS over the whole tree via the cursor.
        if cursor.goto_first_child() {
            continue 'walk;
        }
        loop {
            if cursor.goto_next_sibling() {
                continue 'walk;
            }
            if !cursor.goto_parent() {
                break 'walk;
            }
        }
    }

    // Materialise heading folds: each spans to the line before the next heading
    // at level <= its own, else to EOF (mirrors the Swift post-pass).
    headings.sort_by_key(|&(line, _)| line);
    for (i, &(line, level)) in headings.iter().enumerate() {
        let mut end = total_lines;
        for &(next_line, next_level) in &headings[i + 1..] {
            if next_level <= level {
                end = next_line - 1;
                break;
            }
        }
        if end > line {
            out.push(FoldRegion { start_line: line, end_line: end, kind: FoldKind::Heading });
        }
    }

    // Dedup identical (start,end,kind) regions — nested grammars can capture the
    // same range twice — then sort start ASC / end DESC so outer folds precede
    // inner (mirrors the Swift tail).
    let mut seen = std::collections::HashSet::new();
    out.retain(|r| seen.insert((r.start_line, r.end_line, r.kind)));
    out.sort_by(|a, b| a.start_line.cmp(&b.start_line).then(b.end_line.cmp(&a.end_line)));
    out
}

/// ATX heading level = the count of leading `#` on the heading's first line
/// (after any indentation). Mirrors the Swift `atxHeadingLevel`.
fn atx_level(text: &str, line: usize) -> usize {
    text.lines()
        .nth(line - 1)
        .map(|l| l.trim_start().bytes().take_while(|&b| b == b'#').count())
        .unwrap_or(0)
}

/// Wire request: `{text, lang}` where `lang` is the host's `HighlightLanguage`
/// rawValue — mirrors [`crate::runs::RunsRequest`].
#[derive(Debug, Serialize, Deserialize)]
pub struct FoldsRequest<'a> {
    /// The source text to compute folds for.
    #[serde(borrow)]
    pub text: Cow<'a, str>,
    /// Host `HighlightLanguage` rawValue.
    pub lang: String,
}

/// Wire response. `supported == false` ⇒ this build has no grammar for `lang`
/// (the host keeps its own engine); an empty `regions` with `supported == true`
/// is a real "no folds" answer.
#[derive(Debug, Serialize, Deserialize)]
pub struct FoldsResponse {
    pub supported: bool,
    pub regions: Vec<FoldRegion>,
}

/// Wire entry: `{text, lang}` frame → `{supported, regions}` frame. The FFI /
/// mdv-serve fold export rides on this (capability bit `MDV_CAP_FOLDS`).
pub fn fold_regions_wire(req_frame: &[u8]) -> Result<Vec<u8>, mdvcore_core::wire::WireFault> {
    let req: FoldsRequest<'_> = mdvcore_core::wire::decode_frame_borrowed(req_frame)?;
    let resp = match Lang::from_name(&req.lang) {
        Some(lang) => FoldsResponse { supported: true, regions: fold_regions(&req.text, lang) },
        None => FoldsResponse { supported: false, regions: Vec::new() },
    };
    mdvcore_core::wire::encode_frame(&resp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_folds_object_and_array() {
        let src = "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}";
        let folds = fold_regions(src, Lang::Json);
        // Top-level object spans lines 1..7; the nested array spans 3..6.
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Object && f.start_line == 1),
            "object fold from line 1, got {folds:?}"
        );
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Array && f.start_line == 3),
            "array fold from line 3, got {folds:?}"
        );
    }

    #[test]
    fn javascript_folds_function_body() {
        let src = "function f() {\n  let x = 1;\n  return x;\n}";
        let folds = fold_regions(src, Lang::JavaScript);
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Function && f.start_line == 1),
            "statement_block fold from line 1, got {folds:?}"
        );
    }

    #[test]
    fn single_line_container_is_not_folded() {
        // endLine == startLine ⇒ skipped (a fold must hide ≥1 line).
        let folds = fold_regions("{\"a\": 1}", Lang::Json);
        assert!(folds.is_empty(), "single-line object must not fold, got {folds:?}");
    }

    #[test]
    fn unsupported_language_yields_no_folds() {
        let folds = fold_regions("fn main() {\n    let x = 1;\n}", Lang::Rust);
        assert!(folds.is_empty(), "rust has no fold map yet, got {folds:?}");
    }

    #[test]
    fn typescript_folds_interface_body_as_type() {
        let src = "interface Foo {\n  a: number;\n  b: string;\n}";
        let folds = fold_regions(src, Lang::TypeScript);
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Type && f.start_line == 1),
            "interface_body fold from line 1, got {folds:?}"
        );
    }

    #[test]
    fn xml_folds_element() {
        let src = "<root>\n  <child/>\n</root>";
        let folds = fold_regions(src, Lang::Xml);
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Element && f.start_line == 1),
            "element fold from line 1, got {folds:?}"
        );
    }

    #[test]
    fn swift_folds_function_body_and_control_flow_statements() {
        // function_body folds; the if's `statements` block folds as .other (the
        // parent-constrained rule), while a bare statements elsewhere would not.
        let src = "func f() {\n  if x {\n    a()\n    b()\n  }\n}";
        let folds = fold_regions(src, Lang::Swift);
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Function),
            "function_body fold, got {folds:?}"
        );
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Other),
            "if-statement statements fold as .other, got {folds:?}"
        );
    }

    #[test]
    fn markdown_folds_headings_by_level() {
        // Lines: 1 "# A", 2 intro, 3 "## B", 4 body, 5 "# C", 6 tail.
        let src = "# A\nintro\n## B\nbody\n# C\ntail";
        let folds = fold_regions(src, Lang::Markdown);
        // # A (h1) → line before the next h<=1 (# C @5) ⇒ 1..4.
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Heading && f.start_line == 1 && f.end_line == 4),
            "# A folds lines 1-4, got {folds:?}"
        );
        // ## B (h2) → next h<=2 is # C @5 ⇒ 3..4.
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::Heading && f.start_line == 3 && f.end_line == 4),
            "## B folds lines 3-4, got {folds:?}"
        );
    }

    #[test]
    fn markdown_folds_fenced_code_block() {
        let src = "text\n```\ncode\nmore\n```\n";
        let folds = fold_regions(src, Lang::Markdown);
        assert!(
            folds.iter().any(|f| f.kind == FoldKind::CodeFence),
            "fenced code block folds, got {folds:?}"
        );
    }

    #[test]
    fn regions_are_sorted_and_deduped() {
        // Outer object before inner array (start ASC); no duplicate (start,end,kind).
        let src = "{\n  \"a\": [\n    1\n  ]\n}";
        let folds = fold_regions(src, Lang::Json);
        for w in folds.windows(2) {
            assert!(
                w[0].start_line < w[1].start_line
                    || (w[0].start_line == w[1].start_line && w[0].end_line >= w[1].end_line),
                "not sorted: {folds:?}"
            );
        }
        let mut seen = std::collections::HashSet::new();
        for f in &folds {
            assert!(seen.insert((f.start_line, f.end_line, f.kind)), "dup region: {folds:?}");
        }
    }

    #[test]
    fn wire_round_trip_supported_language() {
        let frame = mdvcore_core::wire::encode_frame(&FoldsRequest {
            text: Cow::Borrowed("{\n  \"a\": 1,\n  \"b\": 2\n}"),
            lang: "json".into(),
        })
        .expect("encode");
        let out = fold_regions_wire(&frame).expect("wire");
        let resp: FoldsResponse = mdvcore_core::wire::decode_frame(&out).expect("decode");
        assert!(resp.supported);
        assert!(
            resp.regions.iter().any(|r| r.kind == FoldKind::Object && r.start_line == 1),
            "round-tripped object fold, got {:?}",
            resp.regions
        );
    }

    #[test]
    fn wire_unsupported_language_is_not_supported() {
        let frame = mdvcore_core::wire::encode_frame(&FoldsRequest {
            text: Cow::Borrowed("x"),
            lang: "no-such-lang".into(),
        })
        .expect("encode");
        let out = fold_regions_wire(&frame).expect("wire");
        let resp: FoldsResponse = mdvcore_core::wire::decode_frame(&out).expect("decode");
        assert!(!resp.supported);
        assert!(resp.regions.is_empty());
    }

    #[test]
    fn fold_kind_raw_values_round_trip() {
        // Every kind survives raw_value -> from_raw (the wire contract has teeth).
        for k in [
            FoldKind::Object, FoldKind::Array, FoldKind::Function, FoldKind::Type,
            FoldKind::Element, FoldKind::StringLiteral, FoldKind::Comment,
            FoldKind::CodeFence, FoldKind::Heading, FoldKind::Other,
        ] {
            assert_eq!(FoldKind::from_raw(k.raw_value()), Some(k));
        }
    }

    /// Robustness fuzz de-risking the pending `.fold` flip (TSK-1202): random
    /// source across every fold language must NEVER panic, and every region must
    /// be a valid 1-based span (start < end <= total_lines), sorted by start, and
    /// free of exact duplicates — the contract DocumentModel's gutter consumes.
    /// Merge gate runs a fixed seed; the nightly lane varies MDV_FUZZ_SEED_BASE.
    #[test]
    fn fold_regions_fuzz_invariants_across_languages() {
        let seed_base: u64 = std::env::var("MDV_FUZZ_SEED_BASE")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let langs = [
            Lang::Json, Lang::JavaScript, Lang::TypeScript, Lang::Xml, Lang::Swift, Lang::Markdown,
        ];
        let alpha: Vec<char> =
            "{}[]()<>\"'`/*-#;:=, \n\t日 func class struct fn let if for while interface enum"
                .chars()
                .collect();
        let mut s: u64 = seed_base.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };
        for _ in 0..600 {
            let len = (next() % 120) as usize;
            let text: String =
                (0..len).map(|_| alpha[(next() % alpha.len() as u64) as usize]).collect();
            let total = text.bytes().filter(|&b| b == b'\n').count() + 1;
            for &lang in &langs {
                let folds = fold_regions(&text, lang); // must not panic
                let mut prev_start = 0usize;
                let mut seen = std::collections::HashSet::new();
                for f in &folds {
                    assert!(f.start_line >= 1, "{lang:?}: start<1 {f:?} for {text:?}");
                    assert!(f.start_line < f.end_line, "{lang:?}: start>=end {f:?} for {text:?}");
                    assert!(f.end_line <= total, "{lang:?}: end>total({total}) {f:?} for {text:?}");
                    assert!(f.start_line >= prev_start, "{lang:?}: unsorted {folds:?} for {text:?}");
                    prev_start = f.start_line;
                    assert!(
                        seen.insert((f.start_line, f.end_line, f.kind)),
                        "{lang:?}: dup region {folds:?} for {text:?}"
                    );
                }
            }
        }
    }
}
