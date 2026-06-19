import Foundation

/// TSK-962 — Source(NSTextView/TreeSitter) ↔ Edit(CM6/Lezer) highlight parity.
///
/// The app paints syntax with two DIFFERENT tokenizers depending on the mode:
///
/// - **Source view** (`TextDisplayView`) tokenizes with TreeSitter (Swift
///   `TreeSitterEngine`, or Rust `tree-sitter-highlight` via
///   `RustHighlightAdapter`). Each TreeSitter capture name (`@keyword.control`,
///   `@string.escape`, …) is resolved to a `TokenKind` by `CaptureMap`, then to
///   a color by `SyntaxTheme.color(for:)`.
/// - **CM6 editor** (`CodeMirrorEditorView`) tokenizes IN JS with a Lezer
///   grammar. Each Lezer highlight tag (`t.keyword`, `t.escape`, …) is resolved
///   to a palette key — the `TokenKind` raw value — by the `paletteExtensions`
///   spec list in `Resources/codemirror/codemirror.html`, then colored by the
///   `SyntaxTheme.cmPalette` hex shipped over the `setTheme` bridge message.
///
/// COLOR parity (kind → hex) is already pinned: `cmPalette` is byte-equal to
/// `color(for:)` (`SyntaxThemeCMPaletteTests`). What was NOT pinned — and what
/// this type fixes — is the SCOPE → kind half: the two tokenizers' scope→kind
/// tables lived in two unrelated places (Swift `CaptureMap`, a hardcoded JS
/// literal) with no shared declaration and no cross-check. A new `TokenKind`
/// would be picked up by the Source path (via `CaptureMap`) yet silently never
/// emitted by the CM6 path (no Lezer tag mapped to it) — a real divergence with
/// no test teeth.
///
/// `HighlightScopeMap` is the single canonical declaration both paths derive
/// from. For every `TokenKind` it records:
///   - `captures`: the TreeSitter capture-name prefixes that resolve to it
///     (what `CaptureMap.table` held). The Source path's `CaptureMap` is now
///     BUILT from this table — one source of truth.
///   - `lezerTags`: the CodeMirror Lezer highlight-tag identifiers the CM6
///     `paletteExtensions` spec maps to this kind's palette key. The JS literal
///     is checked against this (see `HighlightParityHarness` + the
///     `ViewerUITests` drift test) so a JS edit that drops/renames a tag fails
///     the host gate.
///
/// Pure value type — no AppKit / WebKit. Host-testable from `ViewerCoreTests`.
public enum HighlightScopeMap {

    /// One canonical row: a semantic `TokenKind` and the per-tokenizer scope
    /// names that should resolve to it on each path.
    public struct Entry: Sendable, Equatable {
        public let kind: TokenKind
        /// TreeSitter capture-name prefixes (dotted; walked right-to-left by
        /// `CaptureMap.kind(forCapture:)`). Most-specific wins.
        public let captures: [String]
        /// CodeMirror Lezer highlight-tag identifiers, written exactly as they
        /// appear in `codemirror.html`'s `paletteExtensions` spec — including
        /// the modifier-call forms `t.function(t.variableName)`,
        /// `t.standard(t.variableName)`, `t.constant(t.variableName)`,
        /// `t.special(t.string)`. The drift test extracts these from the
        /// shipped HTML and diffs against this list.
        public let lezerTags: [String]

        public init(kind: TokenKind, captures: [String], lezerTags: [String]) {
            self.kind = kind
            self.captures = captures
            self.lezerTags = lezerTags
        }
    }

    /// The canonical table. Ordering mirrors the JS `paletteExtensions` spec so
    /// a reviewer can diff the two side-by-side. Every `TokenKind` appears
    /// exactly once (enforced by `HighlightParityHarness.coverage`).
    ///
    /// `captures` are the union of every capture prefix the TreeSitter queries
    /// emit that we color (was `CaptureMap.table`). `lezerTags` are the Lezer
    /// tags the CM6 host paints with this kind's palette color.
    public static let entries: [Entry] = [
        Entry(kind: .keyword,
              captures: ["keyword", "conditional", "repeat", "include",
                         "import", "exception"],
              lezerTags: ["t.keyword", "t.moduleKeyword", "t.controlKeyword",
                          "t.operatorKeyword", "t.definitionKeyword"]),
        Entry(kind: .string,
              captures: ["string", "character"],
              lezerTags: ["t.string", "t.special(t.string)", "t.docString",
                          "t.character"]),
        Entry(kind: .escape,
              captures: ["string.escape", "escape"],
              lezerTags: ["t.escape"]),
        Entry(kind: .regex,
              captures: ["string.regexp"],
              lezerTags: ["t.regexp"]),
        Entry(kind: .comment,
              captures: ["comment"],
              lezerTags: ["t.comment", "t.lineComment", "t.blockComment",
                          "t.docComment"]),
        Entry(kind: .number,
              captures: ["number", "float"],
              lezerTags: ["t.number", "t.integer", "t.float"]),
        Entry(kind: .type,
              captures: ["type", "class"],
              lezerTags: ["t.typeName", "t.className", "t.namespace"]),
        Entry(kind: .function,
              captures: ["function", "method", "function.call",
                         "function.macro"],
              lezerTags: ["t.function(t.variableName)",
                          "t.function(t.propertyName)", "t.macroName",
                          "t.labelName"]),
        Entry(kind: .variable,
              captures: ["variable", "parameter", "property", "field"],
              lezerTags: ["t.variableName", "t.propertyName", "t.name"]),
        Entry(kind: .attribute,
              captures: ["attribute", "annotation"],
              lezerTags: ["t.annotation", "t.meta"]),
        Entry(kind: .operator,
              captures: ["operator"],
              lezerTags: ["t.operator"]),
        Entry(kind: .punctuation,
              captures: ["punctuation", "punctuation.bracket",
                         "punctuation.delimiter", "punctuation.special"],
              lezerTags: ["t.punctuation", "t.separator", "t.bracket"]),
        Entry(kind: .builtin,
              captures: ["boolean", "constant.builtin", "type.builtin",
                         "function.builtin"],
              lezerTags: ["t.standard(t.variableName)", "t.self", "t.atom"]),
        Entry(kind: .constant,
              captures: ["constant"],
              lezerTags: ["t.constant(t.variableName)", "t.bool", "t.null"]),
        Entry(kind: .heading,
              captures: ["text.title", "markup.heading"],
              lezerTags: ["t.heading"]),
        Entry(kind: .link,
              captures: ["text.uri", "markup.link", "markup.link.url"],
              lezerTags: ["t.link", "t.url"]),
        Entry(kind: .emphasis,
              captures: ["text.emphasis", "markup.italic"],
              lezerTags: ["t.emphasis"]),
        Entry(kind: .strong,
              captures: ["text.strong", "markup.bold"],
              lezerTags: ["t.strong"]),
        Entry(kind: .tag,
              captures: ["tag"],
              lezerTags: ["t.tagName"]),
        Entry(kind: .tagAttribute,
              captures: ["tag.attribute", "string.special.key"],
              lezerTags: ["t.attributeName"]),
    ]

    /// `TreeSitter capture prefix → TokenKind`, derived from `entries`. This is
    /// the exact table `CaptureMap` now consumes — so the Source path and the
    /// canonical map can never drift.
    public static let captureTable: [String: TokenKind] = {
        var out: [String: TokenKind] = [:]
        for e in entries {
            for cap in e.captures { out[cap] = e.kind }
        }
        return out
    }()

    /// `TokenKind → Lezer tag identifiers` for the CM6 path, derived from
    /// `entries`. The canonical view the drift test diffs the shipped JS
    /// literal against.
    public static let lezerTagsByKind: [TokenKind: [String]] = {
        var out: [TokenKind: [String]] = [:]
        for e in entries { out[e.kind] = e.lezerTags }
        return out
    }()
}
