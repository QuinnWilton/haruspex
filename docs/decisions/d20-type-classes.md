# D20: Type classes via instance arguments and dictionary passing

**Decision**: Implement type classes as instance arguments with compile-time proof search, using dictionary-passing codegen with an optional protocol bridge for single-parameter classes.

**Rationale**: Without type classes, dependent types are impractical for real programs — you can't overload `+`, `==`, `map`, or `show`, and every polymorphic operation requires manually threading implementation records. Every usable dependently typed language has some form of this: Lean type classes, Agda instance arguments, Idris 2 interfaces. The BEAM ecosystem already has protocols for dynamic dispatch, but type classes provide richer compile-time guarantees including multi-parameter dispatch, superclass hierarchies, and proof-carrying instances.

**Mechanism**:

Instance arguments are a third kind of implicit, written with `[]` brackets in the surface syntax:

```elixir
class Eq(a) do
  eq(x : a, y : a) : Bool
end

instance Eq(Int) do
  def eq(x, y) do x == y end
end

# Instance argument resolved by search:
def member({a : Type}, [eq : Eq(a)], x : a, xs : List(a)) : Bool do
  ...
end

# Usage — Eq(Int) instance found automatically:
member(42, [1, 2, 42])
```

**Instance search algorithm**:
1. When the checker encounters an instance argument `[C(T1, ..., Tn)]`, it searches the instance database
2. Search is depth-first with backtracking over registered instances
3. An instance matches if its head unifies with the goal
4. Instance constraints (e.g., `instance [Eq(a)] => Eq(List(a))`) trigger recursive search
5. Search depth is bounded (default: 32) to prevent divergence
6. Ambiguous matches (multiple non-overlapping instances) are an error

**Superclasses**:
```elixir
class [Eq(a)] => Ord(a) do
  compare(x : a, y : a) : Ordering
end
```
The superclass constraint means every `Ord` instance implicitly provides `Eq`. The dictionary carries a nested `Eq` dictionary field.

**Codegen — dictionary passing**:
- Each class becomes a struct (record) type at runtime: `%Eq{eq: &Eq.Int.eq/2}`
- Instance arguments compile to regular function parameters
- The compiler passes dictionaries explicitly in generated code
- Method calls compile to field access on the dictionary: `dict.eq(x, y)`

**Protocol bridge** (optional, for Elixir interop):
- Single-parameter type classes with no proof fields can optionally generate an Elixir protocol
- `@protocol` annotation on a class declaration triggers protocol generation
- Elixir types implementing the protocol can be used where the type class is expected
- Bridge is one-directional: Haruspex → Elixir protocol. Elixir protocol → Haruspex instance requires explicit wrapping.

**Instance coherence** (resolves [[../tasks/t08-instance-coherence]]):

- **Overlap resolution**: When multiple instances match a goal, the most specific one wins. Instance A is more specific than B if A's head is a substitution instance of B's head (A is strictly more concrete). If neither is more specific, the match is ambiguous → error. Example: `Eq(List(Int))` beats `[Eq(a)] => Eq(List(a))` because `List(Int)` is a substitution instance of `List(a)`.
- **Orphan instances**: Allowed, but produce a warning when the instance is defined in neither the class's module nor the type's module. This is practical — you sometimes need `instance Show(ThirdPartyType)` — but the warning nudges toward the right module.
- **Local coherence**: Instances are scoped to imports ([[d29-module-system]]). No global registry. If two imports provide instances that overlap without a specificity winner, it's ambiguous → error.
- **No manual priority**: Specificity ordering handles the common case. Manual priority annotations are deferred indefinitely.

**Interaction with other features**:
- Instance arguments interact with elaboration ([[d08-elaboration-boundary]]): the elaborator inserts instance search goals
- Instance dictionaries are erased when the class carries only proof fields ([[d19-erasure-annotations]])
- Default method implementations use the class dictionary (self-referential)

**Trade-off**: Dictionary passing has runtime overhead vs. monomorphization (what GHC does with specialization). On the BEAM, dictionary passing is natural — it's just passing a struct. Monomorphization is incompatible with separate compilation and hot code reloading. Dictionary passing is the right choice for the BEAM.

See [[d21-records]], [[../subsystems/18-type-classes]].
