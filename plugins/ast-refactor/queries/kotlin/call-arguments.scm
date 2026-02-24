; Kotlin call site queries

; Function/method call
(call_expression
  (simple_identifier) @call.name
  (call_suffix
    (value_arguments) @call.arguments))

; Navigation call (obj.method())
(call_expression
  (navigation_expression
    (simple_identifier) @call.name)
  (call_suffix
    (value_arguments) @call.arguments))
