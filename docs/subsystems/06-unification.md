# Unification

## Purpose

Solves metavariables and universe level constraints during type checking. Extends conversion checking with the ability to solve unknowns. Uses Miller pattern unification for the common case and falls back to first-order unification otherwise. See [[../decisions/d14-implicits-from-start]], [[../decisions/d05-universe-hierarchy]].

## Dependencies

- `Haruspex.Core` — term representation
- `Haruspex.Value` — value domain
- `Haruspex.Eval` — evaluation
- `Haruspex.Quote` — readback
- `Haruspex.Context` — typing context
- `Haruspex.Unify.MetaState` — mutable meta context
- `Haruspex.Unify.LevelSolver` — universe level solving

## Key types

```elixir
# MetaState
@type meta_entry :: {:solved, Value.value()} | {:unsolved, Value.value(), Context.t()}
@type meta_state :: %{Core.meta_id() => meta_entry()}

# Level constraints
@type level_constraint ::
  {:eq, Core.level(), Core.level()}
  | {:leq, Core.level(), Core.level()}

# Unification result
@type unify_result :: :ok | {:error, unify_error()}
@type unify_error ::
  {:mismatch, Value.value(), Value.value()}
  | {:occurs_check, Core.meta_id(), Value.value()}
  | {:not_pattern, Core.meta_id(), [Value.value()]}
  | {:scope_escape, Core.meta_id(), Value.value()}
```

## Public API

```elixir
# Main unification entry point
@spec unify(lvl(), Value.value(), Value.value()) :: unify_result()

# Meta operations
@spec fresh_meta(Value.value(), Context.t()) :: {Core.meta_id(), Value.value()}
@spec solve_meta(Core.meta_id(), Value.value()) :: :ok | {:error, term()}
@spec lookup_meta(Core.meta_id()) :: meta_entry()

# Level operations
@spec fresh_level() :: Core.level()
@spec add_level_constraint(level_constraint()) :: :ok
@spec solve_levels() :: :ok | {:error, [level_constraint()]}
```

## Unification algorithm

```
unify(l, v1, v2):
  # Force metas: if v1 or v2 is a solved meta, replace with its solution
  v1' = force(v1)
  v2' = force(v2)

  case {v1', v2'}:
    # Same neutral variable
    {VNeutral(_, NVar(l1)), VNeutral(_, NVar(l2))} when l1 == l2 -> :ok

    # Meta solving (flex-rigid)
    {VNeutral(_, NMeta(id)), _} -> solve_meta_against(l, id, v2')
    {_, VNeutral(_, NMeta(id))} -> solve_meta_against(l, id, v1')

    # Structural cases
    {VLam(_, env1, b1), VLam(_, env2, b2)} ->
      arg = fresh_var(l)
      unify(l+1, eval([arg|env1], b1), eval([arg|env2], b2))

    {VPi(m1, d1, env1, c1), VPi(m2, d2, env2, c2)} when m1 == m2 ->
      unify(l, d1, d2)
      arg = fresh_var(l)
      unify(l+1, eval([arg|env1], c1), eval([arg|env2], c2))

    {VSigma(a1, env1, b1), VSigma(a2, env2, b2)} ->
      unify(l, a1, a2)
      arg = fresh_var(l)
      unify(l+1, eval([arg|env1], b1), eval([arg|env2], b2))

    {VPair(a1, b1), VPair(a2, b2)} ->
      unify(l, a1, a2)
      unify(l, b1, b2)

    {VType(lv1), VType(lv2)} ->
      add_level_constraint({:eq, lv1, lv2})

    {VLit(v), VLit(v)} -> :ok

    # Neutral-neutral: unify heads, then spines
    {VNeutral(_, ne1), VNeutral(_, ne2)} -> unify_neutral(l, ne1, ne2)

    # Eta for functions: one side is a lambda, other is not
    {VLam(_, env, body), _} ->
      arg = fresh_var(l)
      unify(l+1, eval([arg|env], body), vapp(v2', arg))
    {_, VLam(_, env, body)} ->
      arg = fresh_var(l)
      unify(l+1, vapp(v1', arg), eval([arg|env], body))

    _ -> {:error, {:mismatch, v1', v2'}}
```

## Pattern unification (solve_meta_against)

```
solve_meta_against(l, meta_id, spine, rhs):
  # Check pattern condition: spine must be distinct bound variables
  case check_pattern(spine):
    {:ok, var_list} ->
      # Occurs check
      if occurs(meta_id, rhs): {:error, {:occurs_check, meta_id, rhs}}
      # Scope check: rhs only mentions variables in var_list
      if scope_escapes(var_list, rhs): {:error, {:scope_escape, meta_id, rhs}}
      # Build solution: abstract over the spine variables
      solution = abstract(l, var_list, rhs)
      solve_meta(meta_id, solution)

    :not_pattern ->
      # Fall back: try to intersect/prune, or defer
      {:error, {:not_pattern, meta_id, spine}}
```

## Level solver

Collects constraints of the form:
- `{:eq, l1, l2}` — levels must be equal
- `{:leq, l1, l2}` — l1 <= l2 (from cumulativity)

Solver is a simple fixpoint iteration:
1. Initialize all level variables to 0
2. Process constraints, raising variables as needed
3. Repeat until no changes
4. If max iterations exceeded, report unsatisfiable constraints

## Implementation notes

- MetaState is process-local (stored in process dictionary or passed as accumulator)
- `force/1` recursively resolves solved metas (a solved meta may point to another meta)
- Occurs check walks the value looking for the meta being solved
- Pruning (simplification of meta spines) deferred to later if needed

## Testing strategy

- **Unit tests**: Solve simple metas, pattern condition checking, occurs check
- **Property tests**:
  - Solved metas are idempotent: solving twice with the same value is a no-op
  - Unification is symmetric: `unify(a, b) == unify(b, a)`
- **Integration**: Implicit argument inference for `id(42)` resolves `a = Int`
