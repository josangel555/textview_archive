; Folds for Swift (alex-pinkus/tree-sitter-swift node names).
;
; Strategy: fold the *body* nodes — `{ ... }` blocks belonging to
; function / type / control-flow declarations — plus multi-line string
; literals and block comments. Folding the parent declaration would
; include the signature in the folded range, which reads weirdly.
;
; If any of these node names disappear in an upstream grammar bump,
; the engine's name-not-found path emits nothing for that capture;
; remaining captures keep working (Query.execute won't throw on a
; partial match against a node-type we no longer know — we filter
; unknown node names at engine layer too).

; Function / type bodies. `function_body` is the wrapping `{...}`.
(function_body) @fold.function

(class_body)       @fold.type
(enum_class_body)  @fold.type
(protocol_body)    @fold.type

; Statement blocks (if/for/while/do/switch). The grammar emits
; `statements` inside the surrounding `{}`; fold the wrapping block.
(if_statement (statements) @fold.other)
(for_statement (statements) @fold.other)
(while_statement (statements) @fold.other)
(do_statement (statements) @fold.other)
(switch_statement) @fold.other

; Multi-line string literals: only the triple-quoted variant has
; node-kind `multiline_string_literal` in alex-pinkus.
(multiline_string_literal) @fold.stringLiteral

; Block comments. Line-comment runs are not folded (no AST node
; bundles them); a future "comment run" pass can do it heuristically.
((comment) @fold.comment)
