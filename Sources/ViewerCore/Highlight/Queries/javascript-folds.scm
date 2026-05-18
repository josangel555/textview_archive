; Folds for JavaScript / JSX.
;
; tree-sitter-javascript exposes `statement_block` for `{ ... }` and
; named container nodes for objects/arrays/classes. We fold the
; container directly; the start/end punctuation lives inside the
; node, which is what we want for the ellipsis.

(statement_block)   @fold.function
(class_body)        @fold.type
(object)            @fold.object
(array)             @fold.array
(object_pattern)    @fold.object
(array_pattern)     @fold.array
(jsx_element)       @fold.element
(template_string)   @fold.stringLiteral
(comment)           @fold.comment
