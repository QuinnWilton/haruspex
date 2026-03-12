# Erasure

## Purpose

Enforces multiplicity discipline during type checking and removes erased (0-multiplicity) terms before codegen. Types, type arguments, and proof terms marked with `0` multiplicity do not exist at runtime. See [[../decisions/d19-erasure-annotations]].

## Dependencies

- `Haruspex.Core` — multiplicity annotations on Pi/Lam
- `Haruspex.Check` — multiplicity enforcement during checking
- `Haruspex.Erase` — erasure pass between check and codegen

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

## Erasure pass (`Haruspex.Erase`)

A dedicated pass between check and codegen that walks each term alongside its type and removes all erased content. This keeps codegen simple — it never encounters erasure concerns.

```elixir
@spec erase(Core.term(), Core.term()) :: Core.term()
```

### Rules

1. `Lam(:zero, body)` with type `Pi(:zero, dom, cod)` — unwrap: return `erase(body, cod)`
2. `Lam(:omega, body)` with type `Pi(:omega, dom, cod)` — keep: `{:lam, :omega, erase(body, cod)}`
3. `App(f, a)` where `f`'s type is `Pi(:zero, dom, cod)` — skip argument: `erase(f, type_of_f)` applied to codomain
4. `App(f, a)` where `f`'s type is `Pi(:omega, dom, cod)` — keep: `{:app, erase(f, type_of_f), erase(a, dom)}`
5. `Pi(_, _, _)` → `{:erased}`
6. `Sigma(_, _)` → `{:erased}`
7. `Type(_)` → `{:erased}`
8. `Meta(id)` → raise `Haruspex.CompilerBug` ("unsolved meta reached erasure")
9. `InsertedMeta(id, mask)` → raise `Haruspex.CompilerBug` ("unsolved inserted meta reached erasure")
10. `Spanned(span, inner)` → `erase(inner, type)` (strip span, recurse)
11. `Let(def, body)` — if the bound value is type-level (its type is `Type(_)` or `Pi` returning `Type`), eliminate the let entirely and erase just the body. Otherwise, erase both def and body, preserving the let.
12. All other terms (`Var`, `Lit`, `Builtin`, `Extern`, `Pair`, `Fst`, `Snd`) — recurse structurally

### Postconditions

After erasure, the output term:
- Contains no `:zero` multiplicity lams
- Contains no `Pi`, `Sigma`, or `Type` nodes (replaced with `{:erased}`)
- Contains no `Spanned` wrappers
- Contains no `Meta` or `InsertedMeta` nodes
- Every remaining `App` corresponds to a runtime argument

### Type reconstruction for App erasure

The erasure pass requires the type of each subterm to determine whether an `App`'s argument is erased. The type is threaded through the traversal:

- At the top level, `erase/2` receives the term and its checked type
- For `Lam(:omega, body)` with type `Pi(:omega, dom, cod)`: the body's type is `cod`
- For `App(f, a)` with result type `T`: `f`'s type is `Pi(mult, dom, cod)` where `cod[a] = T`. In practice, the erasure pass synthesizes `f`'s type by accumulating Pi types during traversal.

## Implementation notes

- Usage tracking is part of the typing context, incremented in `synth(Var(ix))`
- The check happens at binder exit (end of lambda body, end of let scope)
- Error messages should explain: "variable `proof` has multiplicity 0 and cannot be used here (computational position)"
- Linear types (mult = :one, "use exactly once") are a future extension — the infrastructure is designed to support it

## Testing strategy

- **Unit tests**: erased variable used computationally → error; used in type position → OK
- **Unit tests (Erase pass)**: each erasure rule individually; unsolved meta → CompilerBug; spanned terms stripped
- **Integration**: `head({a : Type}, {0 n : Nat}, xs : Vec(a, succ(n)))` compiles to a function of one argument
- **Property tests**: erased terms never appear in codegen output; output of `Erase.erase/2` contains no `:zero` lams, no `Pi`/`Sigma`/`Type` nodes
