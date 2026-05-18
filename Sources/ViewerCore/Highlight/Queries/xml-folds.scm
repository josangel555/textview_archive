; Folds for XML.
;
; tree-sitter-xml exposes `element` for tag-delimited regions. We use
; `element` only — `STag/ETag` are start/end markers, not folds.
; Doctypes and CDATA sections are intentionally not folded; their
; one-line case is the common one.

(element) @fold.element
