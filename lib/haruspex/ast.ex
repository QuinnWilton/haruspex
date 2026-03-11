defmodule Haruspex.AST do
  @moduledoc """
  Surface AST node types for Haruspex.

  Every node carries a `Pentiment.Span.Byte` for error reporting and LSP
  integration. Nodes are plain tagged tuples — no structs.

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

  ## Type expressions

      {:pi, span, name, mult, domain, codomain, implicit?}
      {:sigma, span, name, fst_type, snd_type}
      {:refinement, span, name, base_type, predicate}
      {:type_universe, span, level | nil}

  ## Top-level

      {:def, span, name, name_span, [param], return_type | nil, body, total?}
      {:type_decl, span, name, [type_param], [constructor]}

  ## Patterns

      {:pat_var, span, name}
      {:pat_lit, span, value}
      {:pat_constructor, span, name, [pattern]}
      {:pat_wildcard, span}

  ## Spans

  All spans are `Pentiment.Span.Byte.t()` — byte offset + length, as
  produced by NimbleParsec. Use `Pentiment.Span.Byte.resolve/2` to
  convert to line/column positions for display.
  """

  @type span :: Pentiment.Span.Byte.t()
  @type mult :: :omega | :zero

  @type param ::
          {:param, span(), atom(), type_expr(), mult(), boolean()}

  @type constructor :: {:constructor, span(), atom(), [type_expr()]}

  @type branch :: {:branch, span(), pattern(), expr()}

  @type pattern ::
          {:pat_var, span(), atom()}
          | {:pat_lit, span(), literal()}
          | {:pat_constructor, span(), atom(), [pattern()]}
          | {:pat_wildcard, span()}

  @type literal :: integer() | float() | String.t() | atom() | boolean()

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

  @type type_expr ::
          {:pi, span(), atom(), mult(), type_expr(), type_expr(), boolean()}
          | {:sigma, span(), atom(), type_expr(), type_expr()}
          | {:refinement, span(), atom(), type_expr(), expr()}
          | {:type_universe, span(), non_neg_integer() | nil}
          | expr()

  @type toplevel ::
          {:def, span(), atom(), span(), [param()], type_expr() | nil, expr(), boolean()}
          | {:type_decl, span(), atom(), [atom()], [constructor()]}

  @type program :: [toplevel()]

  @type binop ::
          :add | :sub | :mul | :div | :eq | :neq | :lt | :gt | :lte | :gte | :and | :or

  @type unaryop :: :neg | :not

  @doc """
  Returns the span of any AST node.
  """
  @spec span(expr() | toplevel() | type_expr() | pattern() | branch() | param() | constructor()) ::
          span()
  def span({_tag, %Pentiment.Span.Byte{} = s}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _, _}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _, _, _}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _, _, _, _}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _, _, _, _, _}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _, _, _, _, _, _}), do: s
  def span({_tag, %Pentiment.Span.Byte{} = s, _, _, _, _, _, _, _}), do: s
end
