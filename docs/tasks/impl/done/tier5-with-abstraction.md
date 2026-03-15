# Tier 5: With-abstraction

**Module**: `Haruspex.Pattern` (integrated with pattern compilation)
**Subsystem doc**: [[../../subsystems/20-with-abstraction]]
**Decisions**: d22 (with-abstraction)

## Scope

Implement `with` expressions for dependent pattern matching on intermediate computed values.

## Implementation

### Elaboration algorithm

Given `with f(x) do branches end` at goal type `G`:

1. Evaluate `e = f(x)`, infer its type `T`
2. Abstract: replace all occurrences of `e` in `G` with fresh variable `w` → `G[e := w]`
3. Case-split on `e` with branches, where each branch specializes `G` by substituting the pattern for `w`
4. Produce a regular `case` in core (no new core terms)

### Abstraction algorithm

Walk the goal type `G`, comparing sub-expressions to `e` (using NbE conversion). Replace matching sub-expressions with `Var(0)` (fresh variable). Wrap in a lambda: `fn(w : T) -> G[e := w]`.

If `e` doesn't appear in `G`, the abstraction is trivial (no refinement) — the case still works but branches don't refine the goal type.

If `e` appears under a binder that captures variables `e` depends on, abstraction fails → error.

### Multiple scrutinees

`with e1, e2 do p1, p2 -> body end` desugars to nested with:
```
with e1 do p1 -> with e2 do p2 -> body end end
```

## Testing strategy

### Unit tests (`test/haruspex/with_test.exs`)

- Simple with on Bool: `with p(x) do true -> ...; false -> ... end`
- With on Nat: `with compare(x, y) do ...`
- Goal type refinement: type mentions `p(x)`, branch knows `p(x) = true`
- Trivial abstraction: `e` not in goal type → still works
- Multiple scrutinees: `with e1, e2` → nested case

### Negative tests

- Abstraction failure: `e` under a capturing binder → clear error

### Integration tests

- Filter on a list with dependent length tracking (if Vec is available)

## Verification

```bash
mix test test/haruspex/with_test.exs
mix format --check-formatted
mix dialyzer
```
