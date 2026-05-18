; Folds for TypeScript (and TSX, same grammar). Mirrors JS folds plus
; a couple of TS-specific container nodes (interface/type bodies).

(statement_block)     @fold.function
(class_body)          @fold.type
(object)              @fold.object
(array)               @fold.array
(object_pattern)      @fold.object
(array_pattern)       @fold.array
(template_string)     @fold.stringLiteral
(comment)             @fold.comment

; TS-only: interface bodies and object type literals are useful folds
; for any non-trivial type definition.
(interface_body)         @fold.type
(object_type)            @fold.type
(enum_body)              @fold.type
