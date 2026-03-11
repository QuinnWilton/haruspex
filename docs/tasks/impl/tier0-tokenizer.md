# Tier 0: Tokenizer

**Module**: `Haruspex.Tokenizer`
**Subsystem doc**: [[../../subsystems/01-tokenizer]]
**Decisions**: d01 (Elixir surface syntax), d09 (pentiment spans), d12 (NimbleParsec)

## Scope

Implement a NimbleParsec tokenizer that converts source text to a stream of tokens with pentiment byte spans.

## Implementation

### Token types

All 29 token tags from the subsystem doc:

- Keywords: `def`, `do`, `end`, `fn`, `case`, `if`, `else`, `type`, `import`, `mutual`, `variable`, `class`, `instance`, `with`, `record`, `where`
- Literals: `:int`, `:float`, `:string`, `:atom_lit`, `:true`, `:false`
- Identifiers: `:ident`, `:upper_ident` (type/module names)
- Operators: `:plus`, `:minus`, `:star`, `:slash`, `:eq_eq`, `:bang_eq`, `:lt`, `:gt`, `:lte`, `:gte`, `:arrow`, `:fat_arrow`, `:pipe`, `:dot`, `:colon`
- Delimiters: `:lparen`, `:rparen`, `:lbrace`, `:rbrace`, `:lbracket`, `:rbracket`, `:comma`
- Structure: `:newline`, `:at` (for annotations like `@total`, `@extern`, `@private`)
- Special: `:underscore` (holes/wildcards)

### Specification gaps to resolve during implementation

1. **String escape sequences**: support `\n`, `\t`, `\\`, `\"`, `\r`, `\0`. Invalid escapes produce a tokenizer error with span.
2. **Newline collapsing**: consecutive newlines collapse to a single `:newline` token. Newlines inside parens/braces/brackets are suppressed (not emitted).
3. **Float edge cases**: require digits on both sides of the dot (`1.0` yes, `1.` no, `.5` no). No `Inf`/`NaN` literals — these are not valid Haruspex source.
4. **Atom literal characters**: `:` followed by identifier characters (`a-z`, `A-Z`, `0-9`, `_`). Quoted atoms with `:"..."` syntax deferred.
5. **Integer limits**: arbitrary precision (Elixir integers). No explicit limit.
6. **Unterminated strings**: produce `{:error, "unterminated string", line, col}` at EOF.
7. **Comment handling**: `#` to end of line. No block comments.

### Public API

```elixir
@spec tokenize(String.t()) :: {:ok, [token()]} | {:error, String.t(), pos_integer(), pos_integer()}
@type token :: {token_tag(), Pentiment.Span.Byte.t(), term()}
```

## Testing strategy

### Unit tests (`test/haruspex/tokenizer_test.exs`)

- Each token type produced correctly with correct span
- Keywords distinguished from identifiers
- Two-character operators parsed before single-character (`==` not `=` + `=`)
- String escape sequences: `\n`, `\t`, `\\`, `\"` produce correct values
- Integer parsing: `0`, `42`, `-1` (negative is unary minus + int), large integers
- Float parsing: `3.14`, `0.5`, `100.0`
- Atom parsing: `:ok`, `:error`, `:some_atom`
- Boolean parsing: `true`, `false` (as keywords, not identifiers)
- Newline collapsing: `\n\n\n` → single `:newline`
- Newline suppression inside parens: `f(\n  x,\n  y\n)` → no newline tokens
- Annotation tokens: `@total`, `@extern`, `@private`
- Comment skipping: `x + y # this is a comment` → `x`, `+`, `y` only

### Negative tests

- Unterminated string → error with position
- Invalid escape `\q` → error with position
- Unexpected character `§` → error with position
- Incomplete operator (if any apply)

### Property tests

- **Span coverage**: union of all token spans covers the entire source (no gaps between tokens, excluding whitespace and comments)
- **Span validity**: every token's span, when sliced from source, matches the token's string representation
- **Determinism**: same input always produces same output
- **No crash**: random ASCII/UTF-8 strings never crash the tokenizer (may produce errors, but never exceptions)

### Integration tests

- Tokenize a complete Haruspex source file (multi-definition, with types, patterns, operators)
- Verify span-to-source roundtrip for all tokens

## Verification

```bash
mix test test/haruspex/tokenizer_test.exs
mix format --check-formatted
mix dialyzer
```
