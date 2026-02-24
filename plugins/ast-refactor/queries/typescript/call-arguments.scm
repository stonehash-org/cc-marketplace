; TypeScript/JavaScript call site queries

; Call expression with arguments
(call_expression
  function: (identifier) @call.name
  arguments: (arguments) @call.arguments)

; Method call
(call_expression
  function: (member_expression
    property: (property_identifier) @call.name)
  arguments: (arguments) @call.arguments)

; New expression
(new_expression
  constructor: (identifier) @call.name
  arguments: (arguments) @call.arguments)
