defmodule Haruspex.OptimizerTest do
  use ExUnit.Case, async: true

  alias Haruspex.Core
  alias Haruspex.Optimizer
  alias Haruspex.Optimizer.Lift
  alias Haruspex.Optimizer.Lower

  # ============================================================================
  # Lower/lift roundtrip
  # ============================================================================

  describe "lower/lift roundtrip" do
    test "literal roundtrips" do
      term = {:lit, 42}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "variable roundtrips" do
      term = {:var, 0}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "builtin roundtrips" do
      term = {:builtin, :add}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "application roundtrips" do
      term = {:app, {:var, 1}, {:var, 0}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "lambda roundtrips (multiplicity defaults to :omega)" do
      # Lowering erases multiplicity; lifting defaults to :omega.
      term = {:lam, :omega, {:var, 0}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "let roundtrips" do
      term = {:let, {:lit, 1}, {:var, 0}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "pair roundtrips" do
      term = {:pair, {:lit, 1}, {:lit, 2}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "fst roundtrips" do
      term = {:fst, {:pair, {:lit, 1}, {:lit, 2}}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "snd roundtrips" do
      term = {:snd, {:pair, {:lit, 1}, {:lit, 2}}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "constructor roundtrips" do
      term = {:con, :Bool, :True, []}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "constructor with args roundtrips" do
      term = {:con, :Maybe, :Just, [{:lit, 42}]}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "def_ref roundtrips" do
      term = {:def_ref, :my_func}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "extern roundtrips" do
      term = {:extern, Kernel, :+, 2}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "erased roundtrips" do
      assert :erased == :erased |> Lower.lower() |> Lift.lift()
    end

    test "nested expression roundtrips" do
      # (fn x -> x + 0)(42)
      term =
        {:app, {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 0}}, {:lit, 0}}}, {:lit, 42}}

      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "case expression roundtrips" do
      term =
        {:case, {:var, 0},
         [
           {:True, 0, {:lit, 1}},
           {:False, 0, {:lit, 0}}
         ]}

      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "type-level terms pass through unchanged" do
      pi = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      assert pi == pi |> Lower.lower() |> Lift.lift()

      sigma = {:sigma, {:builtin, :Int}, {:builtin, :Int}}
      assert sigma == sigma |> Lower.lower() |> Lift.lift()

      type = {:type, {:llit, 0}}
      assert type == type |> Lower.lower() |> Lift.lift()
    end

    test "spanned terms are stripped during lowering" do
      inner = {:lit, 42}
      spanned = {:spanned, {0, 2}, inner}
      assert inner == spanned |> Lower.lower() |> Lift.lift()
    end
  end

  # ============================================================================
  # Arithmetic optimization
  # ============================================================================

  describe "arithmetic optimization" do
    test "x + 0 simplifies to x" do
      # {:app, {:app, {:builtin, :add}, {:var, 0}}, {:lit, 0}}
      term = Core.app(Core.app(Core.builtin(:add), Core.var(0)), Core.lit(0))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "0 + x simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:add), Core.lit(0)), Core.var(0))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "x * 1 simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:mul), Core.var(0)), Core.lit(1))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "1 * x simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:mul), Core.lit(1)), Core.var(0))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "x * 0 simplifies to 0" do
      term = Core.app(Core.app(Core.builtin(:mul), Core.var(0)), Core.lit(0))
      result = Optimizer.optimize(term)
      assert result == {:lit, 0}
    end

    test "0 * x simplifies to 0" do
      term = Core.app(Core.app(Core.builtin(:mul), Core.lit(0)), Core.var(0))
      result = Optimizer.optimize(term)
      assert result == {:lit, 0}
    end

    test "x - 0 simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:sub), Core.var(0)), Core.lit(0))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "x - x simplifies to 0" do
      term = Core.app(Core.app(Core.builtin(:sub), Core.var(0)), Core.var(0))
      result = Optimizer.optimize(term)
      assert result == {:lit, 0}
    end

    test "nested: (x + 0) * 1 simplifies to x" do
      inner = Core.app(Core.app(Core.builtin(:add), Core.var(0)), Core.lit(0))
      term = Core.app(Core.app(Core.builtin(:mul), inner), Core.lit(1))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end
  end

  # ============================================================================
  # Boolean optimization
  # ============================================================================

  describe "boolean optimization" do
    test "not(not(x)) simplifies to x" do
      term = Core.app(Core.builtin(:not), Core.app(Core.builtin(:not), Core.var(0)))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "true and x simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:and), Core.lit(true)), Core.var(0))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "x and true simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:and), Core.var(0)), Core.lit(true))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "false or x simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:or), Core.lit(false)), Core.var(0))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "x or false simplifies to x" do
      term = Core.app(Core.app(Core.builtin(:or), Core.var(0)), Core.lit(false))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end
  end

  # ============================================================================
  # Pair projection optimization
  # ============================================================================

  describe "pair projection optimization" do
    test "fst(pair(a, b)) simplifies to a" do
      term = Core.fst(Core.pair(Core.var(0), Core.var(1)))
      result = Optimizer.optimize(term)
      assert result == {:var, 0}
    end

    test "snd(pair(a, b)) simplifies to b" do
      term = Core.snd(Core.pair(Core.var(0), Core.var(1)))
      result = Optimizer.optimize(term)
      assert result == {:var, 1}
    end

    test "fst(pair(lit, lit)) simplifies to first lit" do
      term = Core.fst(Core.pair(Core.lit(1), Core.lit(2)))
      result = Optimizer.optimize(term)
      assert result == {:lit, 1}
    end

    test "snd(pair(lit, lit)) simplifies to second lit" do
      term = Core.snd(Core.pair(Core.lit(1), Core.lit(2)))
      result = Optimizer.optimize(term)
      assert result == {:lit, 2}
    end
  end

  # ============================================================================
  # No-op optimization
  # ============================================================================

  describe "no-op optimization" do
    test "already optimal literal passes through" do
      term = {:lit, 42}
      assert Optimizer.optimize(term) == {:lit, 42}
    end

    test "already optimal variable passes through" do
      term = {:var, 0}
      assert Optimizer.optimize(term) == {:var, 0}
    end

    test "already optimal application passes through" do
      term = {:app, {:var, 1}, {:var, 0}}
      assert Optimizer.optimize(term) == {:app, {:var, 1}, {:var, 0}}
    end

    test "already optimal lambda passes through" do
      term = {:lam, :omega, {:var, 0}}
      assert Optimizer.optimize(term) == {:lam, :omega, {:var, 0}}
    end

    test "irreducible arithmetic passes through" do
      # x + y where neither is 0 — no rules apply.
      term = Core.app(Core.app(Core.builtin(:add), Core.var(0)), Core.var(1))
      result = Optimizer.optimize(term)
      assert result == term
    end
  end

  # ============================================================================
  # Integration
  # ============================================================================

  describe "integration" do
    test "optimizes function body: fn x -> (x + 0) * 1 => fn x -> x" do
      body =
        Core.app(
          Core.app(
            Core.builtin(:mul),
            Core.app(Core.app(Core.builtin(:add), Core.var(0)), Core.lit(0))
          ),
          Core.lit(1)
        )

      term = Core.lam(:omega, body)
      result = Optimizer.optimize(term)
      assert result == {:lam, :omega, {:var, 0}}
    end

    test "optimizes nested let with identity arithmetic" do
      # let x = 42 in x + 0
      term =
        Core.let_(
          Core.lit(42),
          Core.app(Core.app(Core.builtin(:add), Core.var(0)), Core.lit(0))
        )

      result = Optimizer.optimize(term)
      assert result == {:let, {:lit, 42}, {:var, 0}}
    end

    test "optimizes through constructors" do
      # Just(x + 0)
      inner = Core.app(Core.app(Core.builtin(:add), Core.var(0)), Core.lit(0))
      term = {:con, :Maybe, :Just, [inner]}
      result = Optimizer.optimize(term)
      assert result == {:con, :Maybe, :Just, [{:var, 0}]}
    end
  end

  # ============================================================================
  # Lower/lift edge cases for coverage
  # ============================================================================

  describe "lower/lift edge cases" do
    test "record_proj roundtrips" do
      term = {:record_proj, :name, {:var, 0}}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "data passes through lower and lift" do
      term = {:data, :Nat, [{:builtin, :Int}]}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "refine passes through lower and lift" do
      term = {:refine, {:builtin, :Int}, :positive, :some_pred}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "global lowers to ir_extern and lifts to extern" do
      term = {:global, MyMod, :func, 2}
      ir = Lower.lower(term)
      assert ir == {:ir_extern, MyMod, :func, 2}
      assert Lift.lift(ir) == {:extern, MyMod, :func, 2}
    end

    test "meta passes through lower and lift" do
      term = {:meta, 5}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "inserted_meta passes through lower and lift" do
      term = {:inserted_meta, 3, [true, false]}
      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "case with literal branches roundtrips" do
      term =
        {:case, {:var, 0},
         [
           {:__lit, 0, {:lit, :zero}},
           {:__lit, 1, {:lit, :one}}
         ]}

      assert term == term |> Lower.lower() |> Lift.lift()
    end

    test "constructor with multiple args roundtrips" do
      term = {:con, :Pair, :MkPair, [{:lit, 1}, {:lit, 2}]}
      assert term == term |> Lower.lower() |> Lift.lift()
    end
  end

  # ============================================================================
  # Constructor encoding
  # ============================================================================

  describe "con_op encoding" do
    test "encodes and decodes type/constructor pair" do
      op = Lower.con_op(:Maybe, :Just)
      assert op == :ir_con__Maybe__Just
      assert {:ok, {:Maybe, :Just}} == Lower.decode_con_op(op)
    end

    test "decode_con_op returns :error for non-constructor atoms" do
      assert :error == Lower.decode_con_op(:ir_app)
      assert :error == Lower.decode_con_op(:foo)
    end

    test "decode_con_op returns :error for malformed constructor atoms" do
      assert :error == Lower.decode_con_op(:ir_con__nounderscore)
    end
  end

  # ============================================================================
  # Cost model
  # ============================================================================

  describe "cost model" do
    test "constructor atoms get base cost 2" do
      enode = %Quail.ENode{op: :ir_con__Maybe__Just, children: [], data: []}
      cost = Haruspex.Optimizer.Cost.node_cost(enode, %{})
      assert cost == 2
    end

    test "known ops get their assigned base cost" do
      enode = %Quail.ENode{op: :ir_app, children: [], data: []}
      assert Haruspex.Optimizer.Cost.node_cost(enode, %{}) == 2

      enode = %Quail.ENode{op: :ir_lam, children: [], data: []}
      assert Haruspex.Optimizer.Cost.node_cost(enode, %{}) == 3

      enode = %Quail.ENode{op: :ir_lit, children: [], data: []}
      assert Haruspex.Optimizer.Cost.node_cost(enode, %{}) == 1
    end

    test "unknown ops get base cost 1" do
      enode = %Quail.ENode{op: :unknown_op, children: [], data: []}
      assert Haruspex.Optimizer.Cost.node_cost(enode, %{}) == 1
    end

    test "children costs are summed with base cost" do
      enode = %Quail.ENode{op: :ir_app, children: [{1, %{}}, {2, %{}}], data: []}
      child_costs = %{1 => 3, 2 => 5}
      assert Haruspex.Optimizer.Cost.node_cost(enode, child_costs) == 2 + 3 + 5
    end
  end
end
