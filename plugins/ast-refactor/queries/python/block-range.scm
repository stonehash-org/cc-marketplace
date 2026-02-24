; block-range.scm — Python
; Captures function and class boundaries so extract-function.sh can
; determine the enclosing scope for a given line range.
;
; Captures:
;   @block.name  — the identifier naming the function or class
;   @block.body  — the block node (start/end rows = scope boundary)

; Top-level and nested function definitions
;   def foo(...): ...
(function_definition
  name: (identifier) @block.name
  body: (block) @block.body)

; Class definitions (for method-level scope awareness)
;   class Foo: ...
(class_definition
  name: (identifier) @block.name
  body: (block) @block.body)
