# Tier 10: Tree-sitter grammar and Zed extension

**Subsystem doc**: [[../../subsystems/17-tree-sitter]]

## Scope

Create a tree-sitter grammar for Haruspex syntax highlighting. Generate a Zed extension.

## Implementation

### Grammar

- `grammar.js` with rules for all Haruspex syntax (definitions, types, expressions, patterns, operators, annotations)
- Precedence matching the Pratt table from the parser
- Error recovery via tree-sitter's built-in mechanisms

### Highlight queries

`queries/highlights.scm`:
- Keywords: `def`, `do`, `end`, `type`, `case`, `if`, `else`, `fn`, `let`, `import`, `mutual`, `class`, `instance`, `record`, `with`, `variable`
- Attributes: `@total`, `@extern`, `@private`, `@protocol`, `@no_prelude`
- Types: uppercase identifiers (`Int`, `Float`, `Vec`, etc.)
- Operators: `+`, `-`, `*`, `/`, `==`, `!=`, `<`, `>`, `->`, `|>`
- Literals: integers, floats, strings, atoms, booleans
- Comments: `#` to end of line
- Holes: `_`

### Zed extension

Generated via `mix roux.gen.zed`:
- Language configuration (file extensions, comment syntax, brackets)
- Grammar + highlight queries bundled
- Auto-indent rules

## Testing strategy

### Unit tests

- Tree-sitter corpus tests: example programs with expected parse trees
- Each syntax form produces correct tree-sitter node types
- Error recovery: incomplete programs parse without crashing

### Integration tests

- Install in Zed, verify syntax highlighting on sample `.hx` files

## Verification

```bash
cd tree-sitter-haruspex && npm test  # tree-sitter tests
```
