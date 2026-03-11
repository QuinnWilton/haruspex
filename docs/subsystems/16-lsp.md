# LSP

## Purpose

Provides Language Server Protocol features by delegating to roux's LSP adapter. Each LSP feature maps to a roux query. Includes dependent-type-specific features: typed hole info and implicit argument display. See [[../decisions/d17-typed-holes]].

## Dependencies

- `Haruspex` — query execution
- `roux` — `Roux.Lang.LSP` adapter
- `pentiment` — position mapping

## Features

### Diagnostics
- Type errors with source spans
- Parse errors with source spans
- Hole information (type + context) as informational diagnostics
- Unsolved implicit errors
- Positivity violations
- Totality failures

### Hover
- Show type of expression under cursor (fully resolved, with solved implicits)
- On `_` holes: show expected type + all bindings in scope with types
- On function applications: show solved implicit arguments
- Format: Markdown with syntax highlighting

### Go to definition
- Variable → its binding site (let, lambda parameter, function definition)
- Type name → its `type` declaration
- Constructor → its position within the `type` declaration

### Completions
- All names in scope with their types
- Type-directed: if the expected type is known, rank completions by type compatibility
- Constructor completions when matching on an ADT

### Document symbols
- Top-level `def` and `type` declarations with their spans and types

## Position mapping

- LSP uses 0-based line and column (UTF-16 code units)
- Haruspex uses byte offsets via `Pentiment.Span.Byte`
- Conversion via roux's position mapping utilities

## Implementation notes

- Keep LSP module thin — it should primarily translate between LSP format and query results
- Hover formatting: pretty-print types with names recovered from elaboration context
- Implicit display: `id(42)` hovers as `id({a = Int}, 42)` showing the solved implicit

## Testing strategy

- **Unit tests**: Each LSP feature with mock query results
- **Integration**: LSP request → response roundtrip
