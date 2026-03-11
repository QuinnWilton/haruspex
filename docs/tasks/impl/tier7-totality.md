# Tier 7: Totality checking

**Module**: `Haruspex.Totality`
**Subsystem doc**: [[../../subsystems/13-totality]]
**Decisions**: d18 (opt-in totality)

## Scope

Implement `@total` structural recursion checking for single functions. Mutual totality deferred.

## Implementation

### Algorithm

1. Identify candidate decreasing arguments: parameters whose type is an ADT
2. For each candidate, check all recursive calls:
   a. Find `App(...name...)` in the body
   b. Examine the argument at the candidate position
   c. Verify it is a strict structural subterm (bound by a pattern match on the parameter)
3. If any candidate works for ALL recursive calls → total

### Structural subterm

A variable `v` is a structural subterm of parameter `p` if `v` was bound by a constructor pattern in a `case p do ... end` branch. Variables in nested patterns (matching fields of fields) are also subterms.

### Recursive call detection

Walk the core term looking for applications of the function name. Handle curried applications: `App(App(App(Def(:f), a1), a2), a3)` — collect all arguments in order.

### What is NOT structural

- Recursion on a computed value: `f(g(x))` where `g(x)` is not a pattern variable
- Recursion on the original parameter: `f(x)` where `x` is the un-destructured argument
- Nested recursion: `f(f(x))` — recursion on a recursive call result

## Testing strategy

### Unit tests (`test/haruspex/totality_test.exs`)

- **Accepted**: `@total def length(xs : List(a)) : Nat do case xs do nil -> zero; cons(_, rest) -> succ(length(rest)) end end`
- **Accepted**: `@total def add(n : Nat, m : Nat) : Nat do case n do zero -> m; succ(k) -> succ(add(k, m)) end end`
- **Rejected**: `@total def loop(n : Nat) : Nat do loop(n) end` — no decrease
- **Rejected**: `@total def bad(n : Nat) : Nat do bad(succ(n)) end` — increase, not decrease
- **Rejected**: `@total def nested(n : Nat) : Nat do nested(nested(n))` — nested recursion
- **Non-recursive**: `@total def const(x : Int) : Int do x end` — trivially total (no recursive calls)
- **Non-ADT parameter**: `@total def f(n : Int) : Int do ...` — Int is not an ADT, can't identify subterms → error if recursive

### Integration tests

- Total function compiles and runs
- Total function available for type-level reduction (d28)
- Non-total function works fine but doesn't reduce in types

## Verification

```bash
mix test test/haruspex/totality_test.exs
mix format --check-formatted
mix dialyzer
```
