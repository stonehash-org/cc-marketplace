; block-range.scm — TypeScript / JavaScript
; Captures function and method boundaries so extract-function.sh can
; determine the enclosing scope for a given line range.
;
; Captures:
;   @block.name  — the identifier naming the function / method
;   @block.body  — the statement_block node (start/end rows = scope boundary)

; Named function declarations
;   function foo(...) { ... }
(function_declaration
  name: (identifier) @block.name
  body: (statement_block) @block.body)

; Class method definitions
;   class C { foo(...) { ... } }
(method_definition
  name: (property_identifier) @block.name
  body: (statement_block) @block.body)

; Standalone arrow functions with a block body
;   (...) => { ... }
(arrow_function
  body: (statement_block) @block.body)

; Arrow functions assigned to a const/let/var binding
;   const foo = (...) => { ... }
;   let   foo = (...) => { ... }
(lexical_declaration
  (variable_declarator
    name: (identifier) @block.name
    value: (arrow_function
      body: (statement_block) @block.body)))
