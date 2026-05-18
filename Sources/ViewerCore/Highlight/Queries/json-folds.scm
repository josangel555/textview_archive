; Folds for JSON.
;
; tree-sitter-json node names from upstream grammar/grammar.js: `object`
; and `array` are the only multi-line containers worth folding. We emit
; both as `@fold` and bucket them by Swift-side kind based on the node
; name returned alongside the capture range.

(object) @fold.object
(array)  @fold.array
