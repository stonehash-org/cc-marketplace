; TypeScript/JavaScript symbol queries

; Variable declarations
(variable_declarator name: (identifier) @symbol.definition)

; Function declarations
(function_declaration name: (identifier) @symbol.definition)

; Class declarations
(class_declaration name: (type_identifier) @symbol.definition)

; Interface declarations
(interface_declaration name: (type_identifier) @symbol.definition)

; Method definitions
(method_definition name: (property_identifier) @symbol.definition)

; Property assignments
(pair key: (property_identifier) @symbol.reference)

; Parameter names
(required_parameter (identifier) @symbol.parameter)
(optional_parameter (identifier) @symbol.parameter)

; Type references
(type_identifier) @symbol.type_reference

; Import specifiers
(import_specifier name: (identifier) @symbol.import)

; Export specifiers
(export_specifier name: (identifier) @symbol.export)

; All identifier references (general catch-all)
(identifier) @symbol.reference

; String literals (to EXCLUDE from renaming)
(string) @string.content
(template_string) @string.content

; Comments (to EXCLUDE from renaming)
(comment) @comment.content
