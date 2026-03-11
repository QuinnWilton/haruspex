# Tier 6: Type class declarations

**Module**: `Haruspex.TypeClass`
**Subsystem doc**: [[../../subsystems/18-type-classes]]
**Decisions**: d20 (type classes)

## Scope

Implement class declarations, dictionary record type generation, and superclass handling.

## Implementation

### Class declarations

```elixir
class Eq(a) do eq(x : a, y : a) : Bool end
class [Eq(a)] => Ord(a) do compare(x : a, y : a) : Ordering end
```

- Parse and elaborate class declarations
- Generate dictionary record type: `record EqDict(a : Type) do eq : a -> a -> Bool end`
- Superclass constraints become nested dictionary fields: `OrdDict` contains `eq_super : EqDict(a)`
- Register class in a class database (similar to instance database)
- Default methods: elaborate as functions taking the dictionary as argument

### Instance arguments

`[eq : Eq(a)]` in surface syntax → implicit parameter with instance search resolution.

## Testing strategy

### Unit tests (`test/haruspex/typeclass_test.exs`)

- Class declaration generates correct dictionary record type
- Superclass: `Ord` dictionary contains `Eq` sub-dictionary
- Method signatures accessible from class database
- Default methods elaborated correctly
- Instance argument `[Eq(a)]` in function signature elaborates to implicit param

### Integration tests

- Define `Eq` class with `eq` method
- Define `Ord` class with `Eq` superclass

## Verification

```bash
mix test test/haruspex/typeclass_test.exs
mix format --check-formatted
mix dialyzer
```
