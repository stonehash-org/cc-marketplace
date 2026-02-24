; Java inheritance queries

; Class extends
(class_declaration
  name: (identifier) @class.name
  (superclass
    (type_identifier) @class.extends))

; Class implements
(class_declaration
  name: (identifier) @class.name
  (super_interfaces
    (type_list
      (type_identifier) @class.implements)))

; Interface extends
(interface_declaration
  name: (identifier) @interface.name
  (extends_interfaces
    (type_list
      (type_identifier) @interface.extends)))
