# Refactor: collapse elaborate + check Roux queries

**Depends on**: refactor-unified-elaboration
**Priority**: low — straightforward cleanup after the unified elaboration refactor

## Problem

The Roux pipeline has separate queries for elaboration and checking:

- `haruspex_elaborate` — elaborates surface AST to core terms, stores in entity fields
- `haruspex_check` — reads core terms from entity, type-checks them

Between these queries, core terms are serialized as plain data on Definition entities. This creates friction:

- Meta states don't flow across the query boundary
- `collect_total_defs` must post-process elaborated bodies with `Core.subst` to fix self-references
- The checker creates a separate context from scratch, duplicating work

## Proposed solution

After the unified elaboration refactor (where Elaborate calls Check internally), collapse `haruspex_elaborate` and `haruspex_check` into a single `haruspex_elaborate_and_check` query. The query takes a definition name, produces fully elaborated AND type-checked core, and stores the result.

Keep `haruspex_elaborate_types` separate — type declarations are genuinely independent of value-level checking and benefit from their own incremental query.

## Files to modify

| File | Change |
|------|--------|
| `lib/haruspex.ex` | Merge elaborate + check queries, remove `collect_total_defs` hack |

## Scope

Small (after the unified elaboration refactor is done).

## Verification

```bash
mix test
mix format --check-formatted
mix dialyzer
```
