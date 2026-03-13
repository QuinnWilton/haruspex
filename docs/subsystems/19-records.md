# Records

## Purpose

Named record types with dependent fields, compiling to Elixir structs. Records are single-constructor ADTs with named projections and eta equality. They serve as the carrier type for type class dictionaries. See [[../decisions/d21-records]].

## Dependencies

- `Haruspex.Core` — record term forms (or desugaring to ADT)
- `Haruspex.ADT` — underlying single-constructor representation
- `Haruspex.Elaborate` — surface `record` → core
- `Haruspex.Check` — eta rule, projection typing
- `Haruspex.Codegen` — struct generation

## Key types

```elixir
@type record_decl :: %{
  name: atom(),
  params: [{atom(), Core.term()}],           # type parameters
  fields: [{atom(), Core.term()}],           # field name + type (telescope)
  span: Pentiment.Span.Byte.t()
}
```

## Public API

```elixir
@spec elaborate_record(elab_ctx(), AST.record_decl()) :: {:ok, record_decl()} | {:error, term()}
@spec record_to_adt(record_decl()) :: ADT.adt_decl()
  # Desugar to single-constructor ADT
@spec projection_type(record_decl(), atom()) :: Core.term()
  # Compute the type of a field projection
@spec constructor_type(record_decl()) :: Core.term()
  # Full type of the record constructor (as a dependent function)
```

## Dependent fields (telescopes)

Record fields form a telescope -- each field's type may depend on previous fields:

```elixir
record Sigma(a : Type, b : a -> Type) do
  fst : a
  snd : b(fst)   # type depends on value of fst
end
```

The constructor type is a nested Pi:
```
mk_Sigma : (a : Type) -> (b : a -> Type) -> (fst : a) -> (snd : b(fst)) -> Sigma(a, b)
```

Projection types:
```
Sigma.fst : Sigma(a, b) -> a
Sigma.snd : (s : Sigma(a, b)) -> b(s.fst)   # depends on the record value!
```

## Eta rule

Two record values are equal if all fields are equal:
```
p : Point  ⟹  %Point{x: p.x, y: p.y} ≡ p
```

In NbE, this is implemented via type-directed readback: when quoting a neutral at record type, eta-expand by projecting all fields. This reuses the existing eta machinery for Sigma types ([[../decisions/d15-eta-expansion]]).

## Surface syntax

```elixir
# Declaration
record Point do
  x : Float
  y : Float
end

# Parameterized record
record Pair(a : Type, b : Type) do
  fst : a
  snd : b
end

# Construction
p = %Point{x: 1.0, y: 2.0}

# Projection
p.x

# Update
q = %{p | x: 3.0}

# Pattern matching (via single constructor)
case p do
  %Point{x: x, y: y} -> x + y
end
```

## Codegen

```elixir
# Record declaration →
defmodule Point do
  defstruct [:x, :y]
end

# Construction →
%Point{x: 1.0, y: 2.0}

# Projection →
point.x

# Update →
%{point | x: 3.0}
```

## Update type-checking for dependent fields

When updating a field that other fields depend on, the dependent fields must be re-checked. If the updated field has dependents, the user must provide new values for ALL dependent fields in the same update expression.

```
# Given:
record Sigma(a : Type, b : a -> Type) do
  fst : a
  snd : b(fst)
end

# This is OK — fst has no dependents being kept:
%{s | fst: new_val, snd: new_snd}

# This is an ERROR — snd depends on fst, but snd is not provided:
%{s | fst: new_val}
# Error: field `snd` depends on updated field `fst` — must provide new value for `snd`

# This is always OK — snd has no dependents:
%{s | snd: new_snd}
```

The checker computes the dependency graph of fields from the telescope structure. When elaborating an update `%{r | fields...}`, it verifies that for every updated field, all fields that transitively depend on it are also present in the update.

## Pattern matching syntax

Records support pattern matching via the single constructor:

```
# Full pattern — all fields bound
case p do
  %Point{x: x, y: y} -> x + y
end

# Partial pattern — unmentioned fields are wildcards
case p do
  %Point{x: x} -> x    # y is implicitly _
end

# Nested patterns
case pair do
  %Pair{fst: %Point{x: x}, snd: s} -> x + s
end
```

Surface `%R{f1: p1, f2: p2}` desugars to a constructor pattern `mk_R(p1, p2)` where unmentioned fields become wildcards. Field order in the pattern does not matter — the elaborator reorders to match the declaration order.

## Dot syntax elaboration

`r.field` elaborates to a projection function application. For each field in a record, a projection function is generated:

```
record Point do x : Float; y : Float end

# Generates projections:
Point.x : Point -> Float
Point.x = fn(p : Point) -> case p do mk_Point(x, _) -> x end

Point.y : Point -> Float
Point.y = fn(p : Point) -> case p do mk_Point(_, y) -> y end
```

For dependent records, projection types reference the record value:

```
record Sigma(a : Type, b : a -> Type) do fst : a; snd : b(fst) end

Sigma.fst : {a : Type} -> {b : a -> Type} -> Sigma(a, b) -> a
Sigma.snd : {a : Type} -> {b : a -> Type} -> (s : Sigma(a, b)) -> b(s.fst)
```

The elaborator resolves `r.field` by:
1. Infer the type of `r` — must be a record type `R(args...)`
2. Look up `field` in `R`'s field list
3. Emit `App(R.field, r)` (with implicit args inserted as needed)

If `r`'s type is not a record type, or the field doesn't exist, produce an error.

## Implementation notes

- Records desugar to ADTs in core but retain their record identity for error messages and codegen
- Field order matters (it defines the telescope structure)
- Anonymous records (struct literals without a declared type) are NOT supported -- all records must be declared
- Record update (`%{r | field: val}`) elaborates to reconstruction: `%R{f1: r.f1, ..., field: val, ..., fn: r.fn}`
- Dot syntax `r.field` elaborates to a projection function application

## Testing strategy

- **Unit tests**: Record declaration, construction, projection, update
- **Integration**: Dependent records (Sigma-like), record eta, type class dictionaries as records
- **Codegen tests**: Records compile to working Elixir structs
- **Property tests**: Projection after construction retrieves the original value
