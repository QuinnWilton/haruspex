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
@type toplevel ::
  {:def, Span.t(), signature(), expr()}
  | {:type_decl, Span.t(), atom(), [type_param()], [constructor()]}
  | {:import, Span.t(), module_path(), open_option()}
  | {:variable_decl, Span.t(), [param()]}
  | {:mutual, Span.t(), [toplevel()]}
  | {:class_decl, Span.t(), atom(), [param()], [constraint()], [method_sig()]}
  | {:instance_decl, Span.t(), atom(), [type_expr()], [constraint()], [method_impl()]}
  | {:record_decl, Span.t(), atom(), [param()], [field()]}

@type signature :: {:sig, Span.t(), atom(), Span.t(), [param()], type_expr() | nil, attrs()}
  # {:sig, span, name, name_span, params, return_type, attrs}

@type type_param :: {atom(), type_expr() | nil}
  # type parameter with optional kind, e.g., (a : Type) or (n : Nat)

@type constructor :: {:constructor, Span.t(), atom(), [field()], type_expr() | nil}
  # constructor with named fields and optional return type (for GADTs)

@type field :: {:field, Span.t(), atom(), type_expr()}
@type module_path :: [atom()]
@type open_option :: boolean() | [atom()] | nil
@type constraint :: {:constraint, Span.t(), atom(), [type_expr()]}
@type method_sig :: {:method_sig, Span.t(), atom(), type_expr()}
@type method_impl :: {:method_impl, Span.t(), atom(), expr()}

@type program :: [toplevel()]

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
  | {:dot, Span.t(), expr(), atom()}
  | {:record_construct, Span.t(), atom(), [{atom(), expr()}]}
  | {:record_update, Span.t(), expr(), [{atom(), expr()}]}

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
  | {:pat_record, Span.t(), atom(), [{atom(), pattern()}]}
@type literal :: integer() | float() | String.t() | atom() | boolean()
```

## Public API

```elixir
@spec span(expr() | toplevel() | type_expr() | pattern() | branch() | param()
           | constructor() | signature() | field() | constraint()
           | method_sig() | method_impl()) :: Pentiment.Span.Byte.t()
```

Uses `elem(node, 1)` — works on any tagged tuple with a span in position 1.

## Implementation notes

- All nodes are tagged tuples, not structs — matches Lark's pattern for simplicity
- `span/1` extracts the span from any node via `elem(node, 1)`
- Type expressions reuse expression syntax where possible (a variable `Int` is both an expression and a type)
- `nil` return type on `signature` means the return type is not annotated (will be inferred)
- `binder()` is a plain triple, not a tagged tuple — it's always embedded inside a spanned node
- `signature()` is a first-class node so mutual blocks can collect signatures before checking bodies
- `attrs()` is a map to accommodate future annotations without widening the tuple

## Testing strategy

- **Unit tests**: `span/1` returns correct span for every node type (expressions, type expressions, patterns, top-level declarations, sub-nodes)
- **Property tests**: `span/1` returns the span from position 1 for any randomly generated valid AST node
