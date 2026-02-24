; TypeScript/JavaScript inheritance queries

; Class with extends
(class_declaration
  name: (type_identifier) @class.name
  (class_heritage
    (extends_clause
      value: (identifier) @class.extends)))

; Class with implements
(class_declaration
  name: (type_identifier) @class.name
  (class_heritage
    (implements_clause
      (type_identifier) @class.implements)))

; Interface extends
(interface_declaration
  name: (type_identifier) @interface.name
  (extends_type_clause
    (type_identifier) @interface.extends))
