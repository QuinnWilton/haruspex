# AST (Surface)

## Purpose

Defines the surface AST node types. All nodes are tagged tuples carrying `Pentiment.Span.Byte` spans. The surface AST represents the program as the user wrote it — with named variables, syntactic sugar, and human-readable structure. See [[../decisions/d01-elixir-surface-syntax]], [[../decisions/d09-pentiment-spans-everywhere]].

## Dependencies

- `pentiment` — `Pentiment.Span.Byte`

## Key types

```elixir
# Shared sub-structures
@type binder :: {atom(), multiplicity(), implicit?()}
  # {name, multiplicity, implicit?} — reused in params and pi types
@type multiplicity :: :omega | :zero
@type implicit? :: boolean()
@type attrs :: %{total: boolean(), private: boolean(), extern: extern() | nil}
@type extern :: {module(), atom(), arity()}

# Top-level declarations
@type toplevel :: def_node() | type_decl()
@type def_node :: {:def, Span.t(), signature(), expr()}
  # {:def, span, signature, body}
@type signature :: {:sig, Span.t(), atom(), Span.t(), [param()], type_expr() | nil, attrs()}
  # {:sig, span, name, name_span, params, return_type, attrs}
@type type_decl :: {:type_decl, Span.t(), atom(), [atom()], [constructor()]}
  # {:type_decl, span, name, type_params, constructors}
@type constructor :: {:constructor, Span.t(), atom(), [type_expr()]}

# Parameters
@type param :: {:param, Span.t(), binder(), type_expr()}
  # {:param, span, binder, type}

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
  {:pi, Span.t(), binder(), type_expr(), type_expr()}
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
- `span/1` extracts the span from any node via `elem(node, 1)`
- Type expressions reuse expression syntax where possible (a variable `Int` is both an expression and a type)
- `nil` return type on `signature` means the return type is not annotated (will be inferred)
- `binder()` is a plain triple, not a tagged tuple — it's always embedded inside a spanned node
- `signature()` is a first-class node so mutual blocks can collect signatures before checking bodies
- `attrs()` is a map to accommodate future annotations without widening the tuple

## Testing strategy

- **Unit tests**: Constructor helpers produce well-formed nodes
- **Property tests**: `span/1` never crashes on any valid AST node
