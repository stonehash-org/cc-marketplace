; Java call site queries

; Method invocation
(method_invocation
  name: (identifier) @call.name
  arguments: (argument_list) @call.arguments)

; Object creation
(object_creation_expression
  type: (type_identifier) @call.name
  arguments: (argument_list) @call.arguments)
