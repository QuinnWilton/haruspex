# Tier 6: Type class codegen

**Module**: `Haruspex.TypeClass.Bridge`, `Haruspex.Codegen` (extensions)
**Subsystem doc**: [[../../subsystems/18-type-classes]]
**Decisions**: d20 (type classes)

## Scope

Implement dictionary-passing codegen and optional protocol bridge for single-parameter classes.

## Implementation

### Dictionary passing

- Class dictionaries compile to Elixir structs
- Instance arguments compile to regular function parameters
- Method calls compile to field access: `dict.eq(x, y)`
- Known dictionaries at monomorphic call sites are inlined (no runtime dictionary passing)

### Protocol bridge

When `@protocol` is annotated on a single-parameter class:
1. Generate `defprotocol` with same method signatures
2. Each `instance` also generates `defimpl`
3. Elixir callers use the protocol; Haruspex callers use dictionary passing

### Dictionary inlining

At monomorphic call sites where the type is known, the dictionary is a compile-time constant. Codegen inlines the dictionary and emits direct function calls instead of dictionary field access. E.g., `eq(42, 43)` with `Eq(Int)` → `Kernel.==(42, 43)`.

## Testing strategy

### Unit tests

- Dictionary struct generated correctly for each class
- Instance method implementations accessible via struct field access
- Dictionary inlining at known call sites
- Protocol generation from `@protocol`-annotated class
- `defimpl` generated for each instance

### Integration tests

- `member(42, [1, 2, 42])` compiles to efficient code (dictionary inlined for `Int`)
- Protocol bridge: Elixir code can call Haruspex-generated protocol

## Verification

```bash
mix test test/haruspex/typeclass_codegen_test.exs
mix format --check-formatted
mix dialyzer
```
