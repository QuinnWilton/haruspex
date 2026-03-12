# Tier 2: Unification

**Modules**: `Haruspex.Unify`, `Haruspex.Unify.MetaState`, `Haruspex.Unify.LevelSolver`
**Subsystem doc**: [[../../subsystems/06-unification]]
**Decisions**: d05 (universes), d14 (implicits), d15 (eta)

## Scope

Implement metavariable solving via pattern unification, structural unification with eta, and universe level constraint solving.

## Implementation

### MetaState

Persistent map of meta entries. Threaded explicitly through all operations.

```elixir
Haruspex.Unify.MetaState
  fresh_meta/4, solve/3, lookup/2, force/2
```

### Unification

```elixir
Haruspex.Unify
  unify/4  # (meta_state, lvl, value, value) → {:ok, meta_state} | {:error, type_error}
```

Cases (in order):
1. Force both sides (follow solved metas)
2. Both sides identical (structurally equal after forcing) → ok
3. Flex-flex: two unsolved metas → solve higher-numbered to lower-numbered; with spines, try pattern unification on both sides
4. Flex-rigid: one side is meta → pattern check spine, solve if valid
5. Rigid-rigid: same head constructor → unify arguments recursively
   - `VPi`: check multiplicities match, unify domains, then codomains (evaluated with fresh var)
   - `VSigma`: unify first types, then second types (evaluated with fresh var)
   - `VLam`: apply both to fresh var, unify bodies
   - `VPair`: unify both components
   - `VType`: accumulate `{:eq, l1, l2}` level constraint in MetaState
   - `VLit`: equal literals → ok
   - `VBuiltin`: same name → ok
   - `VExtern`: same module/function/arity → ok
6. Eta for functions: `VLam` vs non-`VLam` → apply both to fresh var, unify bodies
7. Eta for pairs: `VPair` vs non-`VPair` → unify via `vfst`/`vsnd` projections
8. Neutral-neutral: structural spine comparison — same head, pairwise-unify arguments
9. Otherwise → `{:error, {:mismatch, lhs, rhs}}`

Error types:
- `{:mismatch, Value.value(), Value.value()}` — structural mismatch
- `{:occurs_check, meta_id, Value.value()}` — meta appears in its own solution
- `{:scope_escape, meta_id, Value.value()}` — solution references out-of-scope variable
- `{:not_pattern, meta_id, [Value.value()]}` — spine is not distinct bound variables
- `{:multiplicity_mismatch, mult, mult}` — Pi multiplicities don't match

### Pattern unification

For flex-rigid case `Meta(id) spine = rhs`:
1. `check_pattern(spine)` → verify spine is distinct bound variables, return their levels
2. Scope check: all free variables in `rhs` must be in the spine's level list
3. Occurs check: `id` must not appear in `rhs`
4. `abstract(rhs, levels)` → wrap `rhs` in lambdas, converting levels to indices
5. `solve(state, id, abstracted_rhs)`

### Level solver

After a definition is fully checked, solve accumulated level constraints:

```elixir
Haruspex.Unify.LevelSolver
  solve/1  # [level_constraint()] → {:ok, %{level_var_id => non_neg_integer()}} | {:error, ...}
```

Algorithm: fixpoint iteration. Initialize all level vars to 0. Apply constraints. Repeat until stable or max 100 iterations.

## Testing strategy

### Unit tests (`test/haruspex/unify_test.exs`, `test/haruspex/meta_state_test.exs`, `test/haruspex/level_solver_test.exs`)

**MetaState:**
- `fresh_meta` increments ID, stores unsolved entry
- `solve` transitions unsolved → solved
- `solve` on already-solved with same value → ok
- `solve` on already-solved with different value → error
- `lookup` returns correct entry
- `force` follows solved chains: meta A → meta B → VLit(42) → VLit(42)
- `force` handles cycle (meta pointing to itself) without infinite loop
- `add_constraint` accumulates level constraints

**Unification:**
- Same value → ok (VLit(1), VLit(1))
- Different literals → mismatch error
- Same builtin → ok, different builtins → mismatch
- VPi vs VPi → unify domains and codomains
- VPi with different multiplicities → `{:error, {:multiplicity_mismatch, ...}}`
- VLam vs VLam → apply to fresh var, unify bodies
- Eta: VLam vs neutral at Pi type → ok (eta-expand neutral)
- Eta: VPair vs non-VPair → unify via projections (vfst/vsnd)
- Meta solving: `?a = VLit(42)` → meta solved to `VLit(42)`
- Meta = meta → solve higher-numbered to lower-numbered
- Pattern unification: `?a(x) = x` → identity function, `?a(x) = lit` → constant function
- Occurs check: `?a = Pi(_, ?a, _)` → error
- Scope escape: `?a = x` where `x` is not in meta's scope → error
- Neutral-neutral: same head and args → ok, different → mismatch
- Forcing: solved metas on either side are resolved before comparison
- Different universe levels → level constraint accumulated in MetaState

**Level solver:**
- `{:eq, ?l, {:llit, 0}}` → `?l = 0`
- `{:eq, ?l, {:lsucc, {:llit, 0}}}` → `?l = 1`
- `{:eq, ?l, {:lmax, {:llit, 0}, {:llit, 1}}}` → `?l = 1`
- Transitive: `?l1 = ?l2, ?l2 = 0` → both 0
- Cyclic: `?l = succ(?l)` → error

### Property tests

- **Unification symmetry**: `unify(a, b)` succeeds iff `unify(b, a)` succeeds
- **Meta idempotence**: solving a meta twice with the same value doesn't change state
- **Level solver determinism**: same constraints → same solution

### Integration tests

- Unify `Pi(:omega, VBuiltin(:Int), _, Builtin(:Int))` with `Pi(:omega, VBuiltin(:Int), _, Builtin(:Int))` → ok
- Implicit argument: create meta, unify with concrete type, verify meta is solved

## Verification

```bash
mix test test/haruspex/unify_test.exs test/haruspex/meta_state_test.exs test/haruspex/level_solver_test.exs
mix format --check-formatted
mix dialyzer
```
