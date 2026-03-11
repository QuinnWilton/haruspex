# Erasure

## Purpose

Enforces multiplicity discipline during type checking and removes erased (0-multiplicity) terms during codegen. Types, type arguments, and proof terms marked with `0` multiplicity do not exist at runtime. See [[../decisions/d19-erasure-annotations]].

## Dependencies

- `Haruspex.Core` — multiplicity annotations on Pi/Lam
- `Haruspex.Check` — multiplicity enforcement during checking
- `Haruspex.Codegen` — erasure during code generation

## Key types

```elixir
@type mult :: :zero | :omega
@type usage :: non_neg_integer()  # times a binding is used computationally

@type erasure_error ::
  {:erased_in_computational_position, atom(), Pentiment.Span.Byte.t()}
  | {:type_used_at_runtime, Pentiment.Span.Byte.t()}
```

## Checking rules

1. **Erased bindings** (mult = :zero): May only be used in erased positions:
   - Inside type annotations
   - As arguments to other erased parameters
   - In the type component of a Pi or Sigma
   - NOT in function bodies, let definitions, or case scrutinees (computational positions)

2. **Usage tracking**: For each binding, count computational uses. At the end of the scope:
   - :omega bindings: any number of uses allowed
   - :zero bindings: exactly 0 computational uses required

3. **Implicit erasure**: Type arguments to polymorphic functions are always erased, even without explicit `0` annotation. `{a : Type}` implicitly has mult = :zero.

## Codegen erasure

During code generation:
- `Lam(:zero, body)` → compile `body` directly (no lambda wrapping)
- `App(f, arg)` where Pi mult = :zero → compile `f` only (skip argument)
- `Pi(_, _, _)` → not compiled (type-level only)
- `Sigma(_, _)` → not compiled (type-level only)
- `Type(_)` → not compiled

## Implementation notes

- Usage tracking is part of the typing context, incremented in `synth(Var(ix))`
- The check happens at binder exit (end of lambda body, end of let scope)
- Error messages should explain: "variable `proof` has multiplicity 0 and cannot be used here (computational position)"
- Linear types (mult = :one, "use exactly once") are a future extension — the infrastructure is designed to support it

## Testing strategy

- **Unit tests**: Erased variable used computationally → error; used in type position → OK
- **Integration**: `head({a : Type}, {0 n : Nat}, xs : Vec(a, succ(n)))` compiles to a function of one argument
- **Property tests**: Erased terms never appear in codegen output
