; Python symbol queries

; Variable assignments
(assignment left: (identifier) @symbol.definition)

; Function definitions
(function_definition name: (identifier) @symbol.definition)

; Class definitions
(class_definition name: (identifier) @symbol.definition)

; Parameter names
(parameters (identifier) @symbol.parameter)
(default_parameter name: (identifier) @symbol.parameter)
(typed_parameter (identifier) @symbol.parameter)

; Decorator
(decorator (identifier) @symbol.reference)

; Import names
(import_from_statement name: (dotted_name (identifier) @symbol.import))
(aliased_import name: (dotted_name (identifier) @symbol.import))

; All identifier references
(identifier) @symbol.reference

; String literals (EXCLUDE)
(string) @string.content

; Comments (EXCLUDE)
(comment) @comment.content
