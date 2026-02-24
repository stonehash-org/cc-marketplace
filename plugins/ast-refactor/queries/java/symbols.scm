; Java symbol queries

; Variable declarations
(variable_declarator name: (identifier) @symbol.definition)

; Method declarations
(method_declaration name: (identifier) @symbol.definition)

; Class declarations
(class_declaration name: (identifier) @symbol.definition)

; Interface declarations
(interface_declaration name: (identifier) @symbol.definition)

; Formal parameters
(formal_parameter name: (identifier) @symbol.parameter)

; Type references
(type_identifier) @symbol.type_reference

; Import declarations
(import_declaration (scoped_identifier name: (identifier) @symbol.import))

; All identifier references
(identifier) @symbol.reference

; String literals (EXCLUDE)
(string_literal) @string.content

; Comments (EXCLUDE)
(line_comment) @comment.content
(block_comment) @comment.content
