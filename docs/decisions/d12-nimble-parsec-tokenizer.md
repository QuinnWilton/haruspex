# D12: NimbleParsec tokenizer with hand-written recursive descent parser

**Decision**: Use NimbleParsec for tokenization and a hand-written recursive descent parser for parsing. Tree-sitter is used separately for editor highlighting only.

**Rationale**: NimbleParsec provides efficient, composable tokenizer combinators that compile to optimized pattern matching. Hand-written recursive descent gives full control over error recovery, precedence (via Pratt parsing for expressions), and the ability to produce precise error messages with spans. Tree-sitter grammars are great for editors but their error recovery model doesn't produce the diagnostic quality needed for a compiler.

**Mechanism**: The tokenizer produces a flat stream of `{tag, span, value}` tokens. The parser consumes this stream with a recursive descent strategy:
- Pratt parsing for expressions with operator precedence
- Keyword-delimited blocks (`do`/`end`) parsed structurally
- Error recovery synchronizes on `end`/`def`/`type` keywords
- Spans are composed from token spans during parsing

See [[d01-elixir-surface-syntax]], [[../subsystems/01-tokenizer]], [[../subsystems/02-parser]].
