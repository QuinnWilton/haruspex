# Roux queries

## Purpose

Defines the roux query structure for incremental compilation. Each compilation stage is a roux query, enabling fine-grained caching and change detection. See [[../decisions/d10-entity-per-definition]].

## Dependencies

- `roux` — `Roux.Query`, `Roux.Lang`, `Roux.Runtime`, `Roux.Entity`
- All haruspex subsystems (each query calls into a subsystem)

## Key types

```elixir
@type diagnostic :: %{
  severity: :error | :warning | :info,
  message: String.t(),
  span: Pentiment.Span.Byte.t()
}

@type uri :: String.t()  # file path relative to project root, e.g., "lib/math.hx"
```

## Entity definitions

```elixir
defentity Haruspex.Definition do
  identity [:uri, :name]
  field :type        # declared type (Core.term)
  field :body        # function body (Core.term) or {:extern, module, fun, arity}
  field :total?      # boolean
  field :erased_params  # [non_neg_integer()] — indices of 0-mult params
  field :span        # Pentiment.Span.Byte.t()
  field :name_span   # Pentiment.Span.Byte.t()
end
```

## Query definitions

```elixir
definput :source_text, durability: :low

# Parse source → create Definition entities, return definition names
defquery :haruspex_parse, key: uri, returns: {:ok, [atom()]} | {:error, ...}

# Elaborate surface AST → core terms (type and body)
defquery :haruspex_elaborate, key: {uri, name}, returns: {:ok, {Core.term(), Core.term()}} | {:error, ...}

# Type check elaborated core
defquery :haruspex_check, key: {uri, name}, returns: {:ok, Core.term(), Value.value()} | {:error, ...}

# Totality check — deferred to tier 7
defquery :haruspex_totality, key: {uri, name}, returns: :ok | {:error, ...}

# Generate Elixir code (includes erasure)
defquery :haruspex_codegen, key: uri, returns: {:ok, Macro.t()} | {:error, ...}

# Full compilation pipeline
defquery :haruspex_compile, key: uri, returns: {:ok, Macro.t()} | {:error, ...}

# Diagnostics (errors + hole info)
defquery :haruspex_diagnostics, key: uri, returns: [diagnostic()]

# LSP queries — deferred to tier 10
defquery :haruspex_hover, key: {uri, position}, returns: String.t() | nil
defquery :haruspex_definition, key: {uri, position}, returns: map() | nil
defquery :haruspex_completions, key: {uri, position}, returns: [map()]
```

## Query dependencies

```
source_text
    │
    ▼
haruspex_parse ──────────────────────────────┐
    │                                         │
    ▼                                         │
haruspex_elaborate (per definition)           │
    │                                         │
    ▼                                         │
haruspex_check (per definition)               │
    │                                         │
    ├─► haruspex_totality (if @total) [T7]    │
    │                                         │
    ▼                                         │
haruspex_codegen ◄────────────────────────────┘
    │
    ▼
haruspex_compile

haruspex_diagnostics ◄── haruspex_check, haruspex_totality
haruspex_hover ◄── haruspex_check              [T10]
haruspex_definition ◄── haruspex_parse         [T10]
haruspex_completions ◄── haruspex_check        [T10]
```

## Incrementality design

Key insight: Definition entities with `[:uri, :name]` identity enable field-level early cutoff.
- Changing a function's body but not its type → `haruspex_check` for that function re-runs, but dependents that only read the type are NOT invalidated
- Changing a type annotation → all dependents that read the type are invalidated
- Adding/removing a definition → `haruspex_parse` returns a different name list, triggering re-elaboration of affected definitions

## Cross-module dependencies

When a query in module A reads the type of a definition in module B (via `query(db, :haruspex_check, {b_uri, name})`), roux automatically records this as a dependency. No special mechanism is needed — the standard roux dependency tracking handles cross-module invalidation.

This is deferred to tier 4 (module system), when imports and cross-module name resolution are implemented.

## `@total` body access during NbE

When the evaluator needs to unfold a `@total` function during type checking, it calls `query(db, :haruspex_check, {uri, name})` to retrieve the checked body. This creates a roux dependency from the calling definition's check query to the `@total` definition's check query.

There is no circularity: a definition's check query produces its body; the evaluator only unfolds *other* definitions' bodies during NbE. Mutual recursion within a mutual group is handled by collecting all signatures first (tier 2 mutual), then checking bodies in sequence.

This is deferred to tier 7 (totality).

## Error propagation

Queries use `query!/3` for short-circuit error propagation:
- If `haruspex_parse` fails, `haruspex_elaborate` is never called
- If `haruspex_elaborate` fails for a definition, `haruspex_check` for that definition returns the error
- `haruspex_diagnostics` collects errors from all definitions in the file by calling `haruspex_check` for each name returned by `haruspex_parse`, catching errors and converting them to diagnostics

## Implementation notes

- Queries are defined in `Haruspex` module (the Roux.Lang implementor)
- Each query calls into the appropriate subsystem module
- Error handling: queries return tagged tuples; downstream queries propagate errors via `query!/3`
- LSP queries are read-only (they don't modify entities)
- The optimize query is deferred to tier 9; codegen reads directly from check in tiers 3-8

## Testing strategy

- **Unit tests**: individual queries return expected results
- **Integration**: full pipeline: source → compile → eval
- **Incremental tests**: modify source, verify only affected queries re-execute (using roux test helpers)
