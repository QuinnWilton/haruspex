# Algebraic data types

## Purpose

Defines inductive type declarations, constructors, dependent pattern matching, strict positivity checking, and exhaustiveness checking. ADTs are the foundation for data structures like `Option`, `List`, `Vec`, `Nat`. See [[../decisions/d16-strict-positivity]].

## Dependencies

- `Haruspex.Core` — `{:data, ...}`, `{:con, ...}`, `{:case, ...}` terms
- `Haruspex.Check` — integration with type checker
- `Haruspex.Elaborate` — surface `type` declarations → core

## Key types

```elixir
@type adt_decl :: %{
  name: atom(),
  params: [{atom(), Core.term()}],        # type parameters with kinds
  constructors: [constructor_decl()],
  span: Pentiment.Span.Byte.t()
}

@type constructor_decl :: %{
  name: atom(),
  fields: [Core.term()],                  # field types (may reference params)
  return_type: Core.term(),               # fully applied result type
  span: Pentiment.Span.Byte.t()
}
```

## Public API

```elixir
@spec check_positivity(adt_decl()) :: :ok | {:error, {:negative_occurrence, atom(), Pentiment.Span.Byte.t()}}
@spec check_exhaustiveness([{atom(), non_neg_integer()}], [atom()]) :: :ok | {:error, {:missing_patterns, [atom()]}}
@spec elaborate_type_decl(elab_ctx(), AST.type_decl()) :: {:ok, adt_decl()} | {:error, term()}
@spec constructor_type(adt_decl(), atom()) :: Core.term()
  # Computes the full type of a constructor (as a Pi type)
```

## Strict positivity algorithm

```
check_positivity(decl):
  type_name = decl.name
  for each constructor in decl.constructors:
    for each field_type in constructor.fields:
      check_strictly_positive(type_name, field_type)

check_strictly_positive(name, type):
  case type:
    # Name appears as the whole type — OK (positive)
    {:data, ^name, _args} -> :ok

    # Arrow type: name must NOT appear in the domain
    {:pi, _, domain, codomain} ->
      if mentions(name, domain): {:error, :negative}
      check_strictly_positive(name, codomain)

    # Name doesn't appear — trivially positive
    _ when not mentions(name, type) -> :ok

    # Name appears nested in another type constructor
    {:data, other_name, args} ->
      # Check that other_name is strictly positive in the parameter
      # position where name appears (advanced — may defer)
      :ok  # simplified for now

    _ -> {:error, :negative}
```

## Pattern matching

### Dependent pattern matching
When matching on a value of type `Vec(a, n)`:
- Branch `vnil` refines `n` to `zero` in the branch body
- Branch `vcons(x, rest)` refines `n` to `succ(m)` for fresh `m`

This context refinement is implemented by unifying the constructor's return type with the scrutinee type, which may solve index variables.

### Exhaustiveness
Check that all constructors of the scrutinee's type are covered:
1. Collect constructor names from the ADT declaration
2. Collect constructor names from case branches
3. Missing constructors → warning (or error under `@total`)

## Codegen representation

ADT values at runtime are tagged tuples:
- `:none` → `:none` (atom)
- `some(x)` → `{:some, x}`
- `cons(x, rest)` → `{:cons, x, rest}`
- `vnil` → `:vnil`
- `vcons(x, rest)` → `{:vcons, x, rest}`

Pattern matching compiles to Elixir `case` with tuple patterns.

## Mutual inductive types

Mutual `type` declarations are supported inside `mutual do ... end` blocks (see [[../decisions/d25-mutual-blocks]]). The positivity checker handles mutual groups by treating all type names in the group as potentially recursive:

```
check_positivity(mutual_group):
  type_names = for decl <- mutual_group, collect: decl.name
  for each decl in mutual_group:
    for each constructor in decl.constructors:
      for each field_type in constructor.fields:
        for each name in type_names:
          check_strictly_positive(name, field_type)
```

A negative occurrence of any type in the group in any constructor field rejects the entire mutual group.

## Implementation notes

- Start with simple parameterized ADTs (Option, List, Nat)
- GADTs (where constructor return types have different indices) deferred initially
- Universe levels for ADTs: `type T(a : Type 0) : Type 0` — the ADT lives in the same universe as its parameters

## Testing strategy

- **Unit tests**: Positivity checker (positive and negative examples), exhaustiveness checker
- **Integration**: Define Option, List, Nat; pattern match on them; type-check successfully
- **Property tests**: Randomly generated ADTs accepted iff strictly positive
- **Negative tests**: Non-positive types rejected with clear error messages
