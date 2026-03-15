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
  dict_builder: dict_builder()
}

# dict_builder takes one sub-dictionary per instance constraint and returns
# the assembled dictionary value. Arity equals the length of `constraints`.
# For an unconstrained instance like Eq(Int), arity is 0 (nullary function).
# For [Eq(a)] => Eq(List(a)), arity is 1 (receives the Eq(a) dictionary).
@type dict_builder :: (... -> Value.value())

@type search_result ::
  {:found, Value.value()}
  | {:not_found, class_constraint()}
  | {:ambiguous, [instance_entry()]}
  | {:depth_exceeded, class_constraint(), non_neg_integer()}
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
search(db, level, goal = {class_name, args}, depth \\ 0, max_depth \\ 32):
  if depth >= max_depth do
    {:depth_exceeded, goal, depth}
  end

  instances = db[class_name] || []

  matches = for inst <- instances do
    # Try to unify instance head with goal args
    case try_unify(level, inst.args, args):
      :ok ->
        # Check instance constraints recursively
        case resolve_constraints(db, level, inst.constraints, depth + 1, max_depth):
          {:ok, sub_dicts} ->
            dict = inst.dict_builder.(sub_dicts)
            {:match, dict, inst}
          {:error, _} ->
            :no_match
      {:error, _} ->
        :no_match
  end

  case Enum.filter(matches, &match?({:match, _, _}, &1)):
    [{:match, dict, _}] -> {:found, dict}
    [] -> {:not_found, goal}
    multiple ->
      case pick_most_specific(multiple):
        {:ok, dict} -> {:found, dict}
        :ambiguous -> {:ambiguous, multiple}
```

### Search depth counting

Depth increments once per recursive constraint resolution, not per constraint at the same level. Depth is tracked per top-level search — each call to `search/3` from the checker starts at depth 0. When resolving an instance's constraints (e.g., `[Eq(a)] => Eq(List(a))` requires resolving `Eq(a)`), each recursive `search` call receives `depth + 1`. This means a chain of `n` nested instance resolutions hits the limit at `n = max_depth`, regardless of how many constraints appear at each level.

### Specificity comparison algorithm

`more_specific?(inst_a, inst_b)` determines whether instance A is strictly more specific than instance B:

1. Freshen B's head variables (create fresh flex vars for B's type parameters).
2. Attempt to unify A's head with B's freshened head, with B's variables as the flex side.
3. If unification succeeds, A is more specific than B (A's head is a substitution instance of B's head).
4. If unification fails, A is not more specific than B.

To resolve multiple matches:
1. For each candidate, check if it is more specific than all other candidates.
2. If exactly one candidate is more specific than all others, it wins.
3. If no single winner exists (two candidates are incomparable), the match is ambiguous → error.

Example: `Eq(List(Int))` vs `[Eq(a)] => Eq(List(a))`. Freshening B gives `Eq(List(a'))`. Unifying `List(Int)` with `List(a')` succeeds with `a' := Int`. So the concrete instance is more specific and wins.

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

## Instance database scoping

Instances are module-scoped. Each module maintains its own instance database containing:
1. Instances defined in the module itself.
2. Instances from all directly imported modules.

Diamond imports are deduplicated: if module C imports both A and B, and both A and B import module D, D's instances appear exactly once in C's database. Deduplication is by identity — the same instance declaration (same module + span) is never registered twice.

Import order does not affect instance resolution. The instance database is an unordered collection; resolution is determined by specificity, not declaration order.

## Default method implementation

Default methods in a class declaration are elaborated as regular functions that take the class dictionary as their first argument. When an instance omits a method that has a default, the dictionary is constructed with the default implementation.

Self-referential dictionaries (where a default method calls another method from the same class) are constructed in two passes in Elixir codegen:

1. **Pass 1**: Allocate the struct with placeholder values (`:pending`) for methods that reference the dictionary.
2. **Pass 2**: Fill in the self-referential methods as closures that capture the struct reference.

In practice, Elixir closures capture by reference, so a simple `%EqDict{eq: fn(x, y) -> ... end}` works — no explicit laziness or thunking is needed. The two-pass construction is only necessary when a default method's closure must reference the dictionary being built (e.g., a default `neq` that calls `eq` from the same dictionary).

## Implementation notes

- Orphan instance detection: warn when instance is in neither class's nor type's module
- Instance resolution results are cached during checking (same goal → same result)

## Testing strategy

- **Unit tests**: Instance search with simple instances, superclass resolution, ambiguity detection
- **Integration**: `member(42, [1, 2, 42])` resolves `Eq(Int)` and type-checks
- **Property tests**: Instance search is deterministic (same db + goal → same result)
- **Negative tests**: Missing instance → clear error; ambiguous instances → error listing candidates
- **Protocol bridge**: Single-param class generates working Elixir protocol
