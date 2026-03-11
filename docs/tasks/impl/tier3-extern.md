# Tier 3: Extern functions

**Decisions**: d27 (FFI and Elixir interop)

## Scope

Implement `@extern` declarations: parsing, elaboration (type as axiom, no body), and codegen (direct Elixir calls).

## Implementation

### Surface syntax

```elixir
@extern Enum.map/2
def map({a : Type}, {b : Type}, xs : List(a), f : a -> b) : List(b)
```

### Pipeline

1. **Parser**: `@extern` annotation captures `{module, function, arity}`, followed by bodyless `def`
2. **Elaboration**: elaborate the type signature. No body to elaborate. Store as `{:extern, module, function, arity}` in core.
3. **Checker**: the declared type is an axiom — no body to check. Register the name + type in context.
4. **Codegen**: extern calls compile to direct Elixir function calls. Partially applied → function capture. Fully applied → direct call.

### Extern arity vs Haruspex arity

The `@extern` arity is the Elixir arity after erasure. Erased type parameters don't count.

## Testing strategy

### Unit tests

- Parse `@extern :math.sqrt/1 def sqrt(x : Float) : Float` → correct AST
- Elaborate → `{:extern, :math, :sqrt, 1}` with type `Float -> Float`
- Codegen → `:math.sqrt(x)` in Elixir AST
- Erased params: `@extern Enum.map/2 def map({a : Type}, ...)` → arity 2 matches after erasure

### Integration tests

- Call `:math.sqrt` from Haruspex: source → compile → eval → correct result
- Higher-order: pass Haruspex function to Elixir's `Enum.map` → works

## Verification

```bash
mix test test/haruspex/extern_test.exs
mix format --check-formatted
mix dialyzer
```
