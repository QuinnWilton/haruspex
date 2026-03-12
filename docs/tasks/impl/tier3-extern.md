# Tier 3: Extern functions

**Decisions**: d27 (FFI and Elixir interop)

## Scope

Implement `@extern` declarations: parsing, elaboration (type as axiom, no body), checker validation, and codegen (direct Elixir calls).

## Implementation

### Surface syntax

```elixir
@extern Enum.map/2
def map({a : Type}, {b : Type}, xs : List(a), f : a -> b) : List(b)
```

### Pipeline

1. **Parser**: `@extern` annotation captures `{module, function, arity}`, followed by bodyless `def`
2. **Elaboration**: elaborate the type signature. No body to elaborate. Store as `{:extern, module, function, arity}` in core.
3. **Checker**: the declared type is an axiom — no body to check. Register the name + type in context. **Verify** that the `@extern` arity matches the count of non-erased (`:omega`) parameters in the type signature.
4. **Erase**: `{:extern, mod, fun, arity}` passes through unchanged (already runtime-level)
5. **Codegen**: extern calls compile to direct Elixir function calls. Partially applied → function capture or lambda. Fully applied → direct call.

### Extern arity vs Haruspex arity

The `@extern` arity is the Elixir arity after erasure. Erased type parameters don't count.

Example:
```elixir
@extern Enum.map/2
def map({a : Type}, {b : Type}, xs : List(a), f : a -> b) : List(b)
```

Haruspex arity: 4 (a, b, xs, f). Erased params: a, b (both `Type`). Runtime arity: 2 (xs, f). `@extern` arity: 2. Match confirmed.

### Arity mismatch detection

During checking, count the `:omega` parameters in the elaborated type:

```elixir
defp count_runtime_params({:pi, :omega, _dom, cod}), do: 1 + count_runtime_params(cod)
defp count_runtime_params({:pi, :zero, _dom, cod}), do: count_runtime_params(cod)
defp count_runtime_params(_), do: 0
```

If the count doesn't match the declared `@extern` arity, emit a checker error:
```
extern arity mismatch: @extern Enum.map/2 declares arity 2, but the type signature has 3 non-erased parameters
```

### Codegen rules (post-erasure)

After erasure strips type parameters, the extern term flows through to codegen:

- Unapplied: `Extern(mod, fun, arity)` → `&mod.fun/arity`
- Fully applied: `App(...App(Extern(mod, fun, n), a1)..., an)` → `mod.fun(a1, ..., an)`
- Partially applied: wrap in lambda for remaining args

## Testing strategy

### Unit tests (`test/haruspex/extern_test.exs`)

**Parser:**
- Parse `@extern :math.sqrt/1 def sqrt(x : Float) : Float` → correct AST node with `{:math, :sqrt, 1}`
- Parse `@extern Enum.map/2 def map(...)` → correct AST with `{Enum, :map, 2}`

**Elaboration:**
- Elaborate → `{:extern, :math, :sqrt, 1}` with type `Float -> Float`
- Bodyless def does not produce a body term

**Checker:**
- Extern registered as axiom in context with correct type
- Arity match: `@extern Enum.map/2` with 2 non-erased params → OK
- Arity mismatch: `@extern Enum.map/2` with 3 non-erased params → error with clear message
- Erased params correctly excluded from arity count: `@extern Enum.map/2 def map({a : Type}, {b : Type}, xs, f)` → 2 runtime params → OK

**Codegen:**
- Unapplied extern: `Extern(:math, :sqrt, 1)` → `&:math.sqrt/1`
- Fully-applied extern: `App(Extern(:math, :sqrt, 1), x)` → `:math.sqrt(x)` in Elixir AST
- Partially-applied multi-arg extern: `App(Extern(Enum, :zip, 2), xs)` → `fn ys -> Enum.zip(xs, ys) end`
- Extern in higher-order position: passed as argument to another function

**Erasure:**
- Extern with erased type params: after erasure, only runtime args remain
- Extern with multiple erased params interspersed: `@extern Foo.bar/2 def bar({a : Type}, x : a, {b : Type}, y : b)` → 2 args after erasure

### Integration tests

- Call `:math.sqrt` from Haruspex: source → compile → eval → `sqrt(4.0)` returns `2.0`
- Higher-order: pass Haruspex function to Elixir's `Enum.map` → correct results
- Erlang module extern: `:math.pow/2` → `pow(2.0, 10.0)` returns `1024.0`
- Multiple externs in one module: two `@extern` declarations, both callable

## Verification

```bash
mix test test/haruspex/extern_test.exs
mix format --check-formatted
mix dialyzer
```
