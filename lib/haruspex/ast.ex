defmodule Haruspex.AST do
  @moduledoc """
  Surface AST node types for Haruspex.

  Every node carries a `Pentiment.Span.Byte` for error reporting and LSP
  integration. Nodes are plain tagged tuples — no structs.

  ## Sub-structures

      binder = {name, mult, implicit?}
      signature = {:sig, span, name, name_span, [param], return_type | nil, attrs}
      attrs = %{total: bool, private: bool, extern: extern | nil}

  ## Expressions

      {:var, span, name}
      {:lit, span, value}
      {:app, span, func, [args]}
      {:fn, span, [param], body}
      {:let, span, name, value, body}
      {:case, span, scrutinee, [branch]}
      {:if, span, cond, then_branch, else_branch}
      {:binop, span, op, left, right}
      {:unaryop, span, op, expr}
      {:pipe, span, left, right}
      {:ann, span, expr, type_expr}
      {:hole, span}
      {:dot, span, expr, field_name}
      {:record_construct, span, name, [{atom, expr}]}
      {:record_update, span, name | nil, expr, [{atom, expr}]}
      {:with, span, [expr], [branch]}

  ## Type expressions

      {:pi, span, binder, domain, codomain}
      {:sigma, span, name, fst_type, snd_type}
      {:refinement, span, name, base_type, predicate}
      {:type_universe, span, level | nil}

  ## Top-level

      {:def, span, signature, body}
      {:type_decl, span, name, [type_param], [constructor]}
      {:import, span, module_path, open_option}
      {:implicit_decl, span, [param]}
      {:mutual, span, [toplevel]}
      {:class_decl, span, name, [param], [constraint], [method_sig]}
      {:instance_decl, span, class_name, [type_arg], [constraint], [method_impl]}
      {:record_decl, span, name, [param], [field]}

  ## Patterns

      {:pat_var, span, name}
      {:pat_lit, span, value}
      {:pat_constructor, span, name, [pattern]}
      {:pat_wildcard, span}
      {:pat_record, span, name, [{atom, pattern}]}

  ## Spans

  All spans are `Pentiment.Span.Byte.t()` — byte offset + length, as
  produced by NimbleParsec. Use `Pentiment.Span.Byte.resolve/2` to
  convert to line/column positions for display.
  """

  # ============================================================================
  # Shared sub-structures
  # ============================================================================

  @type span :: Pentiment.Span.Byte.t()
  @type mult :: :omega | :zero

  @typedoc "Binding site: {name, multiplicity, implicit?}."
  @type binder :: {atom(), mult(), boolean()}

  @typedoc "Function attributes carried on a signature."
  @type attrs :: %{total: boolean(), private: boolean(), extern: extern() | nil}

  @typedoc "Extern reference: {module, function, arity}."
  @type extern :: {module(), atom(), non_neg_integer()}

  @typedoc "Function signature, separable from its body for mutual block collection."
  @type signature ::
          {:sig, span(), atom(), span(), [param()], type_expr() | nil, attrs()}

  # ============================================================================
  # Parameters and binders
  # ============================================================================

  @type param :: {:param, span(), binder(), type_expr()}

  # ============================================================================
  # Literals
  # ============================================================================

  @type literal :: integer() | float() | String.t() | atom() | boolean()

  # ============================================================================
  # Expressions
  # ============================================================================

  @type expr ::
          {:var, span(), atom()}
          | {:lit, span(), literal()}
          | {:app, span(), expr(), [expr()]}
          | {:fn, span(), [param()], expr()}
          | {:let, span(), atom(), expr(), expr()}
          | {:case, span(), expr(), [branch()]}
          | {:if, span(), expr(), expr(), expr()}
          | {:binop, span(), binop(), expr(), expr()}
          | {:unaryop, span(), unaryop(), expr()}
          | {:pipe, span(), expr(), expr()}
          | {:ann, span(), expr(), type_expr()}
          | {:hole, span()}
          | {:dot, span(), expr(), atom()}
          | {:record_construct, span(), atom(), [{atom(), expr()}]}
          | {:record_update, span(), atom() | nil, expr(), [{atom(), expr()}]}
          | {:with, span(), [expr()], [branch()]}

  @type binop ::
          :add | :sub | :mul | :div | :eq | :neq | :lt | :gt | :lte | :gte | :and | :or

  @type unaryop :: :neg | :not

  # ============================================================================
  # Type expressions
  # ============================================================================

  @type type_expr ::
          {:pi, span(), binder(), type_expr(), type_expr()}
          | {:sigma, span(), atom(), type_expr(), type_expr()}
          | {:refinement, span(), atom(), type_expr(), expr()}
          | {:type_universe, span(), non_neg_integer() | nil}
          | expr()

  # ============================================================================
  # Patterns
  # ============================================================================

  @type branch :: {:branch, span(), pattern(), expr()}

  @type pattern ::
          {:pat_var, span(), atom()}
          | {:pat_lit, span(), literal()}
          | {:pat_constructor, span(), atom(), [pattern()]}
          | {:pat_wildcard, span()}
          | {:pat_record, span(), atom(), [{atom(), pattern()}]}

  # ============================================================================
  # Top-level declarations
  # ============================================================================

  @type toplevel ::
          {:def, span(), signature(), expr()}
          | {:type_decl, span(), atom(), [type_param()], [constructor()]}
          | {:import, span(), module_path(), open_option()}
          | {:implicit_decl, span(), [param()]}
          | {:mutual, span(), [toplevel()]}
          | {:class_decl, span(), atom(), [param()], [constraint()], [method_sig()]}
          | {:instance_decl, span(), atom(), [type_expr()], [constraint()], [method_impl()]}
          | {:record_decl, span(), atom(), [param()], [field()]}

  @type program :: [toplevel()]

  @typedoc "Type parameter with optional kind annotation."
  @type type_param :: {atom(), type_expr()}

  @typedoc "ADT constructor with positional type args, optional return type for GADTs."
  @type constructor :: {:constructor, span(), atom(), [type_expr()], type_expr() | nil}

  @typedoc "Named field in a constructor or record."
  @type field :: {:field, span(), atom(), type_expr()}

  @typedoc "Module path as a list of atoms, e.g., [:Data, :Vec]."
  @type module_path :: [atom()]

  @typedoc "Import open option: true for all, list of atoms for selective, nil for qualified only."
  @type open_option :: boolean() | [atom()] | nil

  @typedoc "Type class constraint, e.g., Eq(a)."
  @type constraint :: {:constraint, span(), atom(), [type_expr()]}

  @typedoc "Method signature in a class declaration."
  @type method_sig :: {:method_sig, span(), atom(), type_expr()}

  @typedoc "Method implementation in an instance declaration."
  @type method_impl :: {:method_impl, span(), atom(), expr()}

  # ============================================================================
  # Span extraction
  # ============================================================================

  @doc """
  Returns the span of any AST node.

  All AST nodes are tagged tuples with the span in the second position.
  """
  @spec span(
          expr()
          | toplevel()
          | type_expr()
          | pattern()
          | branch()
          | param()
          | constructor()
          | signature()
          | field()
          | constraint()
          | method_sig()
          | method_impl()
        ) :: span()
  def span(node) when is_tuple(node) and tuple_size(node) >= 2 do
    elem(node, 1)
  end
end
