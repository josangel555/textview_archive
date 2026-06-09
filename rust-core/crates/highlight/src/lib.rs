//! Source syntax highlighting for the rust-core front-ends (TSK-257).
//!
//! `highlight(src, lang)` tokenises source into a flat list of byte-range
//! [`Span`]s, each tagged with a normalised [`TokenKind`]. Front-ends map the
//! kind to their own palette (TUI → ratatui `Color`; web → a CSS class).
//!
//! The heavy lifting is `tree-sitter-highlight`: it runs the grammar's
//! `highlights.scm` query and emits `HighlightStart/Source/HighlightEnd`
//! events whose capture index points into the configured name list. We collapse
//! nested captures to the innermost (top of the stack), which is what a
//! span-based renderer wants.

use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// A normalised token category — the small, render-agnostic vocabulary the
/// front-ends colour. Maps from tree-sitter's finer-grained capture names
/// (e.g. `function.method` and `function.builtin` both fold to `Function`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    Keyword,
    String,
    Number,
    Comment,
    Function,
    Type,
    Constant,
    Variable,
    Property,
    Operator,
    Punctuation,
    Tag,
    Attribute,
    /// Recognised by the grammar but not in our palette → left unstyled.
    Other,
}

/// A highlighted byte range `[start, end)` of the source, half-open, tagged
/// with its [`TokenKind`]. Spans are non-overlapping and in source order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub kind: TokenKind,
}

/// A supported source language. `from_extension` maps a file extension to a
/// grammar; unknown extensions yield `None` (front-ends fall back to plain).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    Json,
    Rust,
    JavaScript,
}

impl Lang {
    /// Resolve a file extension (case-insensitive, no dot) to a grammar.
    #[must_use]
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext.to_ascii_lowercase().as_str() {
            "json" => Some(Self::Json),
            "rs" => Some(Self::Rust),
            "js" | "mjs" | "cjs" | "jsx" => Some(Self::JavaScript),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Rust => "rust",
            Self::JavaScript => "javascript",
        }
    }

    /// `(grammar language, highlights query source)` for this language.
    /// Note the JS grammar names its query `HIGHLIGHT_QUERY` (singular) while
    /// json/rust use `HIGHLIGHTS_QUERY`.
    fn grammar(self) -> (tree_sitter::Language, &'static str) {
        match self {
            Self::Json => (
                tree_sitter_json::LANGUAGE.into(),
                tree_sitter_json::HIGHLIGHTS_QUERY,
            ),
            Self::Rust => (
                tree_sitter_rust::LANGUAGE.into(),
                tree_sitter_rust::HIGHLIGHTS_QUERY,
            ),
            Self::JavaScript => (
                tree_sitter_javascript::LANGUAGE.into(),
                tree_sitter_javascript::HIGHLIGHT_QUERY,
            ),
        }
    }
}

/// The capture names we configure the highlighter with. A grammar capture not
/// in this list emits no highlight (the source stays unstyled / `Other`).
const HIGHLIGHT_NAMES: &[&str] = &[
    "attribute",
    "comment",
    "constant",
    "constant.builtin",
    "constructor",
    "escape",
    "function",
    "function.builtin",
    "function.method",
    "keyword",
    "label",
    "number",
    "operator",
    "property",
    "punctuation",
    "punctuation.bracket",
    "punctuation.delimiter",
    "string",
    "string.special",
    "tag",
    "type",
    "type.builtin",
    "variable",
    "variable.builtin",
    "variable.parameter",
];

/// Fold a tree-sitter capture name to our normalised [`TokenKind`].
fn kind_for_name(name: &str) -> TokenKind {
    if name.starts_with("keyword") {
        TokenKind::Keyword
    } else if name.starts_with("string") || name == "escape" {
        TokenKind::String
    } else if name == "number" {
        TokenKind::Number
    } else if name.starts_with("comment") {
        TokenKind::Comment
    } else if name.starts_with("function") || name == "constructor" {
        TokenKind::Function
    } else if name.starts_with("type") {
        TokenKind::Type
    } else if name.starts_with("constant") {
        TokenKind::Constant
    } else if name.starts_with("variable") {
        TokenKind::Variable
    } else if name == "property" {
        TokenKind::Property
    } else if name == "operator" {
        TokenKind::Operator
    } else if name.starts_with("punctuation") {
        TokenKind::Punctuation
    } else if name == "tag" {
        TokenKind::Tag
    } else if name == "attribute" || name == "label" {
        TokenKind::Attribute
    } else {
        TokenKind::Other
    }
}

/// Tokenise `src` as `lang` into highlight spans. Returns an empty vec if the
/// grammar/query fails to compile or the source can't be parsed — highlighting
/// is best-effort decoration, never a hard error for the caller.
#[must_use]
pub fn highlight(src: &str, lang: Lang) -> Vec<Span> {
    let (language, query) = lang.grammar();
    let mut config = match HighlightConfiguration::new(language, lang.name(), query, "", "") {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    config.configure(HIGHLIGHT_NAMES);

    let mut hl = Highlighter::new();
    let events = match hl.highlight(&config, src.as_bytes(), None, |_| None) {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };

    let mut spans = Vec::new();
    // Stack of active capture indices; the innermost (top) wins for the source
    // range emitted between Start/End so nested captures collapse cleanly.
    let mut stack: Vec<usize> = Vec::new();
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
                if let Some(&idx) = stack.last() {
                    if let Some(name) = HIGHLIGHT_NAMES.get(idx) {
                        let kind = kind_for_name(name);
                        if kind != TokenKind::Other {
                            spans.push(Span { start, end, kind });
                        }
                    }
                }
            }
            Err(_) => break,
        }
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `TokenKind` covering byte range containing `needle` in `src`.
    fn kind_at<'a>(spans: &[Span], src: &'a str, needle: &str) -> Option<TokenKind> {
        let at = src.find(needle)?;
        spans
            .iter()
            .find(|s| s.start <= at && at < s.end)
            .map(|s| s.kind)
    }

    #[test]
    fn from_extension_maps_known_languages() {
        assert_eq!(Lang::from_extension("json"), Some(Lang::Json));
        assert_eq!(Lang::from_extension("RS"), Some(Lang::Rust));
        assert_eq!(Lang::from_extension("mjs"), Some(Lang::JavaScript));
        assert_eq!(Lang::from_extension("txt"), None);
    }

    #[test]
    fn json_string_number_and_property_classified() {
        let src = r#"{"name": "ada", "age": 42}"#;
        let spans = highlight(src, Lang::Json);
        assert!(!spans.is_empty(), "json should produce spans");
        // The value string "ada" is a String; 42 is a Number; the "age" key is
        // a string/property depending on the query — assert the clear ones.
        assert_eq!(kind_at(&spans, src, "ada"), Some(TokenKind::String));
        assert_eq!(kind_at(&spans, src, "42"), Some(TokenKind::Number));
        // Spans are ordered + non-overlapping.
        for w in spans.windows(2) {
            assert!(w[0].start <= w[1].start, "spans in source order");
        }
    }

    #[test]
    fn rust_keyword_string_number_comment_classified() {
        let src = "fn main() {\n    let x = 7; // note\n    let s = \"hi\";\n}\n";
        let spans = highlight(src, Lang::Rust);
        assert!(!spans.is_empty(), "rust should produce spans");
        assert_eq!(kind_at(&spans, src, "fn"), Some(TokenKind::Keyword));
        assert_eq!(kind_at(&spans, src, "let"), Some(TokenKind::Keyword));
        // tree-sitter-rust tags integer literals `@constant.builtin` (Rust's
        // convention — a literal IS a constant), unlike json's `@number`. The
        // engine reports the grammar's classification faithfully; the front-end
        // palette can colour Constant and Number alike.
        assert_eq!(kind_at(&spans, src, "7"), Some(TokenKind::Constant));
        assert_eq!(kind_at(&spans, src, "// note"), Some(TokenKind::Comment));
        assert_eq!(kind_at(&spans, src, "\"hi\""), Some(TokenKind::String));
        // The fn name is captured as Function (def-site highlight).
        assert_eq!(kind_at(&spans, src, "main"), Some(TokenKind::Function));
    }

    #[test]
    fn javascript_keyword_and_string_classified() {
        let src = "const greeting = \"hello\";\nfunction f() { return 1; }\n";
        let spans = highlight(src, Lang::JavaScript);
        assert!(!spans.is_empty(), "js should produce spans");
        assert_eq!(kind_at(&spans, src, "const"), Some(TokenKind::Keyword));
        assert_eq!(kind_at(&spans, src, "\"hello\""), Some(TokenKind::String));
        assert_eq!(kind_at(&spans, src, "function"), Some(TokenKind::Keyword));
    }

    #[test]
    fn empty_source_yields_no_spans() {
        assert!(highlight("", Lang::Json).is_empty());
        assert!(highlight("", Lang::Rust).is_empty());
    }
}
