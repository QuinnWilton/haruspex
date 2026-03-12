# Parser

## Purpose

Recursive descent parser that consumes a token stream and produces a surface AST. Uses Pratt parsing for expression precedence. Produces precise error messages with source spans. See [[../decisions/d12-nimble-parsec-tokenizer]], [[../decisions/d01-elixir-surface-syntax]].

## Dependencies

- `Haruspex.Tokenizer` — token stream input
- `Haruspex.AST` — node constructors
- `pentiment` — span composition

## Key types

```elixir
@type parse_state :: %{
  tokens: tuple(),
  pos: integer(),
  errors: [parse_error()]
}

@type parse_error :: %{
  message: String.t(),
  span: Pentiment.Span.Byte.t()
}

@type parse_result :: {:ok, [AST.toplevel()]} | {:error, String.t(), pos_integer(), pos_integer()}
```

## Public API

```elixir
@spec parse(String.t()) :: parse_result()
@spec parse_expr(String.t()) :: {:ok, AST.expr()} | {:error, String.t(), pos_integer(), pos_integer()}
```

## Grammar (simplified)

```
program     = toplevel*
toplevel    = annotation? def_decl | type_decl | record_decl | implicit_decl
annotation  = "@" ident                              # @total, @extern, @private
implicit_decl = "@" "implicit" implicit_param         # parsed as @ + ident "implicit"
def_decl    = "def" ident params? (":" type_expr)? "do" expr "end"
type_decl   = "type" upper_ident type_params? "|" constructor ("|" constructor)*
constructor = ident ("(" type_expr ("," type_expr)* ")")? (":" type_expr)?
record_decl = "record" upper_ident params? ":" field ("," field)*
field       = ident ":" type_expr
params      = "(" param ("," param)* ")"
param       = implicit_param | explicit_param
implicit_param = "{" multiplicity? ident ":" type_expr "}"
explicit_param = multiplicity? ident ":" type_expr
multiplicity   = "0"

type_expr   = pi_type | sigma_type | refinement | expr
pi_type     = "(" param ")" "->" type_expr
sigma_type  = "(" ident ":" type_expr "," type_expr ")"
refinement  = "{" ident ":" type_expr "|" expr "}"

expr        = pratt_expr
pratt_expr  = prefix (infix)*        # Pratt parsing with precedence
prefix      = unary | primary
primary     = var | lit | "(" expr ")" | fn_expr | case_expr | let_expr | if_expr | hole
fn_expr     = "fn" params "->" expr "end"   # multi-param lambdas auto-curry
case_expr   = "case" expr "do" branch+ "end"
let_expr    = "let" pattern "=" expr newline expr
if_expr     = "if" expr "do" expr "else" expr "end"
hole        = "_"
branch      = pattern "->" expr
var         = ident | upper_ident
lit         = int | float | string | atom_lit | true | false
```

## Precedence table (Pratt parsing)

| Precedence | Operators | Associativity |
|-----------|-----------|---------------|
| 1 (lowest) | `\|>` (pipe) | left |
| 2 | `\|\|` | left |
| 3 | `&&` | left |
| 4 | `==`, `!=` | left |
| 5 | `<`, `>`, `<=`, `>=` | left |
| 6 | `+`, `-` | left |
| 7 | `*`, `/` | left |
| 8 | unary `-`, `not` | prefix |
| 9 | function application `f(x)` | left |
| 10 | `:` (type annotation) | right |

## Error recovery

- **Not yet implemented.** The parser reports a single error and stops.
- Future work: on parse error in a definition body, skip tokens until `end`/`def`/`type` keyword; on parse error in expression, skip to next newline or closing delimiter; collect multiple errors.

## Implementation notes

- Parser state is a map with token tuple (for O(1) access), current position integer, and accumulated errors
- Peek/advance pattern for token consumption
- Spans composed by merging first and last token spans: `Pentiment.Span.Byte.merge(start_span, end_span)`
- Function application is syntactic: `f(x, y)` — no implicit currying at the surface level
- Constructors are bare identifiers (`none`, `some`), not atoms (`:none`, `:some`)
- Type parameters require kind annotations: `type List(a : Type)` not `type List(a)`

## Testing strategy

- **Unit tests**: Each production rule independently
- **Integration**: Full programs parse to expected AST shapes
- **Property tests**: `parse(format(ast)) == ast` round-trip (requires a formatter, deferred)
- **Error recovery**: Malformed programs produce errors with accurate spans
- **Edge cases**: Empty programs, single expressions, nested blocks
