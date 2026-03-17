# Tier 7: GADT checking

**Depends on**: tier5-adts, tier7-totality

## Scope

Enable GADT pattern matching in the bidirectional type checker with full dependent type support. When a case expression scrutinizes a GADT value, the constructor's return type is unified with the scrutinee type to solve index variables, producing refined field types in each branch. Impossible branches are detected. Type-level computation with `@total` functions reduces in return types.

The showcase: a fully general `vappend` with return type `Vec(Int, add(n, m))` that type-checks, compiles, and runs on the BEAM.

## Algorithm

### Branch context extension (`gadt_branch_ctx`)

1. **Relax neutral indices**: replace neutral type-index args in the scrutinee type with fresh `:gadt` metas so GADT unification can learn index equations (e.g., `n = zero` in the vnil branch)
2. Create fresh `:gadt` metas for each type parameter (evaluating kinds incrementally)
3. Evaluate the constructor's return type under the fresh meta env
4. Unify the return type with the relaxed scrutinee type
5. On success: extract index equations from solved relaxation metas, force param env, evaluate field types
6. On failure: branch is impossible — use placeholder types

### Branch expected type (`apply_index_equations`)

After GADT refinement learns equations like `n = zero`, substitute them into the expected type by modifying the evaluation env and re-evaluating. This allows `add(zero, m)` to reduce to `m` in the vnil branch.

### Implicit insertion

- **Constructor calls**: `peel_implicit_pis` inserts fresh metas for zero-multiplicity Pi params in constructor synth, solving them via later arg checks
- **Function application**: `peel_implicit_apps` does the same for function calls, enabling `vappend(rest, ys)` without explicit implicit args
- **Closure env forcing**: after arg checks solve metas, closure-captured env values are forced so codomain evaluation sees resolved values

### Parser fix

Implicit params `{n : Nat}` now default to `:zero` multiplicity (erased at runtime).

### Constructor type fix

`ADT.constructor_type/2` now correctly shifts field types and GADT return types under field Pi binders using de Bruijn shifting.

### Unification fixes

- **Bare meta solving**: metas with empty spine are solved directly to the rigid value (no quote-abstract-eval round-trip) with scope check using the meta's creation level
- **ncase unification**: stuck case expressions are unified by comparing their scrutinee heads
- **Meta type preservation**: `solve_flex_rigid` passes `ms.entries` to eval so meta type annotations are preserved during the abstract-eval round-trip

### Total def self-reference

`collect_total_defs` substitutes `{:var, 0}` (the def self-reference) with `{:def_ref, name}` so total function bodies work correctly during type-level reduction.

### Motive evaluation

`eval_motive` uses the full context env so free variables in the expected type resolve correctly.

### Quote fix

`quote_neutral` for stuck case expressions evaluates branch bodies under the captured env (with fresh vars for constructor fields) instead of keeping raw core terms with env-relative indices.

## Files modified

| File | Change |
|------|--------|
| `lib/haruspex/check.ex` | `gadt_branch_ctx`, `extend_branch_ctx`, `peel_implicit_pis/apps`, `apply_index_equations`, closure env forcing, GADT-aware exhaustiveness calls |
| `lib/haruspex/pattern.ex` | `constructor_possible?`, `check_exhaustiveness/5` |
| `lib/haruspex/adt.ex` | de Bruijn shifting in `constructor_type` |
| `lib/haruspex/unify.ex` | bare meta solving, ncase unification, meta type preservation |
| `lib/haruspex/unify/meta_state.ex` | `:gadt` meta kind |
| `lib/haruspex/quote.ex` | ncase branch body quoting |
| `lib/haruspex/parser.ex` | implicit param default multiplicity |
| `lib/haruspex.ex` | total def self-reference substitution |
| `test/haruspex/gadt_test.exs` | GADT unit tests |
| `test/haruspex/vec_test.exs` | Vec integration tests |
| `test/haruspex/adt_test.exs` | Updated constructor_type expectation |
| `test/haruspex/parser_test.exs` | Updated implicit param multiplicity expectations |
| `test/haruspex/unify_test.exs` | Updated ncase test env |
| `docs/demos/tier7-gadts.livemd` | Demo notebook |
| `docs/tasks/impl/tier7-gadt.md` | This task doc |

## Testing

```bash
mix test test/haruspex/gadt_test.exs    # 16 GADT unit tests
mix test test/haruspex/vec_test.exs     # 11 Vec integration tests
mix test                                 # Full regression (1619 tests, 0 failures)
mix format --check-formatted
mix dialyzer                             # 0 errors
```
