# Tier 6: Instance declarations and search

**Module**: `Haruspex.TypeClass.Search`
**Subsystem doc**: [[../../subsystems/18-type-classes]]
**Decisions**: d20 (type classes), d08 coherence additions

## Scope

Implement instance declarations, depth-bounded instance search with specificity-based overlap resolution, superclass resolution, and orphan warnings.

## Implementation

### Instance declarations

```elixir
instance Eq(Int) do def eq(x, y) do x == y end end
instance [Eq(a)] => Eq(List(a)) do def eq(xs, ys) do ... end end
```

- Elaborate instance: check method implementations against class method types, applied to instance args
- Build dictionary value: record with method implementations
- Register in instance database

### Instance search

1. Goal: `{class_name, [type_args]}`
2. Filter instances whose head unifies with goal
3. Resolve instance constraints recursively (depth-bounded, default 32)
4. If multiple matches: pick most specific (substitution ordering per d20). Ambiguous → error.
5. Orphan detection: warn if instance is in neither class's nor type's module

### Specificity

Instance A is more specific than B if A's head is a substitution instance of B's head. `Eq(List(Int))` is more specific than `[Eq(a)] => Eq(List(a))`.

## Testing strategy

### Unit tests (`test/haruspex/instance_search_test.exs`)

- Simple search: `Eq(Int)` found from registered instance
- Constrained search: `Eq(List(Int))` resolves via `[Eq(a)] => Eq(List(a))` + `Eq(Int)`
- Superclass: searching for `Eq(a)` when `Ord(a)` is available → extract from Ord dictionary
- Depth limit: recursive instance chain exceeding depth → error
- Specificity: `Eq(List(Int))` beats `Eq(List(a))` when both available
- Ambiguity: two incomparable instances → error
- Not found: `Eq(MyType)` with no instance → clear error
- Orphan: instance in wrong module → warning

### Property tests

- **Determinism**: same database + goal → same result
- **Idempotence**: searching twice → same result

### Integration tests

- `member(42, [1, 2, 42])` resolves `Eq(Int)` automatically
- Polymorphic function with instance constraint type-checks and compiles

## Verification

```bash
mix test test/haruspex/instance_search_test.exs
mix format --check-formatted
mix dialyzer
```
