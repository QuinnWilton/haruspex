# Tree-sitter grammar

## Purpose

Provides syntax highlighting for editors via tree-sitter. The grammar handles Elixir-like syntax extended with type annotations, implicit arguments, holes, and `@total`. Separate from the compilation parser — highlighting only.

## Dependencies

- `tree-sitter` — grammar framework
- `tree-sitter-cli` — grammar compilation

## Grammar highlights

- `def`, `do`, `end`, `type`, `case`, `fn`, `let`, `if`, `else` — keywords
- `@total` — attribute
- `{a : Type}` — implicit parameter (highlighted differently from explicit)
- `_` — hole (distinct highlight)
- `:name` — atom literal
- `Type`, `Type 0` — universe keywords
- `: type_expr` — type annotation (subdued highlight)
- Standard: strings, numbers, operators, comments

## File structure

```
tree-sitter-haruspex/
├── grammar.js          # main grammar definition
├── package.json        # npm package metadata
├── queries/
│   └── highlights.scm  # highlight queries
└── test/
    └── corpus/         # tree-sitter test files
```

## Implementation notes

- Generated via `mix roux.gen.tree_sitter` (roux utility)
- Grammar follows tree-sitter conventions: rules as functions, precedence via `prec()`
- Error recovery via tree-sitter's built-in mechanisms (not custom)
- Zed extension generated via `mix roux.gen.zed`

## Testing strategy

- Tree-sitter's built-in test corpus: example programs with expected parse trees
- Visual testing: syntax-highlighted example files in each editor
