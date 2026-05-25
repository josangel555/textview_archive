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
} from "@codemirror/language";
import {
  linter, lintGutter, setDiagnostics, forEachDiagnostic, Diagnostic,
} from "@codemirror/lint";
import { markdown } from "@codemirror/lang-markdown";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { json } from "@codemirror/lang-json";
import { oneDark } from "@codemirror/theme-one-dark";

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
  foldKeymap, foldGutter, indentOnInput,
  indentUnit, foldAll, unfoldAll, EditorStateTabSize,
  foldService,
  linter, lintGutter, setDiagnostics, forEachDiagnostic,
  markdown, javascript, python, json, oneDark,
};
