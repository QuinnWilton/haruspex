defmodule Haruspex.Optimizer.Lift do
  @moduledoc """
  Lifts optimized IR tuples back to core terms.

  The inverse of `Haruspex.Optimizer.Lower`. Transforms `ir_*` tagged tuples
  back to their corresponding core term representations. Type-level terms
  that passed through lowering unchanged are returned as-is.
  """

  alias Haruspex.Core
  alias Haruspex.Optimizer.Lower

  @doc """
  Lift an IR term back to a core expression.
  """
  @spec lift(term()) :: Core.expr()
  def lift({:ir_var, ix}), do: {:var, ix}
  def lift({:ir_lit, v}), do: {:lit, v}
  def lift({:ir_builtin, name}), do: {:builtin, name}
  def lift({:ir_def_ref, name}), do: {:def_ref, name}
  def lift(:erased), do: :erased

  def lift({:ir_extern, m, f, a}), do: {:extern, m, f, a}

  def lift({:ir_app, f, a}), do: {:app, lift(f), lift(a)}

  # Lambdas lose their multiplicity during lowering; default to :omega.
  def lift({:ir_lam, body}), do: {:lam, :omega, lift(body)}

  def lift({:ir_let, def_val, body}), do: {:let, lift(def_val), lift(body)}

  def lift({:ir_pair, a, b}), do: {:pair, lift(a), lift(b)}
  def lift({:ir_fst, e}), do: {:fst, lift(e)}
  def lift({:ir_snd, e}), do: {:snd, lift(e)}

  def lift({:ir_record_proj, field, expr}), do: {:record_proj, field, lift(expr)}

  # Case expressions have branches as a list.
  def lift({:ir_case, _, _} = term), do: lift_case(term)

  # Constructor and other variable-arity tuples extracted from the e-graph.
  def lift(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 1 do
    op = elem(tuple, 0)

    case Lower.decode_con_op(op) do
      {:ok, {type_name, con_name}} ->
        args =
          if tuple_size(tuple) > 1 do
            1..(tuple_size(tuple) - 1)//1
            |> Enum.map(fn i -> lift(elem(tuple, i)) end)
          else
            []
          end

        {:con, type_name, con_name, args}

      :error ->
        # Type-level terms or unknown forms pass through.
        tuple
    end
  end

  # Lift a case expression from IR. Branches are a list of ir_branch tuples.
  defp lift_case({:ir_case, scrut_ir, branches_list}) when is_list(branches_list) do
    scrutinee = lift(scrut_ir)

    branches =
      Enum.map(branches_list, fn
        {:ir_branch_lit, value, body_ir} ->
          {:__lit, value, lift(body_ir)}

        {:ir_branch, con_name, arity, body_ir} ->
          {con_name, arity, lift(body_ir)}
      end)

    {:case, scrutinee, branches}
  end
end
