# Refactor: closure-based ncase neutrals

**Depends on**: tier7-gadt (done)
**Blocks**: nothing directly, but simplifies refactor-motive
**Priority**: medium — clean standalone refactor

## Problem

Stuck case expressions are represented as:

```
{:ncase, neutral_scrutinee, [{con_name, arity, core_body}], captured_env}
```

The branches are **raw core terms** with de Bruijn indices relative to the captured env. This is unlike every other closure in the system (vlam, vpi, vsigma) which store `{env, body}` pairs. The shared `env` is separate from the branch bodies.

This causes problems:

1. `quote_neutral` must re-evaluate branch bodies with `Eval.default_ctx()` (empty metas and defs), losing information about total defs and solved metas.
2. The ncase neutral mixes core terms with values in the neutral spine, breaking the clean separation between the syntactic (Core) and semantic (Value) layers.
3. Unification on ncase neutrals (`unify_neutral` for `:ncase`) only compares scrutinee heads, ignoring branches entirely. This is sound but imprecise.

## Standard approach

In Agda/Idris, stuck eliminators store branches as closures — the same `{env, body}` pairs used for lambdas and Pi codomains. When readback needs to produce core from a stuck case, closures are opened with fresh variables, evaluated, and quoted — identical to how Pi codomains are read back.

## Proposed solution

Change the ncase neutral representation from:

```
{:ncase, neutral, [{con_name, arity, core_body}], shared_env}
```

to per-branch closures:

```
{:ncase, neutral, [{con_name, arity, {env, core_body}}]}
```

Each branch closure captures its own env (which is the eval context's env at the point the case got stuck). This is the same env for all branches in practice, but the representation is self-contained.

Then:
- `Eval.vcase` for neutral scrutinee: wraps each branch body with its env
- `Quote.quote_neutral` for ncase: opens closures with fresh vars (same as for vpi codomains), no `default_ctx()` needed
- `Unify.occurs_in_neutral?` and `scope_ok_neutral?` for ncase: can now inspect branch closures if needed

## Files to modify

| File | Change |
|------|--------|
| `lib/haruspex/value.ex` | Update neutral type for ncase |
| `lib/haruspex/eval.ex` | Update `vcase` neutral case to store per-branch closures |
| `lib/haruspex/quote.ex` | Update `quote_neutral` to open closures with fresh vars |
| `lib/haruspex/unify.ex` | Update `occurs_in_neutral?`, `scope_ok_neutral?`, `unify_neutral` for new shape |

## Testing

- All existing tests should pass (the behavior is the same, only the representation changes)
- Add a test for quoting a stuck case where branch bodies reference total defs

## Verification

```bash
mix test
mix format --check-formatted
mix dialyzer
```
