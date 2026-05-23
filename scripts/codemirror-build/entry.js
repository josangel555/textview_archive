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
  EditorState, Compartment, EditorSelection,
} from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine,
  highlightActiveLineGutter, drawSelection, rectangularSelection,
  crosshairCursor, dropCursor,
} from "@codemirror/view";
import {
  defaultKeymap, history, historyKeymap, undo, redo,
  indentWithTab,
} from "@codemirror/commands";
import {
  searchKeymap, highlightSelectionMatches, openSearchPanel,
} from "@codemirror/search";
import {
  syntaxHighlighting, defaultHighlightStyle, bracketMatching,
  foldKeymap, foldGutter, indentOnInput,
} from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { json } from "@codemirror/lang-json";
import { oneDark } from "@codemirror/theme-one-dark";

// Re-export the surface the HTML host uses. No CommonJS, no globals
// beyond `window.CM` (set by esbuild --global-name).
export {
  EditorState, EditorView, EditorSelection, Compartment,
  keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter,
  drawSelection, rectangularSelection, crosshairCursor, dropCursor,
  defaultKeymap, history, historyKeymap, undo, redo, indentWithTab,
  searchKeymap, highlightSelectionMatches, openSearchPanel,
  syntaxHighlighting, defaultHighlightStyle, bracketMatching,
  foldKeymap, foldGutter, indentOnInput,
  markdown, javascript, python, json, oneDark,
};
