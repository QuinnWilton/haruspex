# Refactor: unified elaboration and type checking

**Depends on**: refactor-whnf, refactor-ncase-closures (recommended but not strictly required)
**Blocks**: refactor-motive, refactor-pipeline-collapse
**Priority**: high — root cause of most architectural friction

## Problem

Haruspex has a two-phase pipeline: `Elaborate` (surface AST → core terms) then `Check` (core terms → typed core terms). In modern dependently typed compilers (Agda, Lean 4, Idris 2, elaboration-zoo), these are the **same pass**. The split causes:

1. **Implicit reinsertion.** `Elaborate` cannot insert implicit arguments because it has no type information. The checker must re-discover and insert implicits via `peel_implicit_pis` (constructors) and `peel_implicit_apps` (function calls). This is fragile, duplicates logic, and required three separate fixes during GADT work.

2. **Meta state discontinuity.** `Elaborate` creates its own MetaState for holes. `Check` creates a separate one. Metas from elaboration don't survive to checking — they're serialized as `{:meta, id}` core terms that reference a dead meta state. This caused crashes during GADT development.

3. **Self-reference hack.** `collect_total_defs` must `Core.subst(body, 0, {:def_ref, name})` to fix the self-reference that was valid during checking (where the def name is in context) but invalid during type-level reduction (where it isn't).

4. **`@implicit` pipeline wiring.** Auto-implicit declarations had to be threaded through FileInfo entity storage, loaded in `make_elaborate_ctx`, and applied via `resolve_auto_implicits` before elaboration — a pipeline concern that wouldn't exist if the elaborator had type information.

5. **Imprecise error locations.** Type errors are reported from the checker's perspective on core terms, not from the surface AST with source spans.

## Standard approach

In elaboration-zoo style systems, the function `elaborate(ctx, surface_term)` returns `{core_term, type}` in a single pass:

1. Surface names are resolved (scope checking)
2. Implicit arguments are inserted (metas created and applied) using type information
3. Types are evaluated (NbE) as terms are elaborated
4. Terms are checked/inferred against types
5. Metas are solved by unification
6. The output is a fully elaborated, type-correct core term

One MetaState is threaded through the entire process. No serialization boundary.

## Proposed solution

Merge `Elaborate` and `Check` into a single unified elaboration pass. The new module (call it `Elaborate` or `Elab`) takes surface AST and produces fully typed core terms with all metas solved.

### Phase 1: Restructure Elaborate to call Check

Rather than a full rewrite, the first step is to have `Elaborate.elaborate/2` call into `Check.synth` and `Check.check` at the appropriate points:

- `elaborate({:var, span, name})` → resolve name, then `Check.synth` if needed
- `elaborate({:app, span, func, args})` → elaborate func, get its type, use the type to determine implicit insertion, elaborate args with `Check.check`
- `elaborate({:ann, span, expr, type})` → elaborate type, eval it, elaborate expr with `Check.check` against the eval'd type
- `elaborate({:fn, span, params, body})` → build Pi type, elaborate body with `Check.check`

This requires `Elaborate` to carry a `Check.t()` context alongside its own context, sharing the MetaState.

### Phase 2: Eliminate the separate Check pass

Once Elaborate calls Check internally, the external `haruspex_check` query becomes trivial — it just runs the unified elaborate query and post-processes. `peel_implicit_pis`, `peel_implicit_apps`, and the `collect_total_defs` hack can be removed.

### Phase 3: Clean up

- Remove `Check.synth` for `{:con, ...}` implicit insertion (now handled by Elaborate)
- Remove `Check.synth` for `{:app, ...}` implicit insertion (same)
- Simplify `make_elaborate_ctx` — no more separate implicit wiring
- Collapse `haruspex_elaborate` and `haruspex_check` into one Roux query

## What stays the same

- `Eval`, `Quote`, `Unify`, `MetaState` — unchanged, they're already correct
- `Core` term representation — unchanged
- `Value` representation — unchanged
- `Context` — may need minor extensions but fundamentally sound
- `ADT`, `Record`, `TypeClass` — declaration elaboration stays separate (it doesn't need the unified pass)
- `Pattern` — exhaustiveness checking stays the same
- Roux query for `haruspex_elaborate_types` — stays separate (type decls are independent of value-level checking)

## Scope

This is a **large** change. The Elaborate module is ~1600 lines and would need significant restructuring. The Check module is ~1200 lines, parts of which would move into Elaborate. Estimated 2-3 focused sessions.

However, it eliminates the root cause of the most complex bugs encountered during GADT development and makes every future feature (higher-kinded types, universe polymorphism improvements, dependent records) significantly easier.

## Files to modify

| File | Change |
|------|--------|
| `lib/haruspex/elaborate.ex` | Restructure to call Check, share MetaState |
| `lib/haruspex/check.ex` | Remove implicit insertion workarounds, simplify |
| `lib/haruspex.ex` | Collapse elaborate+check queries, remove collect_total_defs hack |
| `lib/haruspex/file_info.ex` | May simplify (no separate implicit_decls needed) |

## Testing

- All existing tests must continue to pass
- The pipeline tests (module_test, reduction_gate_test, etc.) are the critical integration tests
- The GADT/Vec tests exercise the most complex paths

## Verification

```bash
mix test
mix test --cover  # must stay above 95%
mix format --check-formatted
mix dialyzer
```
