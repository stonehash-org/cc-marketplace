; control-flow.scm — TypeScript / JavaScript
; Captures control-flow nodes for complexity analysis.
;
; Captures:
;   @control.if       — if statements
;   @control.else     — else clauses
;   @control.case     — switch case branches
;   @control.ternary  — ternary (conditional) expressions
;   @control.and      — short-circuit && expressions
;   @control.or       — short-circuit || expressions
;   @control.for      — for loops
;   @control.for_in   — for-in loops
;   @control.while    — while loops
;   @control.do       — do-while loops
;   @control.try      — try statements
;   @control.catch    — catch clauses

(if_statement) @control.if
(else_clause) @control.else
(switch_case) @control.case
(ternary_expression) @control.ternary
(binary_expression operator: "&&") @control.and
(binary_expression operator: "||") @control.or
(for_statement) @control.for
(for_in_statement) @control.for_in
(while_statement) @control.while
(do_statement) @control.do
(try_statement) @control.try
(catch_clause) @control.catch
