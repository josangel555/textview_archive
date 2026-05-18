; Folds for Markdown.
;
; The fenced code block node spans the opening fence through the
; closing fence inclusive, which is exactly the fold the user expects.
;
; Heading folds (collapse from an ATX heading to the line before the
; next heading at the same-or-higher level) aren't expressible as a
; single tree-sitter node range — they're spans between sibling
; headings. The engine post-processes `atx_heading` nodes into
; pseudo-fold regions instead. We still capture `atx_heading` here so
; the engine has a heading inventory without re-walking the tree.

(fenced_code_block) @fold.codeFence
(atx_heading)       @fold.heading
