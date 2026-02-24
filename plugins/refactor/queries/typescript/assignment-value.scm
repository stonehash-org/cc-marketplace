; Assignment value captures for inline-variable

(lexical_declaration
  (variable_declarator
    name: (identifier) @variable.name
    value: (_) @variable.value))

(variable_declaration
  (variable_declarator
    name: (identifier) @variable.name
    value: (_) @variable.value))
