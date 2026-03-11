# Tier 4: Module system

**Decisions**: d29 (module system)

## Scope

Implement file → module mapping, `import` with qualified/unqualified access, visibility (`@private`), and cross-module name resolution.

## Implementation

### File → module name

`lib/math.hx` → `Math`, `lib/data/vec.hx` → `Data.Vec`. Configured via `haruspex_paths` in project config.

### Import resolution

1. Parser produces `{:import, span, module_path, open_option}` nodes
2. Elaboration resolves imports by querying the imported module's definition entities via roux
3. Qualified names (`Math.add`) resolve through the module's exported names
4. `open: true` brings all exported names into unqualified scope
5. `open: [:add, :sub]` brings specific names into unqualified scope
6. Last segment shorthand: `import Data.Vec` makes both `Data.Vec.new` and `Vec.new` work

### Visibility

- `@private` annotation on a definition → not exported
- Default: public (exported)
- Elaboration of importing module: filter out `@private` names

### Instance propagation (d29)

All type class instances from an imported module are added to the instance database unconditionally.

### Circular import detection

During `haruspex_parse`, build a module dependency graph. Detect cycles → compile error.

## Testing strategy

### Unit tests

- File path → module name conversion for various paths
- Import resolution: qualified access to imported names
- Import with `open: true`: unqualified access
- Import with `open: [:add]`: selective unqualified access
- `@private` definitions not visible to importers
- Last segment shorthand works

### Negative tests

- Import nonexistent module → error
- Access `@private` name from another module → error
- Circular import → error with cycle description
- `open: [:nonexistent]` → error

### Integration tests

- Two-module program: module A defines `add`, module B imports A and uses `add`
- Cross-module type checking: module B's function uses A's type in its signature

## Verification

```bash
mix test test/haruspex/module_test.exs
mix format --check-formatted
mix dialyzer
```
