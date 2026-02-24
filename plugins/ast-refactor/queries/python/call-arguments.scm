; Python call site queries

; Function call
(call
  function: (identifier) @call.name
  arguments: (argument_list) @call.arguments)

; Method call
(call
  function: (attribute
    attribute: (identifier) @call.name)
  arguments: (argument_list) @call.arguments)
