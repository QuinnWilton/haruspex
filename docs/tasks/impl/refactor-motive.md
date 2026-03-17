# Refactor: proper dependent motive computation

**Depends on**: refactor-unified-elaboration (strongly recommended)
**Blocks**: nothing directly, but required for full dependent pattern matching
**Priority**: medium — the current ad-hoc approach works for Vec but won't scale

## Problem

The case expression checker uses two separate mechanisms for computing branch expected types:

1. **`abstract_over` + `eval_motive`** — for non-GADT branches. Walks the expected type syntactically, replacing occurrences of the scrutinee with `{:var, 0}`. Uses `core_convertible?` which is plain structural equality (`==`), not NbE conversion.

2. **`apply_index_equations`** — for GADT branches. Substitutes solved index values into the evaluation env and re-evaluates the expected type.

These don't compose. A branch gets one mechanism or the other (based on whether `index_equations` is non-empty). A case where both the scrutinee value AND index equations matter would need both, but only gets one.

The `abstract_over` mechanism is also imprecise — it only finds the scrutinee when it appears as the exact same core term. If the scrutinee appears inside a computation (e.g., `add(xs_length, 1)` where `xs_length` depends on the scrutinee), it won't be found.

## Standard approach

In proper dependent elimination (Cockx, McBride, Agda):

1. The **motive** is a first-class lambda `P : (x : Scrutinee_Type) → Type`, computed so that `P(scrutinee) = goal_type`.
2. For each constructor `c` with fields `a1...an`, the branch obligation is `P(c(a1,...,an))` — the motive applied to the reconstructed scrutinee.
3. For GADTs, the constructor's return type indices unify with the scrutinee type indices, and this determines how the motive specializes. No separate "apply index equations" mechanism — it falls out of evaluating the motive.
4. The motive uses **NbE conversion** for abstraction, not syntactic equality.

## Proposed solution

Replace both mechanisms with a single motive-based approach:

1. Compute the motive as a `VLam` value (not a core term) by abstracting the scrutinee from the expected type using NbE conversion.
2. For each branch, apply the motive to the reconstructed constructor value:
   - For `vnil` branch: `P(vnil)` where the index metas in vnil's type are solved by GADT unification
   - For `vcons` branch: `P(vcons(x, rest))` where x and rest are fresh vars with GADT-refined types
3. The GADT index refinement happens naturally through the motive application — when `P` is applied to `vnil`, and `P` was abstracted from `Vec(Int, add(n, m))`, the `n` in the motive becomes `zero` (from vnil's return type), giving `Vec(Int, add(zero, m))` = `Vec(Int, m)`.

This subsumes both `abstract_over` and `apply_index_equations`.

## Files to modify

| File | Change |
|------|--------|
| `lib/haruspex/pattern.ex` | Replace `abstract_over` with NbE-based motive computation |
| `lib/haruspex/check.ex` | Replace dual mechanism (eval_motive / apply_index_equations) with single motive application |

## Scope

Large. Requires NbE conversion checking (not just syntactic equality) and careful handling of the motive lambda's variable binding. Best done after the unified elaboration refactor, which provides the type context needed for NbE-based abstraction.

## Verification

```bash
mix test
mix format --check-formatted
mix dialyzer
```
