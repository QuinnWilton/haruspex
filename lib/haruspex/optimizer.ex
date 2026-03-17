defmodule Haruspex.Optimizer do
  @moduledoc """
  E-graph optimization orchestrator.

  Implements a lower/saturate/extract/lift pipeline using the quail library
  for equality saturation. The optimizer applies algebraic simplification
  rules to core terms, finding equivalent but cheaper representations.

  ## Pipeline

      Core.expr → Lower → IR → e-graph → saturate → extract → IR → Lift → Core.expr

  The optimizer is invoked between type checking and code generation. It
  preserves the semantics of the input term while potentially reducing it.
  """

  alias Haruspex.Core
  alias Haruspex.Optimizer.Cost
  alias Haruspex.Optimizer.Lift
  alias Haruspex.Optimizer.Lower
  alias Haruspex.Optimizer.Rules

  @doc """
  Optimize a core expression using equality saturation.

  Lowers the term to IR, adds it to a quail e-graph, runs saturation with
  the rewrite rules, extracts the cheapest equivalent term, and lifts it
  back to a core expression.
  """
  @spec optimize(Core.expr()) :: Core.expr()
  def optimize(term) do
    ir = Lower.lower(term)
    ir = reduce(ir)
    db = Quail.new()
    {root_id, db} = Quail.add_term(db, ir)
    result = Quail.run(db, Rules.rules(), iter_limit: 30)

    case Quail.extract(result.database, root_id, Cost) do
      {:ok, optimized_ir} ->
        Lift.lift(optimized_ir)

      {:error, _reason} ->
        # If extraction fails (cycle, dangling slot), return the original term.
        term
    end
  end

  # Pre-optimization reductions that are hard to express as e-graph rules.
  # Walks the IR tree and reduces known-scrutinee case expressions and
  # constant arithmetic.
  @spec reduce(Lower.ir()) :: Lower.ir()
  defp reduce({:ir_case, scrutinee, branches}) do
    scrutinee = reduce(scrutinee)

    case scrutinee do
      {:ir_lit, value} ->
        case find_branch(branches, value) do
          {:ok, body} -> reduce(body)
          :error -> {:ir_case, scrutinee, reduce_branches(branches)}
        end

      _ ->
        {:ir_case, scrutinee, reduce_branches(branches)}
    end
  end

  defp reduce({:ir_app, f, a}), do: {:ir_app, reduce(f), reduce(a)}
  defp reduce({:ir_lam, body}), do: {:ir_lam, reduce(body)}
  defp reduce({:ir_let, d, b}), do: {:ir_let, reduce(d), reduce(b)}
  defp reduce({:ir_pair, a, b}), do: {:ir_pair, reduce(a), reduce(b)}
  defp reduce({:ir_fst, e}), do: {:ir_fst, reduce(e)}
  defp reduce({:ir_snd, e}), do: {:ir_snd, reduce(e)}
  defp reduce({:ir_record_proj, f, e}), do: {:ir_record_proj, f, reduce(e)}
  defp reduce(term), do: term

  defp reduce_branches(branches) do
    Enum.map(branches, fn
      {:ir_branch_lit, v, body} -> {:ir_branch_lit, v, reduce(body)}
      {:ir_branch, con, arity, body} -> {:ir_branch, con, arity, reduce(body)}
    end)
  end

  # Find the matching branch for a literal scrutinee.
  defp find_branch(branches, value) do
    Enum.find_value(branches, :error, fn
      {:ir_branch_lit, ^value, body} -> {:ok, body}
      {:ir_branch, :_, _arity, body} -> {:ok, body}
      _ -> nil
    end)
  end
end
