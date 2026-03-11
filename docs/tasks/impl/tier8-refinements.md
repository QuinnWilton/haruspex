# Tier 8: Refinement types

**Module**: `Haruspex.Predicate`
**Subsystem doc**: [[../../subsystems/11-refinements]]
**Decisions**: d06 (constrain for refinements)

## Scope

Implement refinement type syntax, predicate language, assumption gathering, and discharge via constrain.

## Implementation

### Refinement types

```elixir
{x : Int | x > 0}       # positive integer
{xs : List(a) | length(xs) > 0}  # non-empty list
```

### Predicate language

```elixir
@type predicate ::
  {:pred_and, predicate(), predicate()}
  | {:pred_or, predicate(), predicate()}
  | {:pred_not, predicate()}
  | {:pred_cmp, cmp_op(), Core.term(), Core.term()}
  | {:pred_true}
  | {:pred_false}
```

### Type checking flow

1. Check `e : {x : Base | P}`
2. Check `e : Base` → get value `v`
3. Gather assumptions from context (pattern match equalities, other refinements)
4. Substitute `v` for `x` in `P` → concrete predicate `P(v)`
5. Discharge `P(v)` against assumptions:
   - Tautology → ok
   - Entailed by assumptions → ok
   - Unknown/false → type error with available assumptions listed

### Constrain integration

Translate predicates to constrain's Horn clause format. Use constrain's solver for entailment checking.

### Erasure

Refinement predicates are erased at codegen. `{x : Int | x > 0}` compiles to just `Int`.

## Testing strategy

### Unit tests (`test/haruspex/predicate_test.exs`)

- Discharge tautology: `{x : Int | true}` always passes
- Discharge from assumption: in branch `case n > 0 do true -> ...`, `{x : Int | x > 0}` passes for `n`
- Discharge failure: `{x : Int | x > 0}` with no assumptions → error listing available context
- Predicate substitution: `{x : Int | x > y}` applied to `42` → `42 > y`

### Integration tests

- Non-zero division: `def safe_div(x : Int, y : {y : Int | y != 0}) : Int do div(x, y) end`
- Positive integer: function taking `{n : Int | n > 0}`, called with literal `5` → passes
- Called with unconstrained variable → error

## Verification

```bash
mix test test/haruspex/predicate_test.exs
mix format --check-formatted
mix dialyzer
```
