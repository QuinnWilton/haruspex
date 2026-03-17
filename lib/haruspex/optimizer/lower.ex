defmodule Haruspex.Optimizer.Lower do
  @moduledoc """
  Lowers core terms to flat IR tuples suitable for quail e-graphs.

  Core terms use de Bruijn indices, nested application, and type-level nodes.
  The IR preserves the computational structure while flattening to a uniform
  tagged-tuple representation that quail can pattern-match and rewrite.

  Type-level terms (`:pi`, `:sigma`, `:type`, `:refine`) pass through unchanged
  since they carry no runtime behavior worth optimizing.

  Constructors are encoded with generated atom operators (`:"ir_con__Type__Con"`)
  so that quail recognizes them as expression tuples and recurses into their
  children. Use `con_op/2` and `decode_con_op/1` to convert between the
  `{type, con}` pair and the atom representation.
  """

  alias Haruspex.Core

  @type ir ::
          {:ir_var, Core.ix()}
          | {:ir_lit, Core.literal()}
          | {:ir_app, ir(), ir()}
          | {:ir_lam, ir()}
          | {:ir_builtin, atom()}
          | {:ir_case, ir(), [ir()]}
          | {:ir_let, ir(), ir()}
          | {:ir_pair, ir(), ir()}
          | {:ir_fst, ir()}
          | {:ir_snd, ir()}
          | {:ir_def_ref, atom()}
          | {:ir_extern, module(), atom(), arity()}
          | {:ir_record_proj, atom(), ir()}
          | tuple()
          | :erased
          | Core.expr()

  # ============================================================================
  # Constructor encoding
  # ============================================================================

  @doc """
  Encode a constructor type+name pair as an atom operator for the e-graph.
  """
  @spec con_op(atom(), atom()) :: atom()
  def con_op(type_name, con_name) do
    :"ir_con__#{type_name}__#{con_name}"
  end

  @doc """
  Decode a constructor operator atom back to `{type_name, con_name}`.

  Returns `{:ok, {type, con}}` if the atom matches the encoding, `:error` otherwise.
  """
  @spec decode_con_op(atom()) :: {:ok, {atom(), atom()}} | :error
  def decode_con_op(op) when is_atom(op) do
    case Atom.to_string(op) do
      "ir_con__" <> rest ->
        case String.split(rest, "__", parts: 2) do
          [type_str, con_str] ->
            {:ok, {String.to_atom(type_str), String.to_atom(con_str)}}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # ============================================================================
  # Lowering
  # ============================================================================

  @doc """
  Lower a core expression to IR.

  Recursively transforms computational core terms into `ir_*` tagged tuples.
  Type-level terms pass through unchanged.
  """
  @spec lower(Core.expr()) :: ir()
  def lower({:var, ix}), do: {:ir_var, ix}
  def lower({:lit, v}), do: {:ir_lit, v}
  def lower({:builtin, name}), do: {:ir_builtin, name}
  def lower({:def_ref, name}), do: {:ir_def_ref, name}
  def lower(:erased), do: :erased
  def lower({:extern, m, f, a}), do: {:ir_extern, m, f, a}
  def lower({:global, m, f, a}), do: {:ir_extern, m, f, a}
  def lower({:app, f, a}), do: {:ir_app, lower(f), lower(a)}
  def lower({:lam, _mult, body}), do: {:ir_lam, lower(body)}
  def lower({:let, def_val, body}), do: {:ir_let, lower(def_val), lower(body)}
  def lower({:pair, a, b}), do: {:ir_pair, lower(a), lower(b)}
  def lower({:fst, e}), do: {:ir_fst, lower(e)}
  def lower({:snd, e}), do: {:ir_snd, lower(e)}

  def lower({:con, type_name, con_name, args}) do
    lowered_args = Enum.map(args, &lower/1)
    op = con_op(type_name, con_name)
    List.to_tuple([op | lowered_args])
  end

  def lower({:case, scrutinee, branches}) do
    lowered_scrut = lower(scrutinee)

    lowered_branches =
      Enum.map(branches, fn
        {:__lit, value, body} -> {:ir_branch_lit, value, lower(body)}
        {con_name, arity, body} -> {:ir_branch, con_name, arity, lower(body)}
      end)

    {:ir_case, lowered_scrut, lowered_branches}
  end

  # Type-level terms pass through unchanged.
  def lower({:pi, _, _, _} = term), do: term
  def lower({:sigma, _, _} = term), do: term
  def lower({:type, _} = term), do: term
  def lower({:refine, _, _, _} = term), do: term

  # Data declarations are type-level; pass through.
  def lower({:data, _, _} = term), do: term

  # Strip source spans, lowering the inner term.
  def lower({:spanned, _span, inner}), do: lower(inner)

  # Record projection.
  def lower({:record_proj, field, expr}), do: {:ir_record_proj, field, lower(expr)}

  # Metas should be solved before optimization; pass through as fallback.
  def lower({:meta, _} = term), do: term
  def lower({:inserted_meta, _, _} = term), do: term
end
