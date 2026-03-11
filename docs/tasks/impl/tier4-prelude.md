# Tier 4: Prelude

**Decisions**: d26 (builtins and prelude), d29 (module system)

## Scope

Move builtin names from the elaborator's hard-coded table into a `Haruspex.Prelude` module that is auto-imported into every file.

## Implementation

### Prelude contents

- Type names: `Int`, `Float`, `String`, `Atom` (re-exports of builtins)
- `Bool` ADT: `true`, `false` constructors (defined as internal ADT per d26)
- Arithmetic operators: `add`, `sub`, `mul`, `div`, `neg`
- Float operators: `fadd`, `fsub`, `fmul`, `fdiv`
- Comparison: `eq`, `neq`, `lt`, `gt`, `lte`, `gte`
- Boolean: `and`, `or`, `not`

### Auto-import

Every file implicitly starts with `import Haruspex.Prelude, open: true`. Suppressible with `@no_prelude` annotation.

### Migration

Remove the hard-coded builtin table from elaboration. Replace with standard import resolution through the prelude module. Core terms are unchanged — `{:builtin, :Int}` still exists, but name resolution goes through the module system.

## Testing strategy

### Unit tests

- All prelude names resolve in a fresh module
- `@no_prelude` suppresses auto-import
- Prelude names can be shadowed by local definitions

### Integration tests

- Program using `Int`, `add`, `true` works without explicit import
- Program with `@no_prelude` must explicitly import or use qualified names

## Verification

```bash
mix test test/haruspex/prelude_test.exs
mix format --check-formatted
mix dialyzer
```
