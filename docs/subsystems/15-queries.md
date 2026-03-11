# Roux queries

## Purpose

Defines the roux query structure for incremental compilation. Each compilation stage is a roux query, enabling fine-grained caching and change detection. See [[../decisions/d10-entity-per-definition]].

## Dependencies

- `roux` — `Roux.Query`, `Roux.Lang`, `Roux.Runtime`, `Roux.Entity`
- All haruspex subsystems (each query calls into a subsystem)

## Entity definitions

```elixir
defentity Haruspex.Definition do
  identity [:uri, :name]
  field :type        # declared type (Core.term)
  field :body        # function body (Core.term)
  field :total?      # boolean
  field :erased_params  # [non_neg_integer()] — indices of 0-mult params
  field :span        # Pentiment.Span.Byte.t()
  field :name_span   # Pentiment.Span.Byte.t()
end
```

## Query definitions

```elixir
definput :source_text, durability: :low

# Parse source → create Definition entities
defquery :haruspex_parse, key: uri, returns: {:ok, [atom()]} | {:error, ...}

# Elaborate surface AST → core terms
defquery :haruspex_elaborate, key: {uri, name}, returns: {:ok, {Core.term(), Core.term()}} | {:error, ...}

# Type check elaborated core
defquery :haruspex_check, key: {uri, name}, returns: {:ok, Core.term(), Value.value()} | {:error, ...}

# Totality check (only for @total definitions)
defquery :haruspex_totality, key: {uri, name}, returns: :ok | {:error, ...}

# Optimize checked core (optional)
defquery :haruspex_optimize, key: uri, returns: {:ok, [{atom(), Core.term()}]} | {:error, ...}

# Generate Elixir code
defquery :haruspex_codegen, key: uri, returns: {:ok, Macro.t()} | {:error, ...}

# Full compilation pipeline
defquery :haruspex_compile, key: uri, returns: {:ok, Macro.t()} | {:error, ...}

# Diagnostics (errors + hole info)
defquery :haruspex_diagnostics, key: uri, returns: [diagnostic()]

# LSP queries
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
    ├─► haruspex_totality (if @total)         │
    │                                         │
    ▼                                         │
haruspex_optimize ◄───────────────────────────┘
    │
    ▼
haruspex_codegen
    │
    ▼
haruspex_compile

haruspex_diagnostics ◄── haruspex_check, haruspex_totality
haruspex_hover ◄── haruspex_check
haruspex_definition ◄── haruspex_parse
haruspex_completions ◄── haruspex_check
```

## Incrementality design

Key insight: Definition entities with `[:uri, :name]` identity enable field-level early cutoff.
- Changing a function's body but not its type → `haruspex_check` for that function re-runs, but dependents that only read the type are NOT invalidated
- Changing a type annotation → all dependents that read the type are invalidated
- Adding/removing a definition → `haruspex_parse` returns a different name list, triggering re-elaboration of affected definitions

## Implementation notes

- Queries are defined in `Haruspex` module (the Roux.Lang implementor)
- Each query calls into the appropriate subsystem module
- Error handling: queries return tagged tuples; downstream queries propagate errors
- LSP queries are read-only (they don't modify entities)

## Testing strategy

- **Unit tests**: Individual queries return expected results
- **Integration**: Full pipeline: source → compile → eval
- **Incremental tests**: Modify source, verify only affected queries re-execute (using roux test helpers)
