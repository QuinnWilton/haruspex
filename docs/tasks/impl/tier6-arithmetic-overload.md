# Tier 6: Arithmetic overloading

**Decisions**: d26 (builtins → type classes)

## Scope

Migrate arithmetic operators from fixed builtin signatures to type class methods with builtin instances for `Int` and `Float`.

## Implementation

### New classes

```elixir
class Num(a) do
  add(x : a, y : a) : a
  sub(x : a, y : a) : a
  mul(x : a, y : a) : a
end

class Eq(a) do eq(x : a, y : a) : Bool end
class Ord(a) do compare(x : a, y : a) : Ordering end
```

### Builtin instances

```elixir
instance Num(Int) do
  def add(x, y) do @builtin :add end
  def sub(x, y) do @builtin :sub end
  def mul(x, y) do @builtin :mul end
end
```

The instance methods delegate to the same builtin delta rules. Codegen still produces `Kernel.+(a, b)`.

### Migration

1. Remove fixed type signatures for `add`, `sub`, `mul` from the elaborator's builtin table
2. Define `Num`, `Eq`, `Ord` classes in the prelude
3. Define instances for `Int` and `Float` in the prelude
4. `+` operator now resolves through instance search instead of a hard-coded type
5. Monomorphic call sites (known `Int`) inline to the same codegen as before — zero runtime cost

### Backward compatibility

Existing programs that use `+` on `Int` continue to work because `Num(Int)` instance is in the prelude. The only change is how the type is resolved.

## Testing strategy

### Unit tests

- `add(1, 2)` still type-checks as `Int` (via `Num(Int)` instance)
- `add(1.0, 2.0)` type-checks as `Float` (via `Num(Float)` instance)
- `add(x, y)` with `x : a, y : a, [Num(a)]` type-checks polymorphically
- Codegen: monomorphic `add(1, 2)` still produces `Kernel.+(1, 2)`

### Integration tests

- All existing programs pass (regression)
- New polymorphic arithmetic: `def double([Num(a)], x : a) : a do add(x, x) end`

## Verification

```bash
mix test  # full test suite — regression check
mix format --check-formatted
mix dialyzer
```
