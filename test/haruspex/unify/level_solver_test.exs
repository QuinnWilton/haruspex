defmodule Haruspex.Unify.LevelSolverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Unify.LevelSolver

  # ============================================================================
  # Basic constraint solving
  # ============================================================================

  describe "solve/1" do
    test "no constraints returns empty map" do
      assert LevelSolver.solve([]) == {:ok, %{}}
    end

    test "eq with literal: {:lvar, 0} = {:llit, 0}" do
      constraints = [{:eq, {:lvar, 0}, {:llit, 0}}]
      assert {:ok, %{0 => 0}} = LevelSolver.solve(constraints)
    end

    test "eq with succ: {:lvar, 0} = succ({:llit, 0})" do
      constraints = [{:eq, {:lvar, 0}, {:lsucc, {:llit, 0}}}]
      assert {:ok, %{0 => 1}} = LevelSolver.solve(constraints)
    end

    test "eq with max: {:lvar, 0} = max({:llit, 0}, {:llit, 1})" do
      constraints = [{:eq, {:lvar, 0}, {:lmax, {:llit, 0}, {:llit, 1}}}]
      assert {:ok, %{0 => 1}} = LevelSolver.solve(constraints)
    end

    test "transitive: {:lvar, 0} = {:lvar, 1}, {:lvar, 1} = {:llit, 0}" do
      constraints = [
        {:eq, {:lvar, 0}, {:lvar, 1}},
        {:eq, {:lvar, 1}, {:llit, 0}}
      ]

      assert {:ok, result} = LevelSolver.solve(constraints)
      assert result[0] == 0
      assert result[1] == 0
    end

    test "succ chain: {:lvar, 0} = succ({:lvar, 1}), {:lvar, 1} = {:llit, 2}" do
      constraints = [
        {:eq, {:lvar, 0}, {:lsucc, {:lvar, 1}}},
        {:eq, {:lvar, 1}, {:llit, 2}}
      ]

      assert {:ok, result} = LevelSolver.solve(constraints)
      assert result[0] == 3
      assert result[1] == 2
    end

    test "leq constraint: {:lvar, 0} <= {:llit, 3}" do
      constraints = [{:leq, {:lvar, 0}, {:llit, 3}}]
      # Variable starts at 0, which is <= 3, so it stays at 0.
      assert {:ok, %{0 => 0}} = LevelSolver.solve(constraints)
    end

    test "leq forces raising: {:llit, 5} <= {:lvar, 0}" do
      constraints = [{:leq, {:llit, 5}, {:lvar, 0}}]
      assert {:ok, %{0 => val}} = LevelSolver.solve(constraints)
      assert val >= 5
    end

    test "cyclic constraint: ?l = succ(?l) produces error" do
      constraints = [{:eq, {:lvar, 0}, {:lsucc, {:lvar, 0}}}]
      assert {:error, {:universe_cycle, _}} = LevelSolver.solve(constraints)
    end

    test "multiple variables with shared constraints" do
      constraints = [
        {:eq, {:lvar, 0}, {:llit, 1}},
        {:eq, {:lvar, 1}, {:lmax, {:lvar, 0}, {:llit, 2}}},
        {:eq, {:lvar, 2}, {:lsucc, {:lvar, 1}}}
      ]

      assert {:ok, result} = LevelSolver.solve(constraints)
      assert result[0] == 1
      assert result[1] == 2
      assert result[2] == 3
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "determinism: same constraints always produce same result" do
      check all(
              n <- integer(0..10),
              m <- integer(0..10)
            ) do
        constraints = [{:eq, {:lvar, 0}, {:lmax, {:llit, n}, {:llit, m}}}]
        result1 = LevelSolver.solve(constraints)
        result2 = LevelSolver.solve(constraints)
        assert result1 == result2
      end
    end

    property "eq constraint satisfies equality after solving" do
      check all(n <- integer(0..100)) do
        constraints = [{:eq, {:lvar, 0}, {:llit, n}}]
        {:ok, result} = LevelSolver.solve(constraints)
        assert result[0] == n
      end
    end

    property "succ constraint produces value one greater" do
      check all(n <- integer(0..100)) do
        constraints = [{:eq, {:lvar, 0}, {:lsucc, {:llit, n}}}]
        {:ok, result} = LevelSolver.solve(constraints)
        assert result[0] == n + 1
      end
    end
  end
end
