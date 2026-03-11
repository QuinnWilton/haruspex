# Refinements

## Purpose

Refinement types `{x : T | P(x)}` allow expressing constraints that go beyond simple types — e.g., `{n : Int | n > 0}` for positive integers, `{d : Int | d != 0}` for non-zero divisors. Uses constrain's Horn clause solver for automatic discharge. See [[../decisions/d06-constrain-for-refinements]].

## Dependencies

- `Haruspex.Core` — `{:refine, base, predicate}` term
- `Haruspex.Check` — integration with type checker
- `constrain` — `Constrain.entails?/2` for predicate discharge

## Key types

```elixir
# Predicate expressions (subset of constrain's format)
@type predicate ::
  {:gt, pred_expr(), pred_expr()}
  | {:gte, pred_expr(), pred_expr()}
  | {:lt, pred_expr(), pred_expr()}
  | {:lte, pred_expr(), pred_expr()}
  | {:eq, pred_expr(), pred_expr()}
  | {:neq, pred_expr(), pred_expr()}
  | {:and, predicate(), predicate()}
  | {:or, predicate(), predicate()}
  | {:not, predicate()}

@type pred_expr ::
  {:var, atom()}
  | {:lit, integer() | float()}
  | {:add, pred_expr(), pred_expr()}
  | {:sub, pred_expr(), pred_expr()}
  | {:mul, pred_expr(), pred_expr()}

# Assumption context
@type assumptions :: [predicate()]

# Discharge result
@type discharge_result :: :yes | :no | {:unknown, String.t()}
```

## Public API

```elixir
@spec discharge(assumptions(), predicate()) :: discharge_result()
@spec gather_assumptions(Context.t(), Core.term()) :: assumptions()
@spec translate_to_constrain(predicate()) :: Constrain.expr()
```

## Algorithm

### Checking a refinement type
When checking `e : {x : T | P(x)}`:
1. Check `e : T` (the base type)
2. Gather assumptions from the current context (pattern matches, guards, upstream refinements)
3. Substitute `e` for `x` in `P` to get `P(e)`
4. Call `discharge(assumptions, P(e))`
5. Result:
   - `:yes` → type checks (the predicate is entailed)
   - `:no` → type error: "cannot prove P(e); the following assumptions are available: ..."
   - `{:unknown, reason}` → soft error: "could not determine if P(e) holds; consider adding an explicit assertion"

### Assumption gathering
```
gather_assumptions(ctx):
  for each binding in ctx:
    if binding has refinement type {x : T | P(x)}:
      add P(binding_name) to assumptions
    if binding was introduced by pattern match on constructor:
      add equalities from the match (e.g., after matching `some(x)`, we know `val == some(x)`)
    if binding was introduced under a guard `when x > 0`:
      add {:gt, {:var, :x}, {:lit, 0}}
```

### Translation to constrain
Map haruspex predicate expressions to constrain's internal representation. This is a straightforward structural translation since the predicate language was designed to align with constrain's capabilities.

## Implementation notes

- Start simple: only guards expressible in constrain's Horn clause fragment
- Complex predicates (involving function calls, ADT constructors) → `:unknown`
- Refinement types are optional — regular types work without them
- Refinements are erased during codegen (the predicate is a compile-time check only)

## Testing strategy

- **Unit tests**: Discharge for simple predicates (greater-than, not-equal, combined)
- **Integration**: `divide(x, y)` where `y : {y : Int | y != 0}` type-checks
- **Property tests**: If `P` is in assumptions, `discharge(assumptions, P)` returns `:yes`
- **Negative tests**: Missing assumptions → `:no` or `:unknown` with helpful message
