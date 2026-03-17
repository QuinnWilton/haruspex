defmodule Haruspex.Optimizer.Cost do
  @moduledoc """
  Cost model for quail e-graph extraction.

  Assigns base costs to each IR node type and sums children costs to determine
  the cheapest equivalent term in each e-class. Lower cost means the term is
  preferred during extraction.

  Base costs reflect runtime expense:
  - Literals, variables, builtins, def refs, externs: 1 (leaf nodes, cheap)
  - Application, pairs, projections, constructors, let: 2 (one level of indirection)
  - Lambda, case: 3 (closure allocation or branching overhead)
  """

  @behaviour Quail.Extract

  # Base costs by IR node operator.
  @base_costs %{
    ir_lit: 1,
    ir_var: 1,
    ir_builtin: 1,
    ir_def_ref: 1,
    ir_extern: 1,
    ir_app: 2,
    ir_pair: 2,
    ir_fst: 2,
    ir_snd: 2,
    ir_con: 2,
    ir_let: 2,
    ir_record_proj: 2,
    ir_lam: 3,
    ir_case: 3
  }

  @impl Quail.Extract
  @spec node_cost(Quail.ENode.t(), %{Quail.EGraph.id() => number()}) :: number()
  def node_cost(%Quail.ENode{op: op}, child_costs) do
    base = base_cost(op)
    children_total = child_costs |> Map.values() |> Enum.sum()
    base + children_total
  end

  @spec base_cost(atom()) :: number()
  defp base_cost(op) when is_atom(op) do
    case Map.get(@base_costs, op) do
      nil ->
        # Constructor atoms are encoded as :"ir_con__Type__Con".
        case Haruspex.Optimizer.Lower.decode_con_op(op) do
          {:ok, _} -> 2
          :error -> 1
        end

      cost ->
        cost
    end
  end

  defp base_cost(_), do: 1
end
