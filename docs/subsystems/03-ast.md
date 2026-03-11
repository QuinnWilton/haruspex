# AST (Surface)

## Purpose

Defines the surface AST node types. All nodes are tagged tuples carrying `Pentiment.Span.Byte` spans. The surface AST represents the program as the user wrote it — with named variables, syntactic sugar, and human-readable structure. See [[../decisions/d01-elixir-surface-syntax]], [[../decisions/d09-pentiment-spans-everywhere]].

## Dependencies

- `pentiment` — `Pentiment.Span.Byte`

## Key types

```elixir
# Top-level declarations
@type toplevel :: def_node() | type_decl()
@type def_node :: {:def, Span.t(), atom(), Span.t(), [param()], type_expr() | nil, expr(), boolean()}
  # {:def, span, name, name_span, params, return_type, body, total?}
@type type_decl :: {:type_decl, Span.t(), atom(), [atom()], [constructor()]}
  # {:type_decl, span, name, type_params, constructors}
@type constructor :: {:constructor, Span.t(), atom(), [type_expr()]}

# Parameters
@type param :: {:param, Span.t(), atom(), type_expr(), multiplicity(), implicit?()}
  # {:param, span, name, type, mult, implicit?}
@type multiplicity :: :omega | :zero
@type implicit? :: boolean()

# Expressions
@type expr ::
  {:var, Span.t(), atom()}
  | {:lit, Span.t(), literal()}
  | {:app, Span.t(), expr(), [expr()]}
  | {:fn, Span.t(), [param()], expr()}
  | {:let, Span.t(), atom(), expr(), expr()}
  | {:case, Span.t(), expr(), [branch()]}
  | {:if, Span.t(), expr(), expr(), expr()}
  | {:binop, Span.t(), atom(), expr(), expr()}
  | {:unaryop, Span.t(), atom(), expr()}
  | {:pipe, Span.t(), expr(), expr()}
  | {:ann, Span.t(), expr(), type_expr()}
  | {:hole, Span.t()}

# Type expressions (surface-level, before elaboration)
@type type_expr ::
  {:pi, Span.t(), atom(), multiplicity(), type_expr(), type_expr(), implicit?()}
  | {:sigma, Span.t(), atom(), type_expr(), type_expr()}
  | {:refinement, Span.t(), atom(), type_expr(), expr()}
  | {:type_universe, Span.t(), non_neg_integer() | nil}
  | expr()

@type branch :: {:branch, Span.t(), pattern(), expr()}
@type pattern :: {:pat_var, Span.t(), atom()}
  | {:pat_lit, Span.t(), literal()}
  | {:pat_constructor, Span.t(), atom(), [pattern()]}
  | {:pat_wildcard, Span.t()}
@type literal :: integer() | float() | String.t() | atom()
```

## Public API

```elixir
@spec span(toplevel() | expr() | type_expr() | pattern()) :: Pentiment.Span.Byte.t()
```

Helper constructors for each node type (optional, for test convenience).

## Implementation notes

- All nodes are tagged tuples, not structs — matches Lark's pattern for simplicity
- `span/1` extracts the span from any node via pattern matching on the second element
- Type expressions reuse expression syntax where possible (a variable `Int` is both an expression and a type)
- `nil` return type on `def_node` means the return type is not annotated (will be inferred)

## Testing strategy

- **Unit tests**: Constructor helpers produce well-formed nodes
- **Property tests**: `span/1` never crashes on any valid AST node
