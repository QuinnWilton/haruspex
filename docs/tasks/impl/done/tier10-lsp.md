# Tier 10: LSP integration

**Module**: `Haruspex.LSP`
**Subsystem doc**: [[../../subsystems/16-lsp]]

## Scope

Implement LSP queries via roux: hover, go-to-definition, completions, diagnostics, document symbols.

## Implementation

### Queries (delegated through roux)

- **Diagnostics**: aggregate type errors, parse errors, positivity errors, totality errors, hole info per file
- **Hover**: at cursor position, show the type of the expression. For holes, show expected type + bindings. For implicit arguments, show solved values.
- **Go-to-definition**: jump to the definition of a variable, type, or constructor. Cross-module.
- **Completions**: all names in scope at cursor position. Type-directed ranking when expected type is known.
- **Document symbols**: top-level `def` and `type` declarations with spans.

### Position mapping

LSP uses 0-based line/column with UTF-16 offsets. Pentiment spans are byte offsets. Use `Pentiment.Span.Byte.resolve/2` for conversion.

## Testing strategy

### Unit tests (`test/haruspex/lsp_test.exs`)

- Hover on variable → shows its type
- Hover on hole → shows expected type and bindings
- Hover on literal → shows literal type
- Go-to-definition on variable → span of the binding site
- Go-to-definition on type name → span of type declaration
- Completions at empty position → all names in scope
- Completions after dot → field names for records
- Document symbols → list of definitions with spans
- Diagnostics → type errors formatted as LSP diagnostics

### Integration tests

- LSP request/response roundtrip for each feature
- Cross-module go-to-definition

## Verification

```bash
mix test test/haruspex/lsp_test.exs
mix format --check-formatted
mix dialyzer
```
