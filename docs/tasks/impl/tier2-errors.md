# Tier 2: Error rendering

**Module**: `Haruspex.Errors`
**Subsystem doc**: [[../../subsystems/08-checker]] (error pretty-printing section)
**Decisions**: d09 (pentiment spans)

## Scope

Implement error rendering using pentiment spans for source context display.

## Implementation

### Error structure

```elixir
@type rendered_error :: %{
  message: String.t(),
  span: Pentiment.Span.Byte.t(),
  expected: String.t() | nil,
  got: String.t() | nil,
  notes: [String.t()]
}
```

### Rendering pipeline

1. Take a `type_error()` from the checker
2. Pretty-print the expected and actual types using `Haruspex.Pretty`
3. Resolve the span to line/column using `Pentiment.Span.Byte.resolve/2`
4. Format with source context (show the offending line, underline the span)

### Error messages

| Error | Message |
|-------|---------|
| `{:type_mismatch, expected, got, span}` | "type mismatch: expected `X`, got `Y`" |
| `{:not_a_function, ty, span}` | "expected a function, got `T`" |
| `{:not_a_pair, ty, span}` | "expected a pair, got `T`" |
| `{:unsolved_meta, id, ty, span}` | "could not infer implicit argument of type `T`" |
| `{:multiplicity_violation, name, span}` | "variable `name` is erased and cannot be used here" |
| `{:universe_error, msg, span}` | "universe error: `msg`" |
| `{:unbound_variable, name, span}` | "unbound variable `name`" |

### Public API

```elixir
@spec render(type_error(), String.t(), [atom()], non_neg_integer()) :: rendered_error()
  # render(error, source_text, name_list, level)
@spec format(rendered_error()) :: String.t()
  # format for terminal output
```

## Testing strategy

### Unit tests (`test/haruspex/errors_test.exs`)

- Each error type renders with correct message
- Span resolution produces correct line/column
- Pretty-printed types appear in expected/got fields
- Source context shows correct line with underline
- Notes field populated for relevant errors

### Integration tests

- End-to-end: ill-typed program → parse → elaborate → check → render error → readable output

## Deferred to tier 3

### Raw unification error rendering
The errors module does not yet render raw unification errors (`{:mismatch, ...}`,
`{:occurs_check, ...}`, `{:scope_escape, ...}`, `{:not_pattern, ...}`). These are
currently wrapped into `{:type_mismatch, ...}` by the checker's fallback path. When
richer error messages are needed, add dedicated render clauses.

### Rich format with source context
`Errors.format/2` delegates to `Pentiment.format/3` which requires a source argument.
End-to-end formatting with source line display and span underlines is deferred to when
the pipeline provides source text alongside errors.

## Verification

```bash
mix test test/haruspex/errors_test.exs
mix format --check-formatted
mix dialyzer
```
