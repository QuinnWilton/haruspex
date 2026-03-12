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
@type meta_entry ::
  {:unsolved, type :: Value.value(), ctx_level :: non_neg_integer(), kind :: :implicit | :hole}
  | {:solved, Value.value()}

@type meta_state :: %{
  next_id: Core.meta_id(),
  entries: %{Core.meta_id() => meta_entry()}
}

# Level constraints
@type level_constraint ::
  {:eq, Core.level(), Core.level()}
  | {:leq, Core.level(), Core.level()}

# Unification result
@type unify_result :: {:ok, MetaState.t()} | {:error, unify_error()}
@type unify_error ::
  {:mismatch, Value.value(), Value.value()}
  | {:occurs_check, Core.meta_id(), Value.value()}
  | {:not_pattern, Core.meta_id(), [Value.value()]}
  | {:scope_escape, Core.meta_id(), Value.value()}
  | {:multiplicity_mismatch, Core.mult(), Core.mult()}
```

## Public API

```elixir
# Main unification entry point (threads MetaState, accumulates level constraints)
@spec unify(MetaState.t(), non_neg_integer(), Value.value(), Value.value()) :: unify_result()

# Meta operations (Haruspex.Unify.MetaState)
@spec fresh_meta(meta_state(), Value.value(), non_neg_integer(), :implicit | :hole) :: {Core.meta_id(), meta_state()}
@spec solve(meta_state(), Core.meta_id(), Value.value()) :: {:ok, meta_state()} | {:error, :already_solved}
@spec lookup(meta_state(), Core.meta_id()) :: meta_entry()
@spec force(meta_state(), Value.value()) :: Value.value()

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

    # Neutral-neutral: structural comparison of spines (see below)
    {VNeutral(_, ne1), VNeutral(_, ne2)} -> unify_neutral(l, ne1, ne2)

    # Eta for functions: one side is a lambda, other is not
    {VLam(_, env, body), _} ->
      arg = fresh_var(l)
      unify(l+1, eval([arg|env], body), vapp(v2', arg))
    {_, VLam(_, env, body)} ->
      arg = fresh_var(l)
      unify(l+1, vapp(v1', arg), eval([arg|env], body))

    # Eta for pairs: one side is a pair, other is not — unify via projections
    {VPair(a1, b1), _} ->
      unify(l, a1, vfst(v2'))
      unify(l, b1, vsnd(v2'))
    {_, VPair(a2, b2)} ->
      unify(l, vfst(v1'), a2)
      unify(l, vsnd(v1'), b2)

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

## Helper functions

### check_pattern

Verify the spine is a sequence of distinct bound variables, returning their de Bruijn levels.

```
check_pattern(spine) → {:ok, [lvl()]} | :not_pattern

check_pattern(spine):
  levels = for each element in spine:
    case element:
      VNeutral(_, NVar(l)) -> l
      _ -> return :not_pattern
  if has_duplicates(levels): return :not_pattern
  {:ok, levels}
```

### scope_escapes

Syntactic walk of a value, verifying all free variables (neutral vars) have levels contained in the spine's level list. Returns `true` if a variable escapes (i.e., its level is not in the allowed set).

```
scope_escapes(allowed_levels, value) → boolean()

scope_escapes(allowed, val):
  case val:
    VNeutral(_, NVar(l)) -> l not in allowed
    VNeutral(_, NMeta(_)) -> false  # metas are fine, they'll be solved later
    VPi(_, dom, env, cod) ->
      scope_escapes(allowed, dom) or
      scope_escapes(allowed, eval([fresh_var(length(env)) | env], cod))
    VSigma(a, env, b) -> analogous to VPi
    VLam(_, env, body) ->
      scope_escapes(allowed, eval([fresh_var(length(env)) | env], body))
    VPair(a, b) -> scope_escapes(allowed, a) or scope_escapes(allowed, b)
    VNeutral(_, ne) -> scope_escapes_neutral(allowed, ne)
    _ -> false  # VLit, VBuiltin, VType are closed
```

### abstract

Wrap a value in lambdas binding the spine variables, converting de Bruijn levels to indices. Produces a core term suitable for storing as the meta's solution.

```
abstract(current_level, spine_levels, rhs) → Core.term()

abstract(l, levels, rhs):
  # Quote the rhs at the current level
  term = quote(l, rhs)
  # Wrap in lambdas for each spine variable (in reverse order)
  # Each lambda binds one spine variable, so we rename
  # level references in term to de Bruijn indices
  result = rename(term, levels, l)
  wrap_lambdas(result, length(levels))

rename(term, levels, base_level):
  # Replace Var(ix) where the corresponding level is in `levels`
  # with the new index based on its position in the spine
  walk term, for each Var(ix):
    level = base_level - ix - 1
    case index_of(level, levels):
      {:ok, pos} -> Var(length(levels) - pos - 1 + offset)
      :none -> Var(ix + length(levels))  # shift for the new lambdas

wrap_lambdas(term, 0): term
wrap_lambdas(term, n): Lam(:omega, wrap_lambdas(term, n - 1))
```

### unify_neutral

Structural comparison of neutral spines. Two neutrals unify if they have the same head and their argument spines unify pairwise.

```
unify_neutral(l, ne1, ne2) → unify_result()

unify_neutral(l, ne1, ne2):
  case {ne1, ne2}:
    {NVar(l1), NVar(l2)} when l1 == l2 -> :ok
    {NApp(head1, arg1), NApp(head2, arg2)} ->
      unify_neutral(l, head1, head2)
      unify(l, arg1, arg2)
    {NFst(e1), NFst(e2)} -> unify_neutral(l, e1, e2)
    {NSnd(e1), NSnd(e2)} -> unify_neutral(l, e1, e2)
    _ -> {:error, {:mismatch, VNeutral(nil, ne1), VNeutral(nil, ne2)}}
```

### force

Follow solved meta chains. If a value is a solved meta, replace it with the solution and recurse. Includes cycle detection and a defensive depth limit.

```
force(meta_state, value) → Value.value()

force(state, val):
  force_loop(state, val, 0)

force_loop(state, val, depth):
  if depth > 100: val  # defensive limit, should never be hit in practice
  case val:
    VNeutral(_, NMeta(id)) ->
      case lookup(state, id):
        {:solved, solution} ->
          # Follow the chain, but if solution points back to the same meta, stop.
          if solution == val: val  # cycle: leave unsolved
          else: force_loop(state, solution, depth + 1)
        {:unsolved, _, _, _} -> val  # unsolved, return as-is
    _ -> val  # not a meta, nothing to force
```

## Level solver

Collects constraints of the form:
- `{:eq, l1, l2}` — levels must be equal
- `{:leq, l1, l2}` — l1 <= l2 (from cumulativity)

Level expressions in constraints:
- `{:llit, n}` — concrete level literal
- `{:lvar, id}` — level variable (created by `fresh_level/0`)
- `{:lsucc, l}` — successor of a level
- `{:lmax, l1, l2}` — max of two levels

```
solve(constraints) → {:ok, %{level_var_id => non_neg_integer()}} | {:error, {:universe_cycle, ...}}

solve(constraints):
  # Collect all level variable IDs from constraints.
  vars = collect_vars(constraints)

  # Initialize all level variables to 0.
  assignment = %{id => 0 for id in vars}

  # Fixpoint iteration: apply constraints until stable.
  for iteration in 1..100:
    changed = false
    for constraint in constraints:
      case constraint:
        {:eq, lhs, rhs} ->
          lhs_val = eval_level(assignment, lhs)
          rhs_val = eval_level(assignment, rhs)
          # If lhs is a variable, raise it to max(current, rhs_val).
          # If rhs is a variable, raise it to max(current, lhs_val).
          # If both are ground and unequal, error.
          update assignment, set changed = true if any value increased
        {:leq, l1, l2} ->
          v1 = eval_level(assignment, l1)
          v2 = eval_level(assignment, l2)
          # If l2 is a variable and v1 > v2, raise l2 to v1.
          # If both ground and v1 > v2, error.

    if not changed: return {:ok, assignment}

  # Exceeded 100 iterations — constraints are unsatisfiable.
  # Example: ?l = succ(?l) causes infinite growth.
  {:error, {:universe_cycle, constraints}}

eval_level(assignment, level):
  case level:
    {:llit, n} -> n
    {:lvar, id} -> Map.get(assignment, id, 0)
    {:lsucc, l} -> eval_level(assignment, l) + 1
    {:lmax, l1, l2} -> max(eval_level(assignment, l1), eval_level(assignment, l2))
```

## Implementation notes

- MetaState is a persistent data structure threaded explicitly through elaboration and checking (not process dictionary). All operations that modify MetaState return an updated state.
- `force/2` recursively resolves solved metas with cycle detection and a max chain depth of 100 (see helper functions above).
- Occurs check walks the value looking for the meta being solved.
- Pruning (simplification of meta spines) deferred to later if needed.

## Testing strategy

- **Unit tests**: Solve simple metas, pattern condition checking, occurs check
- **Property tests**:
  - Solved metas are idempotent: solving twice with the same value is a no-op
  - Unification is symmetric: `unify(a, b) == unify(b, a)`
- **Integration**: Implicit argument inference for `id(42)` resolves `a = Int`
