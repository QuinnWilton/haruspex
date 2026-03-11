# Type classes

## Purpose

Implements type classes with instance search, dictionary representation, and optional protocol bridge for Elixir interop. Type classes are a third kind of implicit argument (alongside `{}` implicits and explicit) that the compiler resolves by searching a database of registered instances. See [[../decisions/d20-type-classes]].

## Dependencies

- `Haruspex.Core` — new term forms for class/instance declarations
- `Haruspex.Elaborate` — instance argument insertion
- `Haruspex.Check` — instance search during type checking
- `Haruspex.Unify` — unification during instance matching
- `Haruspex.Codegen` — dictionary-passing code generation
- `Haruspex.AST` — surface syntax for `class`, `instance`, `[]` brackets

## Key types

```elixir
@type class_decl :: %{
  name: atom(),
  params: [{atom(), Core.term()}],           # class type parameters
  superclasses: [class_constraint()],         # e.g., [Eq(a)] => Ord(a)
  methods: [{atom(), Core.term()}],           # method name + type
  defaults: [{atom(), Core.term()}],          # default implementations
  span: Pentiment.Span.Byte.t()
}

@type class_constraint :: {atom(), [Core.term()]}  # e.g., {:Eq, [Var(0)]}

@type instance_decl :: %{
  class_name: atom(),
  args: [Core.term()],                        # instance head, e.g., [Int] for Eq(Int)
  constraints: [class_constraint()],          # instance constraints
  methods: [{atom(), Core.term()}],           # method implementations
  span: Pentiment.Span.Byte.t()
}

@type instance_db :: %{atom() => [instance_entry()]}
  # class name → list of registered instances

@type instance_entry :: %{
  args: [Value.value()],
  constraints: [class_constraint()],
  dict_builder: (... -> Value.value())        # builds the dictionary value
}

@type search_result ::
  {:found, Value.value()}
  | {:not_found, class_constraint()}
  | {:ambiguous, [instance_entry()]}
```

## Public API

```elixir
@spec register_class(class_decl()) :: :ok
@spec register_instance(instance_decl()) :: :ok
@spec search(instance_db(), lvl(), class_constraint()) :: search_result()
@spec class_to_record_type(class_decl()) :: Core.term()
  # Generates the dictionary record type for a class
```

## Instance search algorithm

```
search(db, level, goal = {class_name, args}):
  instances = db[class_name] || []

  matches = for inst <- instances do
    # Try to unify instance head with goal args
    case try_unify(level, inst.args, args):
      :ok ->
        # Check instance constraints recursively
        case resolve_constraints(db, level, inst.constraints):
          {:ok, sub_dicts} ->
            dict = inst.dict_builder.(sub_dicts)
            {:match, dict}
          {:error, _} ->
            :no_match
      {:error, _} ->
        :no_match
  end

  case Enum.filter(matches, &match?({:match, _}, &1)):
    [{:match, dict}] -> {:found, dict}
    [] -> {:not_found, goal}
    multiple ->
      # Specificity: pick the most specific instance (head is a substitution
      # instance of all others). If no single winner, ambiguous → error.
      case pick_most_specific(multiple):
        {:ok, dict} -> {:found, dict}
        :ambiguous -> {:ambiguous, multiple}
```

Search is bounded by a configurable depth limit (default: 32) to prevent divergence from recursive instances like `instance [Eq(a)] => Eq(List(a))`.

## Dictionary representation

Each class generates a record type:

```
class Eq(a) do eq(x : a, y : a) : Bool end
  →
record EqDict(a : Type) do eq : a -> a -> Bool end
```

Superclass dictionaries are nested fields:

```
class [Eq(a)] => Ord(a) do compare(x : a, y : a) : Ordering end
  →
record OrdDict(a : Type) do
  eq_super : EqDict(a)
  compare : a -> a -> Ordering
end
```

## Codegen

- Class declarations → struct module definitions
- Instance declarations → module with struct construction function
- Instance arguments → regular function parameters in emitted Elixir
- Method calls → field access on dictionary struct: `dict.method(args)`

### Protocol bridge

When `@protocol` is annotated on a single-parameter class:
1. Generate `defprotocol` with same method signatures
2. Each `instance` also generates `defimpl`
3. Elixir callers use the protocol; Haruspex callers use dictionary passing
4. The bridge is opt-in and one-directional

## Implementation notes

- Instance database is module-scoped (instances registered per-module, visible to importers)
- Orphan instance detection: warn when instance is in neither class's nor type's module
- Default methods: elaborated as regular functions that take the class dictionary as an argument (self-referential dictionaries via lazy evaluation or two-pass construction)
- Instance resolution results are cached during checking (same goal → same result)

## Testing strategy

- **Unit tests**: Instance search with simple instances, superclass resolution, ambiguity detection
- **Integration**: `member(42, [1, 2, 42])` resolves `Eq(Int)` and type-checks
- **Property tests**: Instance search is deterministic (same db + goal → same result)
- **Negative tests**: Missing instance → clear error; ambiguous instances → error listing candidates
- **Protocol bridge**: Single-param class generates working Elixir protocol
