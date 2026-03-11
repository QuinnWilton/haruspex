# Tier 3: Subsystem specification gaps

## Gaps to fill

### 1. Codegen (subsystems/09-codegen.md)

- **Complete builtin mapping table**: add all builtins from d26 with their Elixir Kernel equivalents
- **Extern codegen rules**: add `{:extern, mod, fun, arity}` compilation rules from d27
- **Variable name recovery algorithm**: define the index → name mapping for generated code. Use user names from elaboration context when available, fall back to `_v0`, `_v1`.
- **Fully-applied builtin optimization**: document when builtins are inlined vs. captured
- **Bool codegen**: `VCon(:Bool, :true, [])` → `true`, `VCon(:Bool, :false, [])` → `false` (d26)

### 2. Queries (subsystems/15-queries.md)

- **Diagnostic type definition**: add `@type diagnostic :: %{severity: atom(), message: String.t(), span: Pentiment.Span.Byte.t()}`
- **Cross-module query dependencies**: document how importing a module creates roux dependencies
- **@total body access**: document how the evaluator retrieves @total function bodies during NbE via roux queries

## Deliverable

Updated subsystem docs 09 and 15 with the above.
