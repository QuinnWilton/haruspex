# Tier 0: Parser

**Module**: `Haruspex.Parser`
**Subsystem doc**: [[../../subsystems/02-parser]]
**Decisions**: d01 (Elixir surface syntax), d09 (pentiment spans)

## Scope

Implement a recursive descent parser with Pratt parsing for expressions, consuming a token stream from the tokenizer and producing the surface AST.

## Implementation

### Grammar coverage

All productions from the subsystem doc:

- **Top-level**: `def` (with optional `@total`, `@extern`, `@private`), `type` declarations, `mutual do ... end` blocks, `import` statements, `@implicit` declarations (parsed as `@` followed by ident `implicit`), `class`/`instance` declarations, `record` declarations
- **Expressions**: variables, literals, function application `f(x, y)`, lambdas `fn(x) -> ... end` (multi-param lambdas auto-curry), let bindings, case/if/else, binary operators, unary operators, pipe `|>`, type annotations `(e : T)`, holes `_`, with-expressions
- **Type expressions**: Pi types `(x : A) -> B`, arrow types `A -> B`, Sigma types, refinement types `{x : A | P}`, universes `Type`, `Type 0`
- **Type declarations**: `type Option(a : Type) | none | some(a)` — constructors introduced with `|`, kind annotations required on type params, constructors are bare identifiers (not atoms)
- **Record declarations**: `record Point : x : Int , y : Int` — `:` introduces fields, `,` separates them
- **Patterns**: variable, literal, constructor `cons(x, xs)`, wildcard `_`
- **Parameters**: explicit `(x : T)`, implicit `{a : Type}`, instance `[eq : Eq(a)]`, erased `(0 x : T)`

### Pratt precedence table

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 | `\|>` | left |
| 2 | `or` | left |
| 3 | `and` | left |
| 4 | `==`, `!=` | left |
| 5 | `<`, `>`, `<=`, `>=` | left |
| 6 | `+`, `-` | left |
| 7 | `*`, `/` | left |
| 8 | unary `-`, `not` | prefix |
| 9 | function application | left |
| 10 | `.` (field access) | left |

### Specification gaps to resolve during implementation

1. **Newline as statement separator**: newlines separate top-level definitions and statements in blocks. Newlines are optional before `end`, after `do`, and inside parenthesized expressions (already suppressed by tokenizer).
2. **Error recovery**: not yet implemented. The parser reports a single error and stops. Future work: skip tokens until `end`, `def`, `type`, or EOF, collecting multiple errors.
3. **Function application vs. grouping**: `f(x)` is application, `(x)` is grouping. Distinguished by whether an expression precedes `(`.
4. **Annotation attachment**: `@total`, `@extern`, `@private` attach to the immediately following `def` or `type`. Error if annotation has no following declaration.
5. **Operator sections**: not supported. `(+ 1)` is a parse error.
6. **Trailing commas**: allowed in argument lists and parameter lists.
7. **`@extern` argument**: `@extern Module.function/arity` parses as annotation with a module-function-arity reference.

### Public API

```elixir
@spec parse(String.t()) :: {:ok, AST.program()} | {:error, [parse_error()]}
@spec parse_expr(String.t()) :: {:ok, AST.expr()} | {:error, parse_error()}
@type parse_error :: {:parse_error, String.t(), Pentiment.Span.Byte.t()}
```

## Testing strategy

### Unit tests (`test/haruspex/parser_test.exs`)

- **Literals**: integers, floats, strings, atoms, booleans parse to `{:lit, span, value}`
- **Variables**: lowercase → `{:var, span, name}`, uppercase → `{:var, span, name}`
- **Application**: `f(x, y)` → `{:app, span, {:var, _, :f}, [{:var, _, :x}, {:var, _, :y}]}`
- **Operators**: precedence tests — `1 + 2 * 3` → `add(1, mul(2, 3))`, `1 * 2 + 3` → `add(mul(1, 2), 3)`
- **Associativity**: `1 - 2 - 3` → `sub(sub(1, 2), 3)` (left-associative)
- **Pipe**: `x |> f |> g` → `g(f(x))`
- **Lambda**: `fn(x, y) -> x + y end` → correct AST (multi-param lambdas auto-curry)
- **Let**: `let x = 1 in x + 1` → correct AST
- **Case**: simple and nested patterns
- **If/else**: `if cond do a else b end`
- **Type annotations**: `(x : Int)` → `{:ann, span, x, Int}`
- **Pi types**: `(x : A) -> B` with explicit binding, `A -> B` without binding
- **Implicit params**: `{a : Type}` in function signatures
- **Instance params**: `[eq : Eq(a)]` in function signatures
- **Erased params**: `(0 x : T)` in function signatures
- **Definitions**: `def f(x : Int) : Int do x + 1 end`
- **Type declarations**: `type Option(a : Type) | none | some(a)` — constructors with `|`, kind-annotated params, bare identifiers
- **Mutual blocks**: `mutual do ... end` with multiple defs/types
- **Holes**: `_` in expression and pattern position
- **Annotations**: `@total def ...`, `@extern Enum.map/2 def ...`, `@private def ...`
- **Import**: `import Math`, `import Math, open: true`, `import Math, open: [add, sub]`
- **Implicit declarations**: `@implicit {a : Type}` (parsed as `@` + ident `implicit`)
- **Span correctness**: every AST node's span covers exactly its source text
- **Span nesting**: parent spans contain child spans

### Negative tests

- Missing `end` → error with position
- Missing `do` → error with position
- Unexpected token in expression → error
- Annotation without following definition → error
- Single error stops parsing (error recovery not yet implemented)

### Property tests

- **Span containment**: for every AST node, `AST.span(node)` is a valid span and child spans are contained within parent spans
- **No crash**: random token streams never crash the parser (may produce errors)

### Integration tests

- Parse a full multi-definition program with types, patterns, operators, annotations
- Parse → `AST.span/1` extracts correct spans for all nodes

## Verification

```bash
mix test test/haruspex/parser_test.exs
mix format --check-formatted
mix dialyzer
```
