; Assignment value captures for inline-variable (Kotlin)

; val/var declarations with initializer
(property_declaration
  (variable_declaration
    (simple_identifier) @variable.name)
  (_) @variable.value)
