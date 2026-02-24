; block-range.scm — Kotlin
; Captures function boundaries for extract-function.

; Regular function declarations
(function_declaration
  (simple_identifier) @block.name
  (function_body) @block.body)
