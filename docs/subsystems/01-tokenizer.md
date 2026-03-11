# Tokenizer

## Purpose

Converts source text into a flat stream of tokens using NimbleParsec combinators. Each token carries a `Pentiment.Span.Byte` for precise error reporting. See [[../decisions/d12-nimble-parsec-tokenizer]], [[../decisions/d01-elixir-surface-syntax]].

## Dependencies

- `nimble_parsec` — combinator library
- `pentiment` — `Pentiment.Span.Byte` for token spans

## Key types

```elixir
@type token_tag ::
  # keywords
  :def | :do | :end | :type | :case | :fn | :let | :if | :else | :total |
  # literals
  :int | :float | :string | :atom_lit | :true | :false |
  # identifiers
  :ident | :upper_ident |
  # operators
  :plus | :minus | :star | :slash | :eq | :eq_eq | :neq | :lt | :gt | :lte | :gte |
  :and_and | :or_or | :not | :pipe | :arrow | :fat_arrow | :colon | :dot |
  # delimiters
  :lparen | :rparen | :lbrace | :rbrace | :lbracket | :rbracket |
  :comma | :newline | :underscore | :at |
  # special
  :eof

@type token :: {token_tag(), Pentiment.Span.Byte.t(), term()}
```

## Public API

```elixir
@spec tokenize(String.t()) :: {:ok, [token()]} | {:error, String.t(), pos_integer(), pos_integer()}
```

## Algorithm

1. Skip whitespace and comments (line comments with `#`)
2. Match keywords before identifiers (keywords are reserved)
3. Two-char operators before single-char (`->` before `-`, `==` before `=`, `!=`, `<=`, `>=`, `&&`, `||`, `=>`)
4. Integer and float literals (float: digits `.` digits)
5. String literals with double quotes, basic escape sequences
6. Atom literals: `:name` syntax
7. Identifiers: start with lowercase letter or `_`, contain letters/digits/`_`
8. Upper identifiers: start with uppercase letter (for type constructors/module names)
9. Invalid characters: produce error with position

Span tracking uses NimbleParsec's pre/post traverse:
- `pre_traverse`: record byte offset at token start
- `post_traverse`: compute span from start offset to current position, emit `{tag, span, value}`

## Implementation notes

- Keywords checked via MapSet lookup after identifier recognition
- `@total` tokenized as `@` followed by `total` — the parser combines them
- Newlines are significant tokens (for statement separation) but consecutive newlines are collapsed
- Indentation is not significant (unlike Python) — `do`/`end` provides block structure

## Testing strategy

- **Unit tests**: Each token type in isolation
- **Property tests**: `tokenize(source)` produces tokens whose spans cover the entire source with no gaps or overlaps
- **Round-trip**: Token spans can reconstruct the original source via `String.slice(source, span.start, span.stop - span.start)`
- **Error cases**: Invalid characters, unterminated strings, incomplete operators
