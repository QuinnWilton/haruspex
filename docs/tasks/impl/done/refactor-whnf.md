# Refactor: proper whnf with meta resolution

**Depends on**: tier7-gadt (done)
**Blocks**: refactor-unified-elaboration (simplifies it)
**Priority**: high — can be done independently, immediately improves correctness

## Problem

When metas in closure-captured envs get solved after the closure is created, the closures hold stale neutral values. The checker works around this with ad-hoc `forced_env = Enum.map(env, &MetaState.force(...))` calls in:

- App synth codomain evaluation (check.ex)
- Con synth codomain evaluation (check.ex)
- `gadt_branch_ctx` field type evaluation (check.ex)

`MetaState.force/2` only resolves the top-level value. A value like `{:vpi, :omega, {:vneutral, _, {:nmeta, solved_id}}, env, cod}` where the domain contains a solved meta will NOT be updated — force only operates on the outermost constructor.

This is fragile: every new call site that evaluates a codomain with a potentially-stale env must remember to force. Missing a force call produces subtle bugs that only manifest with specific meta-solving orderings.

## Standard approach

Lean 4 style: the `whnf` (weak head normal form) function re-evaluates stuck terms each time it's called, using the current meta state. Since the meta context is always available, re-evaluation sees the latest solutions. No manual forcing needed.

Alternatively, Kovacs' "glued evaluation" carries both folded and unfolded representations. This is more principled but requires changing the Value type.

## Proposed solution

Add `Eval.whnf(eval_ctx, value)` that reduces a value to weak head normal form, resolving solved metas along the way:

1. If the value is `{:vneutral, type, {:nmeta, id}}` and id is solved, return the solution (recursively whnf'd)
2. If the value is `{:vneutral, type, {:napp, ne, arg}}` and the head meta is solved, re-apply the solved function to the arg
3. If the value is `{:vneutral, type, {:ncase, ne, branches, env}}` and the scrutinee is now a constructor, reduce the case
4. Otherwise return the value unchanged

Then replace all `forced_env = Enum.map(env, &MetaState.force(...))` calls with proper whnf calls on the codomain result. The whnf function should be the single entry point for "make sure this value reflects the current meta state."

## Files to modify

| File | Change |
|------|--------|
| `lib/haruspex/eval.ex` | Add `whnf/2` function |
| `lib/haruspex/check.ex` | Replace ad-hoc `forced_env` patterns with whnf |
| `lib/haruspex/unify.ex` | Use whnf instead of `MetaState.force` at unification entry |

## Testing

- Existing tests should continue to pass (whnf subsumes force)
- Add tests for nested meta resolution (meta inside Pi domain, meta inside data constructor arg)
- Add test for stuck case becoming reducible after meta solving

## Verification

```bash
mix test
mix format --check-formatted
mix dialyzer
```
