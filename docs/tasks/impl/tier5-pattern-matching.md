# Tier 5: Pattern matching

**Module**: `Haruspex.Pattern`
**Subsystem doc**: [[../../subsystems/12-adts]], [[../../subsystems/20-with-abstraction]]
**Decisions**: d26 (literal patterns), d30 (pattern match compilation)

## Scope

Implement case tree compilation, exhaustiveness checking, dependent pattern matching with index unification, and literal pattern support.

## Implementation

### Case tree compilation (d30)

1. Choose split variable: leftmost non-trivial pattern column
2. For each constructor of the split variable's type:
   a. Unify constructor's return type with scrutinee type (index refinement)
   b. If unification fails → impossible branch, skip
   c. Filter and recurse on remaining patterns
3. Literal patterns: always require wildcard catch-all

### Exhaustiveness checking

- Enumerate constructors from ADT declaration
- For each constructor, attempt unification with scrutinee type
- If unification succeeds and no branch matches → missing pattern error
- For `@total` functions: missing pattern is an error. For others: warning.
- Literal scrutinees: wildcard required (infinite types)

### Dependent pattern matching

When splitting `xs : Vec(a, succ(n))`:
- `vnil`: unify `Vec(a, zero)` with `Vec(a, succ(n))` → fails → impossible
- `vcons(x, rest)`: unify `Vec(a, succ(m))` with `Vec(a, succ(n))` → `m = n` → refine context

### Dot patterns (d30)

Inferred, not required. Forced positions (determined by index unification) are recognized automatically.

### Nested patterns (d30)

`cons(cons(x, _), _)` flattened to nested case trees during elaboration.

### First-match semantics (d30)

Overlapping patterns allowed. First match wins.

### Codegen

Case trees → Elixir `case` with tagged tuple patterns:
- `vnil` → `:vnil`
- `vcons(x, rest)` → `{:vcons, x, rest}`

## Testing strategy

### Unit tests (`test/haruspex/pattern_test.exs`)

- **Simple matching**: `case Some(42) do Some(x) -> x; None -> 0 end` → `42`
- **Nested patterns**: `cons(cons(x, _), _)` correctly flattened
- **Literal patterns**: `case 0 do 0 -> "zero"; _ -> "other" end`
- **Exhaustiveness**: missing constructor → warning/error
- **Exhaustiveness with types**: `Vec(a, succ(n))` only needs `vcons` branch
- **Impossible branches**: `case (xs : Vec(a, 0)) do vnil -> ... end` — `vcons` impossible
- **Overlap**: duplicate patterns → first match wins (no error)
- **Wildcard required**: literal scrutinee without wildcard → error

### Property tests

- **Coverage soundness**: if coverage check passes, every possible value of the scrutinee type has at least one matching branch

### Integration tests

- Pattern match on `Option`, `List`, `Nat` with type checking and codegen
- Dependent matching on `Vec` with index refinement
- `@total` function with exhaustive patterns passes; incomplete → error

## Verification

```bash
mix test test/haruspex/pattern_test.exs
mix format --check-formatted
mix dialyzer
```
