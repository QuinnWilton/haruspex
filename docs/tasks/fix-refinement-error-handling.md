# Fix: refinement failure crashes instead of returning error tuple

**Priority**: medium — crashes LSP on files with refinement types that fail to verify

## Problem

When a refinement type check fails, the error `{:error, {:refinement_failed, pred, assumptions}}`
is not caught in the checker pipeline. Instead of propagating as an error
tuple, it hits a `case` or `with` clause that doesn't match and raises
`CaseClauseError`.

## Affected files

- test/examples/refinement.hx (`clamp` function with range refinement)

## Fix

Ensure the checker's refinement verification path returns `{:error, ...}`
tuples that propagate through `check_elaborated_def` back to the diagnostics
query. The `error_to_diagnostic` catch-all at line 738 will handle display.
