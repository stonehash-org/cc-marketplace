; Assignment value captures for inline-variable

(local_variable_declaration
  declarator: (variable_declarator
    name: (identifier) @variable.name
    value: (_) @variable.value))

(field_declaration
  declarator: (variable_declarator
    name: (identifier) @variable.name
    value: (_) @variable.value))
