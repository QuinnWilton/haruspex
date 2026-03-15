# Tier 3: Roux queries and entities

**Module**: `Haruspex` (query definitions), `Haruspex.Definition`, `Haruspex.MutualGroup`
**Subsystem doc**: [[../../subsystems/15-queries]]
**Decisions**: d10 (entity per definition)

## Scope

Wire the full compilation pipeline through roux queries for incremental computation. Implement entity modules and all tier-3 queries (parse through compile + diagnostics). LSP, totality, and optimize queries are stubbed for later tiers.

## Implementation

### Entities

```elixir
defmodule Haruspex.Definition do
  use Roux.Entity,
    identity: [:uri, :name],
    tracked: [:type, :body, :total?, :erased_params, :span, :name_span]
end

defmodule Haruspex.MutualGroup do
  use Roux.Entity,
    identity: [:uri, :group_id],
    tracked: [:definitions]
end
```

### Queries

| Query | Key | Returns | Calls | Tier |
|-------|-----|---------|-------|------|
| `:haruspex_parse` | `uri` | `{:ok, [atom()]}` | Tokenizer, Parser | 3 |
| `:haruspex_elaborate` | `{uri, name}` | `{:ok, {Core.term(), Core.term()}}` | Elaborate | 3 |
| `:haruspex_check` | `{uri, name}` | `{:ok, Core.term(), Value.value()}` | Check | 3 |
| `:haruspex_codegen` | `uri` | `{:ok, Macro.t()}` | Erase, Codegen | 3 |
| `:haruspex_compile` | `uri` | `{:ok, Macro.t()}` | Full pipeline | 3 |
| `:haruspex_diagnostics` | `uri` | `[diagnostic()]` | Check | 3 |
| `:haruspex_totality` | `{uri, name}` | `:ok` or error | Totality | 7 (stub) |
| `:haruspex_hover` | `{uri, position}` | `String.t() \| nil` | Check | 10 (stub) |
| `:haruspex_definition` | `{uri, position}` | `map() \| nil` | Parse | 10 (stub) |
| `:haruspex_completions` | `{uri, position}` | `[map()]` | Check | 10 (stub) |

### Query implementations

**`:haruspex_parse`** — reads `source_text` input, tokenizes, parses, creates `Definition` entities for each top-level def, returns list of definition names.

**`:haruspex_elaborate`** — reads the `Definition` entity's surface AST (from parse), elaborates the type signature and body into core terms. Updates the entity's `:type` and `:body` fields.

**`:haruspex_check`** — reads the elaborated core from the entity, type-checks bidirectionally, returns checked core term and its type as a value. Updates entity fields.

**`:haruspex_codegen`** — queries `haruspex_check` for all definitions in the file (via `haruspex_parse` for the name list), erases each, compiles to Elixir AST, wraps in `defmodule`.

**`:haruspex_compile`** — calls `haruspex_codegen`, evaluates the quoted AST with `Code.eval_quoted`, returns the module.

**`:haruspex_diagnostics`** — queries `haruspex_parse` for names, then `haruspex_check` for each name (catching errors), converts errors to `%{severity: _, message: _, span: _}` diagnostics.

### Error propagation

- `query!/3` is used for short-circuit: if parse fails, elaborate is never called
- `haruspex_diagnostics` catches errors from individual definitions and converts them to diagnostics — one failing definition doesn't prevent diagnostics for others

### Incrementality

- Changing a function's body but not its type → only that function's check re-runs; dependents that only read the type via `field(db, Definition, id, :type)` are not invalidated
- Changing a type → all dependents re-check
- Adding/removing a definition → parse returns different name list → downstream invalidation

### URI format

File path relative to project root: `"lib/math.hx"`. Constructed by the roux compiler integration from the source file path.

### Diagnostic type

```elixir
@type diagnostic :: %{
  severity: :error | :warning | :info,
  message: String.t(),
  span: Pentiment.Span.Byte.t()
}
```

## Testing strategy

### Unit tests (`test/haruspex/queries_test.exs`)

- Parse query returns definition names from source
- Elaborate query returns core terms for a single definition
- Check query returns checked terms and types
- Codegen query returns Elixir AST
- Compile query runs full pipeline and produces a callable module
- Parse error → elaborate query returns error without running elaboration
- Elaborate error → check query returns error
- Diagnostics query collects errors from multiple definitions (one fails, others succeed)
- Diagnostics query returns empty list for valid source

### Integration tests

- End-to-end: source text → `Roux.Runtime.query(db, :haruspex_compile, uri)` → Elixir AST → eval → correct result
- Multi-definition file: two defs, both compile and are callable
- Extern definition: `@extern` in source → compiles through query pipeline → callable

### Incremental tests

- Modify source body (not type), verify only check re-runs (not parse or elaborate)
- Modify source type, verify dependents re-check
- Add a definition, verify parse result changes and new definition is elaborated/checked
- Remove a definition, verify it's no longer in parse results

### Entity tests

- Definition entity created with correct identity `{uri, name}`
- Field-level cutoff: update entity with same type but different body → downstream queries reading only `:type` are NOT invalidated

## Verification

```bash
mix test test/haruspex/queries_test.exs
mix format --check-formatted
mix dialyzer
```
