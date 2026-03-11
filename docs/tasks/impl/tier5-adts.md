# Tier 5: Algebraic data types

**Module**: `Haruspex.ADT`
**Subsystem doc**: [[../../subsystems/12-adts]]
**Decisions**: d16 (strict positivity), d25 (mutual types), d26 (Bool as ADT)

## Scope

Implement type declarations, constructor typing, strict positivity checking, and the internal Bool ADT.

## Implementation

### Type declarations

- Parse `type Option(a : Type) do none : Option(a); some(x : a) : Option(a) end`
- Elaborate: compute constructor types as Pi types, register type and constructors in context
- Positivity check: verify all constructor fields are strictly positive in the declared type name

### Constructor types

`some : {a : Type} -> a -> Option(a)` — constructors are functions from their fields to the fully applied type.

### Bool (d26)

Internally defined ADT injected before user code:
```
type Bool : Type 0 do true : Bool; false : Bool end
```
`if c then a else b` desugars to `case c do true -> a; false -> b end`.

### Mutual inductive types (d25)

Types in `mutual do ... end` are jointly positivity-checked. All type names in the group are treated as potentially recursive.

### Universe levels

`type T(a : Type l) : Type l` — the ADT lives at the max universe level of its parameters.

## Testing strategy

### Unit tests (`test/haruspex/adt_test.exs`)

- **Positivity**: `Option`, `List`, `Nat` accepted. `type Bad(a) do mk(a -> Bad(a) -> Int) end` → rejected (negative occurrence)
- **Constructor types**: `some` has type `{a : Type} -> a -> Option(a)`
- **Bool**: `true : Bool`, `false : Bool`, `if` desugars to case
- **Mutual positivity**: `Tree`/`Forest` example accepted. Negative cross-reference rejected.
- **Zero-constructor types**: `type Void do end` accepted (empty type)
- **Universe levels**: `type T(a : Type 0) : Type 0` checks

### Property tests

- **Random ADTs**: randomly generated type declarations with random field types → accepted iff strictly positive

### Integration tests

- Define `Option`, pattern match on it, type-checks and compiles
- Define `Nat`, write `add`, type-checks
- `if true then 1 else 2` → `1`

## Verification

```bash
mix test test/haruspex/adt_test.exs
mix format --check-formatted
mix dialyzer
```
