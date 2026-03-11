# Tier 5: Records

**Module**: `Haruspex.Record`
**Subsystem doc**: [[../../subsystems/19-records]]
**Decisions**: d21 (records)

## Scope

Implement record declarations as single-constructor ADTs with named field projections, struct codegen, construction, update, and pattern matching.

## Implementation

### Record declarations

```elixir
record Point do x : Float; y : Float end
```

Desugars to a single-constructor ADT `type Point do mk_Point(x : Float, y : Float) : Point end` but retains record identity for field access, construction, update, and eta.

### Features

- **Construction**: `%Point{x: 1.0, y: 2.0}` → `Con(:Point, :mk_Point, [1.0, 2.0])`
- **Projection**: `p.x` → `Fst(p)` (or appropriate projection function)
- **Update**: `%{p | x: 3.0}` → reconstruct with new field value
- **Pattern matching**: `%Point{x: x, y: y}` → match on single constructor
- **Dependent fields**: `record Sigma(a : Type, b : a -> Type) do fst : a; snd : b(fst) end`
- **Eta rule**: `mk_Point(p.x, p.y) ≡ p` in NbE (type-directed readback)
- **Codegen**: records compile to Elixir structs

## Testing strategy

### Unit tests (`test/haruspex/record_test.exs`)

- Declaration with simple fields type-checks
- Declaration with dependent fields type-checks
- Construction type-checks and produces correct values
- Projection retrieves correct field
- Update produces correct new record
- Pattern matching on record works
- Eta: `mk_Point(p.x, p.y)` converts to `p`
- Codegen: record compiles to Elixir struct

### Property tests

- **Projection roundtrip**: `construct(project_1(r), project_2(r), ...) ≡ r`

### Integration tests

- Define `Point`, construct, project, update, pattern match — end-to-end
- Dependent record: `Sigma` pair with dependent second field

## Verification

```bash
mix test test/haruspex/record_test.exs
mix format --check-formatted
mix dialyzer
```
