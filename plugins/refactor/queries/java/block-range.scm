; block-range.scm — Java
; Captures method and constructor boundaries so extract-function.sh can
; determine the enclosing scope for a given line range.
;
; Captures:
;   @block.name  — the identifier naming the method or constructor
;   @block.body  — the block node (start/end rows = scope boundary)

; Regular method declarations
;   public/private/... ReturnType methodName(...) { ... }
(method_declaration
  name: (identifier) @block.name
  body: (block) @block.body)

; Constructor declarations
;   ClassName(...) { ... }
(constructor_declaration
  name: (identifier) @block.name
  body: (block) @block.body)
