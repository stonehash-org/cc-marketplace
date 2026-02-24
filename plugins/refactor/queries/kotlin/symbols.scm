; Kotlin symbol queries

; Property declarations (val/var)
(property_declaration
  (variable_declaration
    (simple_identifier) @symbol.definition))

; Function declarations
(function_declaration
  (simple_identifier) @symbol.definition)

; Class declarations
(class_declaration
  (type_identifier) @symbol.definition)

; Object declarations
(object_declaration
  (type_identifier) @symbol.definition)

; Class parameters (constructor params)
(class_parameter
  (simple_identifier) @symbol.parameter)

; Function parameters
(parameter
  (simple_identifier) @symbol.parameter)

; Type references
(user_type
  (type_identifier) @symbol.type_reference)

; Import declarations
(import_header
  (identifier
    (simple_identifier) @symbol.import) .)

; All identifier references
(simple_identifier) @symbol.reference

; String literals (EXCLUDE)
(string_literal) @string.content

; Comments (EXCLUDE)
(line_comment) @comment.content
(multiline_comment) @comment.content
