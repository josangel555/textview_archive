// Entry point bundled into Sources/ViewerUI/Resources/codemirror/codemirror.js.
// Exposes everything CodeMirror needs as `window.CM.*` via esbuild's
// --global-name=CM. The HTML host loaded by CodeMirrorEditorView.swift
// only references symbols off `CM` — keep that contract stable when
// editing this file.
//
// Re-bundle command (from scripts/codemirror-build/):
//   npm install --no-audit --no-fund
//   npm run build
//
// Outputs (committed to the repo):
//   Sources/ViewerUI/Resources/codemirror/codemirror.js
//   Sources/ViewerUI/Resources/codemirror/codemirror.css

import {
  EditorState, EditorSelection, Compartment, Transaction,
  StateField, StateEffect, RangeSetBuilder,
} from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine,
  highlightActiveLineGutter, drawSelection, rectangularSelection,
  crosshairCursor, dropCursor,
  Decoration, ViewPlugin, WidgetType,
  hoverTooltip, gutter, GutterMarker,
} from "@codemirror/view";
import {
  defaultKeymap, history, historyKeymap, undo, redo,
  indentWithTab,
} from "@codemirror/commands";
import {
  search, searchKeymap, highlightSelectionMatches,
  openSearchPanel, closeSearchPanel,
  findNext, findPrevious, replaceNext, replaceAll,
  setSearchQuery, SearchQuery, getSearchQuery,
} from "@codemirror/search";
import {
  syntaxHighlighting, defaultHighlightStyle, bracketMatching,
  foldKeymap, foldGutter, indentOnInput,
  indentUnit, foldAll, unfoldAll,
  foldService,
  HighlightStyle,
  // StreamLanguage wraps the legacy CodeMirror-5-style stream parsers
  // from @codemirror/legacy-modes (swift, kotlin, c#, lua, shell, yaml,
  // ruby) into CM6 LanguageSupport. Already in the bundle (it ships with
  // @codemirror/language) — re-exporting just surfaces it on window.CM.
  StreamLanguage,
} from "@codemirror/language";
// TSK-602 ViewOnly↔Editor color parity: the HTML host builds a
// HighlightStyle from the Swift SyntaxTheme palette, which needs the
// lezer tag objects. @lezer/highlight is ALREADY in the bundle (it
// defines defaultHighlightStyle + oneDark in terms of these tags) —
// re-exporting `tags` adds no new package, just surfaces it on window.CM.
import { tags } from "@lezer/highlight";
import {
  linter, lintGutter, setDiagnostics, forEachDiagnostic, Diagnostic,
} from "@codemirror/lint";
// TSK-1136: editor completion popup. Drives an async Swift-backed completion
// source (LSP or in-file fallback) via the WebView bridge. The package is
// already a build dep (package.json) — bundling adds no Swift runtime dep.
import { autocompletion, completionStatus, startCompletion } from "@codemirror/autocomplete";
import { markdown } from "@codemirror/lang-markdown";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { json } from "@codemirror/lang-json";
// TSK-1135: full-22-language editor highlighting via official Lezer packs.
// Each is a real Lezer grammar (tree-sitter-quality CM6 LanguageSupport,
// with folding / indent / bracket-matching where the pack provides it).
// lang-cpp's grammar also parses C; lang-html embeds lang-css + lang-js.
import { rust } from "@codemirror/lang-rust";
import { java } from "@codemirror/lang-java";
import { cpp } from "@codemirror/lang-cpp";
import { sql } from "@codemirror/lang-sql";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { xml } from "@codemirror/lang-xml";
import { go } from "@codemirror/lang-go";
// TSK-1135: languages without an official Lezer pack use the CM5-style
// stream parsers from @codemirror/legacy-modes, wrapped via StreamLanguage
// in the HTML host. Regex/stream tokenizers (coarser than Lezer trees, but
// they highlight correctly). kotlin + csharp are clike variants.
import { swift as swiftMode } from "@codemirror/legacy-modes/mode/swift";
import { lua as luaMode } from "@codemirror/legacy-modes/mode/lua";
import { shell as shellMode } from "@codemirror/legacy-modes/mode/shell";
import { yaml as yamlMode } from "@codemirror/legacy-modes/mode/yaml";
import { ruby as rubyMode } from "@codemirror/legacy-modes/mode/ruby";
import { kotlin as kotlinMode, csharp as csharpMode } from "@codemirror/legacy-modes/mode/clike";
import { oneDark } from "@codemirror/theme-one-dark";
// Vim mode (opt-in; owner-approved 2026-06-15). @replit/codemirror-vim 6.3.0,
// MIT, maintained by Replit. Bundles into codemirror.js — no runtime npm dep,
// same as every other @codemirror/* package here. Gated behind a Compartment in
// the HTML host (off by default; toggled via View → Vim Mode).
// `Vim` (defineEx — wire `:w` to the app's save) + `getCM` (the cm5-compat
// handle for `vim-mode-change` events → the footer mode indicator).
import { vim, Vim, getCM } from "@replit/codemirror-vim";

// EditorState.tabSize is a facet on the namespace object, not a named
// export. Re-export as `EditorStateTabSize` for use from the HTML host
// (where `EditorState` is destructured into a local).
const EditorStateTabSize = EditorState.tabSize;

// Re-export the surface the HTML host uses. No CommonJS, no globals
// beyond `window.CM` (set by esbuild --global-name).
export {
  EditorState, EditorView, EditorSelection, Compartment, Transaction,
  StateField, StateEffect, RangeSetBuilder,
  keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter,
  drawSelection, rectangularSelection, crosshairCursor, dropCursor,
  Decoration, ViewPlugin, WidgetType,
  hoverTooltip, gutter, GutterMarker,
  defaultKeymap, history, historyKeymap, undo, redo, indentWithTab,
  search, searchKeymap, highlightSelectionMatches,
  openSearchPanel, closeSearchPanel,
  findNext, findPrevious, replaceNext, replaceAll,
  setSearchQuery, SearchQuery, getSearchQuery,
  syntaxHighlighting, defaultHighlightStyle, bracketMatching,
  HighlightStyle, tags,
  foldKeymap, foldGutter, indentOnInput,
  indentUnit, foldAll, unfoldAll, EditorStateTabSize,
  foldService,
  StreamLanguage,
  linter, lintGutter, setDiagnostics, forEachDiagnostic,
  autocompletion, completionStatus, startCompletion,
  markdown, javascript, python, json, oneDark,
  // TSK-1135: official Lezer language packs.
  rust, java, cpp, sql, html, css, xml, go,
  // TSK-1135: legacy-mode stream parsers (wrapped via StreamLanguage in
  // the HTML host). Exported under their *Mode names to avoid colliding
  // with the Lezer pack names above.
  swiftMode, luaMode, shellMode, yamlMode, rubyMode, kotlinMode, csharpMode,
  vim, Vim, getCM,
};
