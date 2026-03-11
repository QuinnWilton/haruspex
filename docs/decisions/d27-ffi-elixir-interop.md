# D27: FFI and Elixir interop

**Decision**: External functions are declared with `@extern Module.function/arity` annotations on bodyless type signatures. Extern types are trusted axioms. There is no `Dynamic` type or escape hatch. Runtime representations are BEAM terms with no marshaling.

**Rationale**: Haruspex compiles to Elixir, so its runtime values *are* BEAM terms — integers are integers, lists are lists, functions are funs. This makes FFI zero-cost by construction: no boxing, no marshaling, no foreign pointer wrappers. The only thing the FFI needs to bridge is the *type* gap: Elixir functions don't carry Haruspex types, so the programmer declares them with `@extern` and the checker trusts the declaration. This is the same approach as Idris 2's `%foreign` and Haskell's `foreign import`.

**Resolves**: [[../tasks/t02-ffi-elixir-interop]]

## Declaring external functions

An extern declaration is a type signature with no body, annotated with the target function:

```elixir
@extern Enum.map/2
def map(xs : List(a), f : a -> b) : List(b)

@extern :math.sqrt/1
def sqrt(x : Float) : Float

@extern IO.puts/1
def puts(s : String) : Atom
```

The `@extern` annotation takes the standard Elixir function reference syntax: `Module.function/arity`. Erlang modules use the atom prefix: `:module.function/arity`.

The declared arity in `@extern` is the **Elixir arity** (after erasure), not the Haruspex arity. If the Haruspex signature has erased type parameters, those don't count:

```elixir
# Haruspex arity: 3 (a, xs, f)
# Elixir arity after erasure: 2 (xs, f) — a is erased
@extern Enum.map/2
def map({a : Type}, xs : List(a), f : a -> b) : List(b)
```

## Trust boundary

Extern types are **axioms**. The checker accepts the declared type without verification. If the declared type doesn't match the actual Elixir function's behavior, the result is a runtime error.

The `@extern` annotation is the visual marker of trust. Any function with `@extern` is outside the checker's guarantees. Code review should scrutinize extern declarations carefully.

There is no `unsafe` block, no `Dynamic` type, and no `believe_me`. If you can't type an Elixir function accurately in Haruspex's type system, you can't call it. This constraint relaxes over time as the type system grows (ADTs for union returns, typeclasses for polymorphism, etc.).

## Core representation

Extern declarations elaborate to a new core term form:

```elixir
@type term ::
  ...
  | {:extern, module(), atom(), arity()}  # external function reference
```

The extern term carries the target MFA. It has no body — the checker assigns it the declared type and stops. In the value domain:

```elixir
{:vextern, module(), atom(), arity()}
```

Extern values do not delta-reduce during NbE. They are opaque at the type level — you can't compute with an extern during type checking. This is correct: extern functions may have side effects, may not terminate, and their behavior is unknown to the type system.

## Codegen

Extern calls compile to direct Elixir function calls:

```
compile(App(App(Extern(:math, :sqrt, 1), arg)))
  → :math.sqrt(compile(arg))

compile(Extern(:math, :sqrt, 1))
  → &:math.sqrt/1
```

Partially applied externs compile to function captures, fully applied externs to direct calls. No wrapping, no indirection.

## Argument order at the boundary

Haruspex functions may have erased arguments (types, proofs) that don't exist at runtime. The extern declaration's parameter list defines the **mapping** between Haruspex arguments and Elixir arguments:

```elixir
@extern Enum.map/2
def map({a : Type}, {b : Type}, xs : List(a), f : a -> b) : List(b)
```

After erasure, `a` and `b` disappear. The remaining arguments `(xs, f)` are passed to `Enum.map/2` positionally.

## Calling Haruspex from Elixir

Since Haruspex compiles to Elixir modules with `def`/`defp`, calling Haruspex from Elixir is automatic. The generated API respects:

- **Erased arguments are absent**: type and proof parameters don't appear in the Elixir function signature
- **Dictionary arguments are resolved**: typeclass dictionaries (Tier 6) are resolved at the Haruspex module boundary, not leaked to callers
- **Runtime representations are standard**: ADTs are tagged tuples, records are structs, functions are funs

```elixir
# Haruspex source
def identity({a : Type}, x : a) : a do x end

# Generated Elixir (a is erased)
def identity(x), do: x
```

## Higher-order FFI

Haruspex functions compile to Elixir funs with the correct runtime arity (after erasure). Passing them to Elixir higher-order functions works naturally:

```elixir
@extern Enum.map/2
def map({a : Type}, {b : Type}, xs : List(a), f : a -> b) : List(b)

def doubles(xs : List(Int)) : List(Int) do
  map(xs, fn(x) do x * 2 end)
end
```

The lambda `fn(x) do x * 2 end` compiles to an Elixir fun of arity 1, which is what `Enum.map` expects.

## BEAM types at the boundary

No marshaling is needed. Haruspex types and BEAM terms share runtime representations:

| Haruspex type | BEAM runtime value |
|--------------|-------------------|
| `Int` | integer (arbitrary precision) |
| `Float` | float (IEEE 754) |
| `String` | binary (UTF-8) |
| `Atom` | atom |
| `Bool` | `true \| false` atoms |
| `List(a)` | list |
| `a -> b` | fun/1 |
| ADT constructors | tagged tuples `{:ctor, ...}` |
| Records | structs `%Module{...}` |
| `Sigma(a, b)` | 2-tuple `{a, b}` |

This zero-cost representation is a direct consequence of compiling to Elixir rather than a custom runtime.

## Future extensions

| Extension | What changes |
|-----------|-------------|
| `Dynamic` type | New builtin type with explicit cast operations; requires runtime type checking |
| NIFs | `@nif` annotation, similar to `@extern` but with NIF loading machinery |
| Ports | Out of scope; standard Elixir port API accessible via `@extern` |
| Typespec generation | Codegen emits `@spec` annotations derived from Haruspex types |
| Callback behaviours | `@callback` declarations for OTP behaviours, verified against extern types |
