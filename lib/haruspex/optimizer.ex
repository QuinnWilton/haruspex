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
end
