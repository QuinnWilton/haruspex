# Tier 7: Length-indexed vectors

**Depends on**: tier7-totality, tier7-reduction-gate, tier5-adts

## Scope

Define `Vec(a, n)` — a length-indexed vector type — as a standard library type that exercises dependent types with type-level computation. This validates that `@total` functions reduce in types and that the full dependent type pipeline works end-to-end.

## Implementation

### Type definition

```
type Vec(a : Type, n : Nat) =
  vnil : Vec(a, zero)
  | vcons(a, Vec(a, k)) : Vec(a, succ(k))
```

This is a GADT: constructors have non-trivial return types that refine the index `n`.

### Standard functions

```
@total
def vhead(v : Vec(a, succ(n))) : a do
  case v do vcons(x, _) -> x end
end

@total
def vtail(v : Vec(a, succ(n))) : Vec(a, n) do
  case v do vcons(_, rest) -> rest end
end

@total
def vappend(xs : Vec(a, n), ys : Vec(a, m)) : Vec(a, add(n, m)) do
  case xs do
    vnil -> ys
    vcons(x, rest) -> vcons(x, vappend(rest, ys))
  end
end

@total
def vmap(f : a -> b, xs : Vec(a, n)) : Vec(b, n) do
  case xs do
    vnil -> vnil
    vcons(x, rest) -> vcons(f(x), vmap(f, rest))
  end
end
```

### Type-level reduction validation

These functions exercise the reduction gate:

- `vappend` return type `Vec(a, add(n, m))` requires `add` to reduce in types
- `vhead` input type `Vec(a, succ(n))` requires pattern matching on type indices
- `vmap` preserves the length index

### Prerequisites

- GADT constructor return type elaboration (constructors with refined indices)
- Dependent pattern matching that refines type indices in branches
- `@total` `add` available for type-level reduction via `def_ref`

## Testing strategy

### Unit tests

- `vnil` has type `Vec(a, zero)`
- `vcons(1, vcons(2, vnil))` has type `Vec(Int, succ(succ(zero)))`
- `vhead(vcons(1, vnil))` evaluates to `1`
- `vtail(vcons(1, vcons(2, vnil)))` evaluates to `vcons(2, vnil)`
- `vappend(vcons(1, vnil), vcons(2, vnil))` has type `Vec(Int, succ(succ(zero)))`

### Integration tests

- `def foo(xs : Vec(a, add(succ(succ(zero)), succ(zero)))) : Vec(a, succ(succ(succ(zero)))) do xs end` type-checks (add reduces)
- `vmap` compiles and runs correctly
- All Vec functions pass `@total` checking

### Negative tests

- `vhead(vnil)` is a type error (index mismatch: `zero ≠ succ(n)`)
- Non-exhaustive match on Vec is caught

## Verification

```bash
mix test test/haruspex/vec_test.exs
mix format --check-formatted
mix dialyzer
```
