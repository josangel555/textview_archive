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
use tree_sitter::Parser;

/// The fold category, mirroring `FoldRegion.Kind` on the Swift side. Only the
/// kinds reachable from the languages ported so far are listed; markdown's
/// `heading`/`codeFence` and any `other` land with their languages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoldKind {
    Object,
    Array,
    Function,
    Type,
    Element,
    StringLiteral,
    Comment,
}

/// A foldable region: a 1-based, inclusive line span (matching the Swift
/// `FoldRegion`) plus its kind. Single-line nodes never produce a region.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoldRegion {
    pub start_line: usize,
    pub end_line: usize,
    pub kind: FoldKind,
}

/// Maps a `(language, tree-sitter node kind)` to a fold kind — the Rust encoding
/// of the per-language fold `.scm` queries. `None` = the node is not foldable.
fn fold_kind(lang: Lang, node_kind: &str) -> Option<FoldKind> {
    match lang {
        // json-folds.scm
        Lang::Json => match node_kind {
            "object" => Some(FoldKind::Object),
            "array" => Some(FoldKind::Array),
            _ => None,
        },
        // javascript-folds.scm (JS / JSX)
        Lang::JavaScript => match node_kind {
            "statement_block" => Some(FoldKind::Function),
            "class_body" => Some(FoldKind::Type),
            "object" | "object_pattern" => Some(FoldKind::Object),
            "array" | "array_pattern" => Some(FoldKind::Array),
            "jsx_element" => Some(FoldKind::Element),
            "template_string" => Some(FoldKind::StringLiteral),
            "comment" => Some(FoldKind::Comment),
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
    let mut cursor = tree.root_node().walk();
    'walk: loop {
        let node = cursor.node();
        if let Some(kind) = fold_kind(lang, node.kind()) {
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
    out
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
}
