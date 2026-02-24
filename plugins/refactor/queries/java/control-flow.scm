; control-flow.scm — Java
; Captures control-flow nodes for complexity analysis.
;
; Captures:
;   @control.if       — if statements
;   @control.switch   — switch expressions
;   @control.for      — for loops
;   @control.for_each — enhanced for (for-each) loops
;   @control.while    — while loops
;   @control.do       — do-while loops
;   @control.try      — try statements
;   @control.catch    — catch clauses
;   @control.ternary  — ternary (conditional) expressions
;   @control.and      — short-circuit && expressions
;   @control.or       — short-circuit || expressions

(if_statement) @control.if
(switch_expression) @control.switch
(for_statement) @control.for
(enhanced_for_statement) @control.for_each
(while_statement) @control.while
(do_statement) @control.do
(try_statement) @control.try
(catch_clause) @control.catch
(ternary_expression) @control.ternary
(binary_expression operator: "&&") @control.and
(binary_expression operator: "||") @control.or
