defmodule Haruspex.Unify.MetaStateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Unify.MetaState

  # ============================================================================
  # Fresh meta creation
  # ============================================================================

  describe "fresh_meta/4" do
    test "increments ID and stores unsolved entry" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}

      {id0, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)
      assert id0 == 0
      assert MetaState.lookup(ms, 0) == {:unsolved, type, 0, :implicit}

      {id1, ms} = MetaState.fresh_meta(ms, type, 1, :hole)
      assert id1 == 1
      assert MetaState.lookup(ms, 1) == {:unsolved, type, 1, :hole}
      # Previous entry still accessible.
      assert MetaState.lookup(ms, 0) == {:unsolved, type, 0, :implicit}
    end

    test "each call produces a unique ID" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}

      {ids, _ms} =
        Enum.reduce(0..9, {[], ms}, fn _, {ids, ms} ->
          {id, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)
          {[id | ids], ms}
        end)

      assert length(Enum.uniq(ids)) == 10
    end
  end

  # ============================================================================
  # Solving
  # ============================================================================

  describe "solve/3" do
    test "transitions unsolved to solved" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}
      {id, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)

      assert {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})
      assert MetaState.lookup(ms, id) == {:solved, {:vlit, 42}}
    end

    test "solving with same value returns ok" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}
      {id, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert {:ok, ^ms} = MetaState.solve(ms, id, {:vlit, 42})
    end

    test "solving with different value returns error" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}
      {id, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert {:error, :already_solved} = MetaState.solve(ms, id, {:vlit, 99})
    end
  end

  # ============================================================================
  # Lookup
  # ============================================================================

  describe "lookup/2" do
    test "returns correct entry for unsolved meta" do
      ms = MetaState.new()
      type = {:vbuiltin, :Int}
      {id, ms} = MetaState.fresh_meta(ms, type, 3, :hole)

      assert MetaState.lookup(ms, id) == {:unsolved, {:vbuiltin, :Int}, 3, :hole}
    end

    test "returns correct entry for solved meta" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, "hello"})

      assert MetaState.lookup(ms, id) == {:solved, {:vlit, "hello"}}
    end

    test "raises on unknown ID" do
      ms = MetaState.new()
      assert_raise KeyError, fn -> MetaState.lookup(ms, 99) end
    end
  end

  # ============================================================================
  # Forcing
  # ============================================================================

  describe "force/2" do
    test "returns non-meta values unchanged" do
      ms = MetaState.new()
      assert MetaState.force(ms, {:vlit, 42}) == {:vlit, 42}
      assert MetaState.force(ms, {:vtype, {:llit, 0}}) == {:vtype, {:llit, 0}}
    end

    test "returns unsolved meta unchanged" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      meta_val = {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id}}

      assert MetaState.force(ms, meta_val) == meta_val
    end

    test "follows single solved meta" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      meta_val = {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id}}
      assert MetaState.force(ms, meta_val) == {:vlit, 42}
    end

    test "follows solved meta chain: A -> B -> VLit(42)" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}

      {id_a, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)
      {id_b, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)

      # Solve B to VLit(42).
      {:ok, ms} = MetaState.solve(ms, id_b, {:vlit, 42})

      # Solve A to meta B.
      b_val = {:vneutral, type, {:nmeta, id_b}}
      {:ok, ms} = MetaState.solve(ms, id_a, b_val)

      a_val = {:vneutral, type, {:nmeta, id_a}}
      assert MetaState.force(ms, a_val) == {:vlit, 42}
    end

    test "handles cycle without infinite loop" do
      ms = MetaState.new()
      type = {:vtype, {:llit, 0}}
      {id, ms} = MetaState.fresh_meta(ms, type, 0, :implicit)

      # Solve meta to itself (a cycle).
      self_val = {:vneutral, type, {:nmeta, id}}
      {:ok, ms} = MetaState.solve(ms, id, self_val)

      # Should terminate and return the meta value.
      assert MetaState.force(ms, self_val) == self_val
    end
  end

  # ============================================================================
  # Level constraints
  # ============================================================================

  describe "add_constraint/2" do
    test "accumulates constraints" do
      ms = MetaState.new()
      assert ms.level_constraints == []

      ms = MetaState.add_constraint(ms, {:eq, {:lvar, 0}, {:llit, 1}})
      assert length(ms.level_constraints) == 1

      ms = MetaState.add_constraint(ms, {:leq, {:lvar, 1}, {:lvar, 0}})
      assert length(ms.level_constraints) == 2
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "solve idempotence: solving twice with same value doesn't change state" do
      check all(n <- integer()) do
        ms = MetaState.new()
        {id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
        {:ok, ms1} = MetaState.solve(ms, id, {:vlit, n})
        {:ok, ms2} = MetaState.solve(ms1, id, {:vlit, n})
        assert ms1 == ms2
      end
    end
  end
end
