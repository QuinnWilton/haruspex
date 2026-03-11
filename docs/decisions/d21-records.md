# D21: Records as single-constructor ADTs with named projections

**Decision**: Records are single-constructor algebraic data types with named fields, compiling to Elixir structs. They are the carrier type for type class dictionaries.

**Rationale**: Sigma types (dependent pairs) are theoretically sufficient for products but practically unusable beyond 2 fields — `{x : Int, {y : Int, {z : Int, Unit}}}` is unreadable. Named fields with dot-syntax projections are essential for ergonomic programming. Records also serve as the representation for type class dictionaries ([[d20-type-classes]]), making them a load-bearing feature. The mapping to Elixir structs is natural and preserves BEAM idioms.

**Surface syntax**:
```elixir
# Record declaration (Elixir struct-like)
record Point do
  x : Float
  y : Float
end

# Dependent record (field types can reference earlier fields)
record Sigma(a : Type, b : a -> Type) do
  fst : a
  snd : b(fst)
end

# Construction
p = %Point{x: 1.0, y: 2.0}

# Projection (dot syntax)
p.x

# Update
q = %{p | x: 3.0}
```

**Core representation**: Records desugar to single-constructor ADTs in the core:
```
record Point { x : Float, y : Float }
  ≡
data Point = mk_Point(x : Float, y : Float)
  + projection functions: Point.x : Point -> Float, Point.y : Point -> Float
  + eta rule: mk_Point(p.x, p.y) ≡ p
```

This means:
- Records participate in dependent typing (field types can depend on earlier fields — a telescope)
- The positivity checker handles records automatically (single constructor, always positive)
- Pattern matching on records works via the single constructor

**Eta for records**: Two record values are equal if all their fields are equal. This is implemented via the eta rule for the underlying Sigma/single-constructor ADT in NbE. See [[d15-eta-expansion]].

**Codegen**: Records compile to Elixir structs:
- `record Point` → `defmodule Point do defstruct [:x, :y] end`
- `%Point{x: 1.0, y: 2.0}` → `%Point{x: 1.0, y: 2.0}`
- `p.x` → `p.x` (Elixir's native dot access on structs)
- `%{p | x: 3.0}` → `%{p | x: 3.0}`

**Type class dictionary representation**: A class like `Eq(a)` generates a record:
```elixir
record Eq(a : Type) do
  eq : a -> a -> Bool
end
```
Instances populate these records. The protocol bridge (when enabled) generates a corresponding `defprotocol`.

**Trade-off**: Making records a core feature (rather than pure sugar) means the core term language is slightly larger. But the alternative — encoding everything as nested Sigma types — makes error messages incomprehensible and codegen awkward. First-class records are worth the complexity.

See [[d20-type-classes]], [[d15-eta-expansion]], [[../subsystems/19-records]].
