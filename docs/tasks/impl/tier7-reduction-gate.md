# Tier 7: Totality gates type-level reduction

**Decisions**: d28 (reduction scope)

## Scope

Connect totality checking to NbE: `@total` functions unfold during type checking, non-total functions are opaque.

## Implementation

### Wiring

1. After a function passes `@total` checking, mark it in the definition entity: `total?: true`
2. The evaluator's definition context (passed to `eval`) reads this flag
3. When evaluating `App(Def(:f), arg)`:
   - If `f` is `@total` and fuel > 0: unfold body, decrement fuel
   - If `f` is not `@total`: produce `VNeutral(_, NDef(:f, [arg]))`
   - If fuel = 0: produce stuck neutral + diagnostic

### Fuel per-definition override

`@fuel 5000` attribute on a definition overrides the default fuel for that definition's type checking.

## Testing strategy

### Unit tests

- `@total add(succ(succ(zero)), succ(zero))` reduces to `succ(succ(succ(zero)))` during NbE
- Non-total `fib(3)` does NOT reduce — remains as `NDef(:fib, [3])`
- Fuel exhaustion: deeply recursive `@total` function with low fuel → stuck neutral + diagnostic

### Integration tests

- `def foo(xs : Vec(a, add(2, 1))) : Vec(a, 3) do xs end` type-checks (add is total, reduces)
- `def bar(xs : Vec(a, mystery(1))) : Vec(a, mystery(1)) do xs end` type-checks (opaque, trivially equal)
- `def baz(xs : Vec(a, mystery(1))) : Vec(a, 2) do xs end` fails (opaque ≠ literal)

## Verification

```bash
mix test test/haruspex/reduction_gate_test.exs
mix format --check-formatted
mix dialyzer
```
