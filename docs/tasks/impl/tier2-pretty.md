# Tier 2: Pretty-printer

**Module**: `Haruspex.Pretty`
**Subsystem doc**: [[../../subsystems/08-checker]] (error pretty-printing section)

## Scope

Implement `Value → String` pretty-printing with name recovery from de Bruijn levels.

## Implementation

### Name recovery

Given a name list `[atom()]` indexed by de Bruijn level:
- `VNeutral(_, NVar(lvl))` → `names[lvl]`
- On shadowing (same name at multiple levels): append primes — `x`, `x'`, `x''`
- If name list is shorter than level (shouldn't happen): use `_v{level}`

### Formatting rules

- `VBuiltin(:Int)` → `"Int"`, `VBuiltin(:Float)` → `"Float"`, etc.
- `VPi(:omega, dom, _, cod)` where binding unused → `"Dom -> Cod"`
- `VPi(:omega, dom, _, cod)` where binding used → `"(x : Dom) -> Cod"`
- `VPi(:zero, dom, _, cod)` implicit → `"{x : Dom} -> Cod"`
- `VSigma(a, _, b)` → `"(x : A, B)"` or `"A × B"` when unused
- `VLam(_, _, _)` → `"fn(x) do ... end"`
- `VLit(42)` → `"42"`, `VLit("hello")` → `"\"hello\""`
- `VType(LLit(0))` → `"Type"`, `VType(LLit(1))` → `"Type 1"`
- `VNeutral(_, ne)` → print the neutral spine
- Solved implicits: elided by default

### Public API

```elixir
@spec pretty(Value.value(), [atom()], non_neg_integer()) :: String.t()
  # pretty(value, name_list, current_level)
@spec pretty_term(Core.term(), [atom()]) :: String.t()
  # for printing core terms (less common)
```

## Testing strategy

### Unit tests (`test/haruspex/pretty_test.exs`)

- Builtin types: `VBuiltin(:Int)` → `"Int"`
- Literals: `VLit(42)` → `"42"`, `VLit(3.14)` → `"3.14"`
- Arrow: non-dependent Pi → `"Int -> Int"`
- Dependent Pi: `"(n : Nat) -> Vec(a, n)"`
- Implicit: `"{a : Type} -> a -> a"`
- Variable with name: `NVar(0)` with names `[:x]` → `"x"`
- Shadowing: two bindings named `:x` → `"x"` and `"x'"`
- Nested Pi: `"Int -> Int -> Int"` (right-associative arrow)

### Property tests

- **No crash**: random well-formed values never crash the pretty-printer
- **Non-empty**: pretty-printing any value produces a non-empty string

## Verification

```bash
mix test test/haruspex/pretty_test.exs
mix format --check-formatted
mix dialyzer
```
