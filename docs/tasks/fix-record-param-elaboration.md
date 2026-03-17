# Fix: record param elaboration crashes on parser tuple shape

**Priority**: high — crashes LSP on any file with parameterized records

## Problem

`Elaborate.elaborate_record_decl/2` (line 561) pattern-matches record type
parameters as `{param_name, kind_expr}`, but the parser produces
`{:param, span, {name, mult, erased?}, kind_expr}`.

Any file with a parameterized record (e.g. `record Wrapper(a : Type)`) raises
`FunctionClauseError` in the elaborator.

## Affected files

- test/examples/adversarial.hx (`record Wrapper(a : Type)`)
- test/examples/decl_edge.hx (`record Config(a : Type)`)

## Fix

Update the `Enum.reduce` callback at line 561 to destructure the `:param`
tuple shape the parser actually emits. Propagate `mult` and `erased?` if
needed, or extract just the name and kind for now.
