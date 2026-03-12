defmodule Haruspex.Unify.LevelSolver do
  @moduledoc """
  Universe level constraint solver.

  Solves systems of level constraints via fixpoint iteration. Level expressions
  are built from literals, variables, successor, and max. Constraints are
  equalities and inequalities between level expressions.
  """

  alias Haruspex.Core

  @max_iterations 100

  # ============================================================================
  # Types
  # ============================================================================

  @type level_constraint :: {:eq, Core.level(), Core.level()} | {:leq, Core.level(), Core.level()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Solve a list of level constraints, returning a mapping from level variable IDs
  to concrete level values.

  Uses fixpoint iteration: initialize all variables to 0, then repeatedly evaluate
  constraints and raise variable assignments until stable. Returns an error if the
  system doesn't converge within #{@max_iterations} iterations.
  """
  @spec solve([level_constraint()]) ::
          {:ok, %{non_neg_integer() => non_neg_integer()}}
          | {:error, {:universe_cycle, [level_constraint()]}}
  def solve(constraints) when is_list(constraints) do
    vars = collect_vars(constraints)
    initial = Map.new(vars, fn v -> {v, 0} end)
    iterate(constraints, initial, 0)
  end

  # ============================================================================
  # Fixpoint iteration
  # ============================================================================

  defp iterate(constraints, _assignments, iteration) when iteration >= @max_iterations do
    {:error, {:universe_cycle, constraints}}
  end

  defp iterate(constraints, assignments, iteration) do
    updated =
      Enum.reduce(constraints, assignments, fn constraint, acc ->
        apply_constraint(constraint, acc)
      end)

    if updated == assignments do
      {:ok, assignments}
    else
      iterate(constraints, updated, iteration + 1)
    end
  end

  defp apply_constraint({:eq, lhs, rhs}, assignments) do
    lhs_val = eval_level(lhs, assignments)
    rhs_val = eval_level(rhs, assignments)
    target = max(lhs_val, rhs_val)

    assignments
    |> raise_vars(lhs, target)
    |> raise_vars(rhs, target)
  end

  defp apply_constraint({:leq, lhs, rhs}, assignments) do
    lhs_val = eval_level(lhs, assignments)
    rhs_val = eval_level(rhs, assignments)

    if lhs_val > rhs_val do
      # Need to raise rhs variables to accommodate.
      raise_vars(assignments, rhs, lhs_val)
    else
      assignments
    end
  end

  # ============================================================================
  # Level expression evaluation
  # ============================================================================

  @doc """
  Evaluate a level expression given current variable assignments.
  """
  @spec eval_level(Core.level(), %{non_neg_integer() => non_neg_integer()}) ::
          non_neg_integer()
  def eval_level({:llit, n}, _assignments), do: n

  def eval_level({:lvar, id}, assignments) do
    Map.get(assignments, id, 0)
  end

  def eval_level({:lsucc, l}, assignments) do
    eval_level(l, assignments) + 1
  end

  def eval_level({:lmax, l1, l2}, assignments) do
    max(eval_level(l1, assignments), eval_level(l2, assignments))
  end

  # ============================================================================
  # Variable collection and raising
  # ============================================================================

  defp collect_vars(constraints) do
    constraints
    |> Enum.flat_map(fn
      {:eq, lhs, rhs} -> level_vars(lhs) ++ level_vars(rhs)
      {:leq, lhs, rhs} -> level_vars(lhs) ++ level_vars(rhs)
    end)
    |> Enum.uniq()
  end

  defp level_vars({:llit, _}), do: []
  defp level_vars({:lvar, id}), do: [id]
  defp level_vars({:lsucc, l}), do: level_vars(l)
  defp level_vars({:lmax, l1, l2}), do: level_vars(l1) ++ level_vars(l2)

  # Raise all variables in a level expression to at least `target`.
  defp raise_vars(assignments, {:lvar, id}, target) do
    current = Map.get(assignments, id, 0)

    if current < target do
      Map.put(assignments, id, target)
    else
      assignments
    end
  end

  defp raise_vars(assignments, {:lsucc, l}, target) do
    # If lsucc(l) needs to be `target`, then l needs to be `target - 1`.
    if target > 0 do
      raise_vars(assignments, l, target - 1)
    else
      assignments
    end
  end

  defp raise_vars(assignments, {:lmax, l1, l2}, target) do
    # Both sides of max need to be able to reach `target`.
    # Raise the side that's currently lower.
    v1 = eval_level(l1, assignments)
    v2 = eval_level(l2, assignments)

    cond do
      v1 >= target -> assignments
      v2 >= target -> assignments
      true -> raise_vars(raise_vars(assignments, l1, target), l2, target)
    end
  end

  defp raise_vars(assignments, {:llit, _}, _target), do: assignments
end
