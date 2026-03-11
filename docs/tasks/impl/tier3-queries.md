# Tier 3: Roux queries and entities

**Module**: `Haruspex` (query definitions), `Haruspex.Definition`, `Haruspex.MutualGroup`
**Subsystem doc**: [[../../subsystems/15-queries]]
**Decisions**: d10 (entity per definition)

## Scope

Wire the full compilation pipeline through roux queries for incremental computation.

## Implementation

### Entities

```elixir
defentity Haruspex.Definition do
  identity [:uri, :name]
  field :type, :body, :total?, :erased_params, :span, :name_span
end

defentity Haruspex.MutualGroup do
  identity [:uri, :group_id]
  field :definitions
end
```

### Queries

| Query | Key | Returns | Calls |
|-------|-----|---------|-------|
| `:haruspex_parse` | `uri` | `{:ok, [atom()]}` | Tokenizer, Parser |
| `:haruspex_elaborate` | `{uri, name}` | `{:ok, {Core.term(), Core.term()}}` | Elaborate |
| `:haruspex_check` | `{uri, name}` | `{:ok, Core.term(), Value.value()}` | Check |
| `:haruspex_totality` | `{uri, name}` | `:ok` or error | Totality (Tier 7) |
| `:haruspex_codegen` | `uri` | `{:ok, Macro.t()}` | Codegen |
| `:haruspex_compile` | `uri` | `{:ok, Macro.t()}` | Full pipeline |
| `:haruspex_diagnostics` | `uri` | `[diagnostic()]` | Check, Totality |

### Incrementality

- Changing a function's body but not its type → only that function's check re-runs; dependents that only read the type are not invalidated
- Changing a type → all dependents re-check
- Adding/removing a definition → parse returns different name list → downstream invalidation

### Specification gaps to resolve

1. **URI format**: file path relative to project root, e.g., `"lib/math.hx"`
2. **Diagnostic type**: `%{severity: :error | :warning | :info, message: String.t(), span: Pentiment.Span.Byte.t()}`
3. **Cross-module dependencies**: when a query reads a definition from another module, it creates a roux dependency. This enables cross-module invalidation.

## Testing strategy

### Unit tests (`test/haruspex/queries_test.exs`)

- Parse query returns definition names from source
- Elaborate query returns core terms
- Check query returns checked terms and types
- Codegen query returns Elixir AST
- Compile query runs full pipeline

### Integration tests

- End-to-end: source text → `Roux.Runtime.query(db, :haruspex_compile, uri)` → Elixir AST
- Incremental: modify source body, verify only check re-runs (not parse)
- Incremental: modify source type, verify dependents re-check

## Verification

```bash
mix test test/haruspex/queries_test.exs
mix format --check-formatted
mix dialyzer
```
