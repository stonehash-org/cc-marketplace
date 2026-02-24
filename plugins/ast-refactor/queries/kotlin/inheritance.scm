; Kotlin inheritance queries

; Class with superclass/interface via delegation_specifier
(class_declaration
  (type_identifier) @class.name
  (delegation_specifier
    (constructor_invocation
      (user_type
        (type_identifier) @class.extends))))

(class_declaration
  (type_identifier) @class.name
  (delegation_specifier
    (user_type
      (type_identifier) @class.implements)))
