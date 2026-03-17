# Fix: type declarations inside mutual blocks crash collect_top_level

**Priority**: high — crashes LSP on any file with mutual inductive types

## Problem

`collect_top_level/3` (line 526) handles mutual blocks by reducing over the
block's children, but the inner `Enum.reduce` only matches `:def` forms. When
a mutual block contains `:type_decl` forms (mutual inductive types), there is
no matching clause and the function crashes.

## Affected files

- test/examples/ambiguity_probe.hx (mutual block with `type Even`, `type Odd`)

## Fix

Add clauses in the mutual block handler for `:type_decl` (and potentially
`:record_decl`). Type declarations inside mutual blocks should be collected
into `tds` the same way top-level type declarations are, and the mutual group
should track their names for cross-reference resolution.
