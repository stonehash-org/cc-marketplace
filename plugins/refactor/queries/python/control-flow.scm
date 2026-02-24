; control-flow.scm — Python
; Captures control-flow nodes for complexity analysis.
;
; Captures:
;   @control.if            — if statements
;   @control.elif          — elif clauses
;   @control.for           — for loops
;   @control.while         — while loops
;   @control.try           — try statements
;   @control.except        — except clauses
;   @control.with          — with (context manager) statements
;   @control.ternary       — conditional expressions (ternary)
;   @control.and           — boolean 'and' operator
;   @control.or            — boolean 'or' operator
;   @control.comprehension — list comprehensions

(if_statement) @control.if
(elif_clause) @control.elif
(for_statement) @control.for
(while_statement) @control.while
(try_statement) @control.try
(except_clause) @control.except
(with_statement) @control.with
(conditional_expression) @control.ternary
(boolean_operator operator: "and") @control.and
(boolean_operator operator: "or") @control.or
(list_comprehension) @control.comprehension
