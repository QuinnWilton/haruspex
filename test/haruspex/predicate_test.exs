defmodule Haruspex.PredicateTest do
  use ExUnit.Case, async: true

  alias Haruspex.Check
  alias Haruspex.Context
  alias Haruspex.Core
  alias Haruspex.Elaborate
  alias Haruspex.Eval
  alias Haruspex.Predicate

  defp span, do: Pentiment.Span.Byte.new(0, 1)

  # ============================================================================
  # Translation: surface predicate -> constrain predicate
  # ============================================================================

  describe "translate/2" do
    test "translates x > 0" do
      surface = {:binop, span(), :gt, {:var, span(), :x}, {:lit, span(), 0}}
      assert {:gt, {:var, :x}, {:lit, 0}} = Predicate.translate(surface, :x)
    end

    test "translates x < 10" do
      surface = {:binop, span(), :lt, {:var, span(), :x}, {:lit, span(), 10}}
      assert {:lt, {:var, :x}, {:lit, 10}} = Predicate.translate(surface, :x)
    end

    test "translates x == 5" do
      surface = {:binop, span(), :eq, {:var, span(), :x}, {:lit, span(), 5}}
      assert {:eq, {:var, :x}, {:lit, 5}} = Predicate.translate(surface, :x)
    end

    test "translates x != 0" do
      surface = {:binop, span(), :neq, {:var, span(), :x}, {:lit, span(), 0}}
      assert {:neq, {:var, :x}, {:lit, 0}} = Predicate.translate(surface, :x)
    end

    test "translates x >= 1" do
      surface = {:binop, span(), :gte, {:var, span(), :x}, {:lit, span(), 1}}
      assert {:gte, {:var, :x}, {:lit, 1}} = Predicate.translate(surface, :x)
    end

    test "translates x <= 100" do
      surface = {:binop, span(), :lte, {:var, span(), :x}, {:lit, span(), 100}}
      assert {:lte, {:var, :x}, {:lit, 100}} = Predicate.translate(surface, :x)
    end

    test "translates conjunction" do
      left = {:binop, span(), :gt, {:var, span(), :x}, {:lit, span(), 0}}
      right = {:binop, span(), :lt, {:var, span(), :x}, {:lit, span(), 100}}
      surface = {:binop, span(), :and, left, right}

      assert {:and, {:gt, {:var, :x}, {:lit, 0}}, {:lt, {:var, :x}, {:lit, 100}}} =
               Predicate.translate(surface, :x)
    end

    test "translates disjunction" do
      left = {:binop, span(), :eq, {:var, span(), :x}, {:lit, span(), 0}}
      right = {:binop, span(), :eq, {:var, span(), :x}, {:lit, span(), 1}}
      surface = {:binop, span(), :or, left, right}

      assert {:or, {:eq, {:var, :x}, {:lit, 0}}, {:eq, {:var, :x}, {:lit, 1}}} =
               Predicate.translate(surface, :x)
    end

    test "translates negation" do
      inner = {:binop, span(), :eq, {:var, span(), :x}, {:lit, span(), 0}}
      surface = {:unaryop, span(), :not, inner}

      assert {:not, {:eq, {:var, :x}, {:lit, 0}}} = Predicate.translate(surface, :x)
    end

    test "translates boolean literal true" do
      assert true == Predicate.translate({:lit, span(), true}, :x)
    end

    test "translates boolean literal false" do
      assert false == Predicate.translate({:lit, span(), false}, :x)
    end
  end

  # ============================================================================
  # Expression translation
  # ============================================================================

  describe "translate_expr/2" do
    test "translates variable reference" do
      assert {:var, :y} = Predicate.translate_expr({:var, span(), :y}, :x)
    end

    test "translates integer literal" do
      assert {:lit, 42} = Predicate.translate_expr({:lit, span(), 42}, :x)
    end

    test "translates arithmetic operation" do
      surface = {:binop, span(), :add, {:var, span(), :x}, {:lit, span(), 1}}
      assert {:op, :add, [{:var, :x}, {:lit, 1}]} = Predicate.translate_expr(surface, :x)
    end

    test "translates negation as subtraction from zero" do
      surface = {:unaryop, span(), :neg, {:var, span(), :x}}
      assert {:op, :sub, [{:lit, 0}, {:var, :x}]} = Predicate.translate_expr(surface, :x)
    end
  end

  # ============================================================================
  # Discharge
  # ============================================================================

  describe "discharge/2" do
    test "tautology: trivially true predicate discharges" do
      assert :yes = Predicate.discharge([], true)
    end

    test "contradiction: false predicate fails" do
      assert :no = Predicate.discharge([], false)
    end

    test "entailment from assumption" do
      # Assume x > 5, check x > 0.
      assumptions = [{:gt, {:var, :x}, {:lit, 5}}]
      goal = {:gt, {:var, :x}, {:lit, 0}}
      assert :yes = Predicate.discharge(assumptions, goal)
    end

    test "failure with no supporting assumptions" do
      # No assumptions, check x > 0.
      goal = {:gt, {:var, :x}, {:lit, 0}}
      result = Predicate.discharge([], goal)
      assert result in [:no, {:unknown, "could not determine entailment"}]
    end

    test "non-zero entailment from neq" do
      # Assume x != 0, check x != 0.
      assumptions = [{:neq, {:var, :x}, {:lit, 0}}]
      goal = {:neq, {:var, :x}, {:lit, 0}}
      assert :yes = Predicate.discharge(assumptions, goal)
    end
  end

  # ============================================================================
  # Assumption gathering
  # ============================================================================

  describe "gather_assumptions/1" do
    test "empty context produces no assumptions" do
      ctx = Context.empty()
      assert [] = Predicate.gather_assumptions(ctx)
    end

    test "non-refinement bindings produce no assumptions" do
      ctx = Context.extend(Context.empty(), :x, {:vbuiltin, :Int}, :omega)
      assert [] = Predicate.gather_assumptions(ctx)
    end

    test "refinement binding produces substituted predicate" do
      # Bind n : {x : Int | x > 0}
      ref_type = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      ctx = Context.extend(Context.empty(), :n, ref_type, :omega)

      assumptions = Predicate.gather_assumptions(ctx)
      assert length(assumptions) == 1
      # The assumption should have :n substituted for :x.
      assert {:gt, {:var, :n}, {:lit, 0}} = hd(assumptions)
    end

    test "multiple refinement bindings produce multiple assumptions" do
      ref_type_1 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      ref_type_2 = {:vrefine, {:vbuiltin, :Int}, :y, {:lt, {:var, :y}, {:lit, 100}}}

      ctx =
        Context.empty()
        |> Context.extend(:a, ref_type_1, :omega)
        |> Context.extend(:b, ref_type_2, :omega)

      assumptions = Predicate.gather_assumptions(ctx)
      assert length(assumptions) == 2
    end
  end

  # ============================================================================
  # Core — subst and shift
  # ============================================================================

  describe "Core.subst for :refine" do
    test "substitutes in the base type" do
      # refine(var(0), :x, pred) with var 0 -> builtin Int
      term = {:refine, {:var, 0}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Core.subst(term, 0, {:builtin, :Int})

      assert {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}} = result
    end

    test "predicate is preserved through substitution" do
      pred = {:neq, {:var, :y}, {:lit, 0}}
      term = {:refine, {:builtin, :Int}, :y, pred}
      result = Core.subst(term, 0, {:lit, 42})

      # Predicate is untouched.
      assert {:refine, {:builtin, :Int}, :y, ^pred} = result
    end
  end

  describe "Core.shift for :refine" do
    test "shifts indices in the base type" do
      term = {:refine, {:var, 0}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Core.shift(term, 1, 0)

      assert {:refine, {:var, 1}, :x, {:gt, {:var, :x}, {:lit, 0}}} = result
    end
  end

  # ============================================================================
  # Value domain — eval and quote
  # ============================================================================

  describe "eval for :refine" do
    test "evaluates to vrefine value" do
      ctx = Eval.default_ctx()
      term = {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Eval.eval(ctx, term)

      assert {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}} = result
    end
  end

  describe "quote for :vrefine" do
    test "quotes back to :refine core term" do
      value = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Haruspex.Quote.quote_untyped(0, value)

      assert {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}} = result
    end
  end

  # ============================================================================
  # Elaboration
  # ============================================================================

  describe "elaborate_type for :refinement" do
    test "elaborates refinement type to core :refine" do
      ctx = Elaborate.new()

      surface =
        {:refinement, span(), :x, {:var, span(), :Int},
         {:binop, span(), :gt, {:var, span(), :x}, {:lit, span(), 0}}}

      assert {:ok, {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}, _ctx} =
               Elaborate.elaborate_type(ctx, surface)
    end

    test "elaborates refinement with equality predicate" do
      ctx = Elaborate.new()

      surface =
        {:refinement, span(), :y, {:var, span(), :Int},
         {:binop, span(), :neq, {:var, span(), :y}, {:lit, span(), 0}}}

      assert {:ok, {:refine, {:builtin, :Int}, :y, {:neq, {:var, :y}, {:lit, 0}}}, _ctx} =
               Elaborate.elaborate_type(ctx, surface)
    end
  end

  # ============================================================================
  # Type checking — synth
  # ============================================================================

  describe "synth for :refine" do
    test "refinement type synthesizes as a Type" do
      ctx = Check.new()
      term = {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:ok, ^term, {:vtype, _level}, _ctx} = Check.synth(ctx, term)
    end
  end

  # ============================================================================
  # Type checking — check against refinement
  # ============================================================================

  describe "check against refinement type" do
    test "literal satisfying the predicate passes" do
      ctx = Check.new()
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:ok, {:lit, 5}, _ctx} = Check.check(ctx, {:lit, 5}, refine_type)
    end

    test "literal violating the predicate fails" do
      ctx = Check.new()
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:error, {:refinement_failed, _, _}} = Check.check(ctx, {:lit, -1}, refine_type)
    end

    test "literal zero fails x > 0" do
      ctx = Check.new()
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:error, {:refinement_failed, _, _}} = Check.check(ctx, {:lit, 0}, refine_type)
    end

    test "variable with refinement assumption passes" do
      # Bind n : {x : Int | x > 0}, then check n against {y : Int | y > 0}.
      ref_type = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      ctx =
        Check.new()
        |> extend(:n, ref_type, :omega)

      target_type = {:vrefine, {:vbuiltin, :Int}, :y, {:gt, {:var, :y}, {:lit, 0}}}

      assert {:ok, {:var, 0}, _ctx} = Check.check(ctx, {:var, 0}, target_type)
    end

    test "trivially true refinement always passes" do
      ctx = Check.new()
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, true}

      assert {:ok, {:lit, 42}, _ctx} = Check.check(ctx, {:lit, 42}, refine_type)
    end

    test "trivially false refinement always fails" do
      ctx = Check.new()
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, false}

      assert {:error, {:refinement_failed, _, _}} = Check.check(ctx, {:lit, 42}, refine_type)
    end

    test "non-zero check with literal" do
      ctx = Check.new()
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, {:neq, {:var, :x}, {:lit, 0}}}

      assert {:ok, {:lit, 5}, _ctx} = Check.check(ctx, {:lit, 5}, refine_type)
      assert {:error, {:refinement_failed, _, _}} = Check.check(ctx, {:lit, 0}, refine_type)
    end
  end

  # ============================================================================
  # Erasure
  # ============================================================================

  describe "erasure of refinement types" do
    test "refinement type erases to :erased in synth mode" do
      term = {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Haruspex.Erase.erase(term, {:type, {:llit, 0}})
      assert :erased = result
    end

    test "term checked against refinement type erases normally" do
      # A literal 5 with refinement type {x : Int | x > 0} erases to just {:lit, 5}.
      term = {:lit, 5}
      type = {:refine, {:builtin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Haruspex.Erase.erase(term, type)
      assert {:lit, 5} = result
    end
  end

  # ============================================================================
  # Pretty-printing
  # ============================================================================

  describe "pretty-printing refinement types" do
    test "pretty-prints vrefine value" do
      value = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      result = Haruspex.Pretty.pretty(value)
      assert result == "{x : Int | x > 0}"
    end

    test "pretty-prints core refine term" do
      term = {:refine, {:builtin, :Int}, :x, {:neq, {:var, :x}, {:lit, 0}}}
      result = Haruspex.Pretty.pretty_term(term)
      assert result == "{x : Int | x != 0}"
    end
  end

  # ============================================================================
  # Translate — additional coverage
  # ============================================================================

  describe "translate/2 — edge cases" do
    test "bare variable in predicate position produces :bound" do
      surface = {:var, span(), :x}
      assert {:bound, :x} = Predicate.translate(surface, :x)
    end

    test "non-boolean literal in predicate position produces true" do
      surface = {:lit, span(), 42}
      assert true == Predicate.translate(surface, :x)
    end
  end

  describe "translate_expr/2 — arithmetic ops" do
    test "translates subtraction" do
      surface = {:binop, span(), :sub, {:var, span(), :x}, {:lit, span(), 1}}
      assert {:op, :sub, [{:var, :x}, {:lit, 1}]} = Predicate.translate_expr(surface, :x)
    end

    test "translates multiplication" do
      surface = {:binop, span(), :mul, {:var, span(), :x}, {:lit, span(), 2}}
      assert {:op, :mul, [{:var, :x}, {:lit, 2}]} = Predicate.translate_expr(surface, :x)
    end

    test "translates division" do
      surface = {:binop, span(), :div, {:var, span(), :x}, {:lit, span(), 3}}
      assert {:op, :div, [{:var, :x}, {:lit, 3}]} = Predicate.translate_expr(surface, :x)
    end
  end

  # ============================================================================
  # Discharge — additional coverage
  # ============================================================================

  describe "discharge/2 — concrete evaluation" do
    test "concrete conjunction evaluates directly" do
      # 5 > 0 and 5 < 10 → both concrete and true.
      goal = {:and, {:gt, {:lit, 5}, {:lit, 0}}, {:lt, {:lit, 5}, {:lit, 10}}}
      assert :yes = Predicate.discharge([], goal)
    end

    test "concrete conjunction with one false" do
      goal = {:and, {:gt, {:lit, 5}, {:lit, 0}}, {:lt, {:lit, 5}, {:lit, 3}}}
      assert :no = Predicate.discharge([], goal)
    end

    test "concrete disjunction evaluates directly" do
      goal = {:or, {:gt, {:lit, 5}, {:lit, 10}}, {:lt, {:lit, 5}, {:lit, 10}}}
      assert :yes = Predicate.discharge([], goal)
    end

    test "concrete disjunction both false" do
      goal = {:or, {:gt, {:lit, 0}, {:lit, 10}}, {:lt, {:lit, 10}, {:lit, 5}}}
      assert :no = Predicate.discharge([], goal)
    end

    test "concrete negation evaluates directly" do
      goal = {:not, {:gt, {:lit, 0}, {:lit, 5}}}
      assert :yes = Predicate.discharge([], goal)
    end

    test "concrete negation of true predicate" do
      goal = {:not, {:gt, {:lit, 5}, {:lit, 0}}}
      assert :no = Predicate.discharge([], goal)
    end

    test "concrete lte comparison" do
      assert :yes = Predicate.discharge([], {:lte, {:lit, 3}, {:lit, 5}})
      assert :no = Predicate.discharge([], {:lte, {:lit, 5}, {:lit, 3}})
    end

    test "concrete gte comparison" do
      assert :yes = Predicate.discharge([], {:gte, {:lit, 5}, {:lit, 3}})
      assert :no = Predicate.discharge([], {:gte, {:lit, 3}, {:lit, 5}})
    end

    test "non-concrete predicate delegates to solver" do
      # Variable in predicate means not concrete — delegates to solver.
      goal = {:gt, {:var, :x}, {:lit, 0}}
      result = Predicate.discharge([], goal)
      assert result in [:no, {:unknown, "could not determine entailment"}]
    end

    test "solver returns :no for contradictory assumptions" do
      # Assume x > 5 and x < 3 (contradiction), goal is anything.
      assumptions = [{:gt, {:var, :x}, {:lit, 5}}, {:lt, {:var, :x}, {:lit, 3}}]
      goal = {:gt, {:var, :x}, {:lit, 0}}
      assert :yes = Predicate.discharge(assumptions, goal)
    end
  end

  # ============================================================================
  # Integration: checking against refinement with variable in scope
  # ============================================================================

  describe "integration — refinement propagation" do
    test "stronger refinement assumption discharges weaker goal" do
      # Bind n : {x : Int | x > 5}, then check n against {y : Int | y > 0}.
      strong_ref = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 5}}}

      ctx =
        Check.new()
        |> extend(:n, strong_ref, :omega)

      weak_ref = {:vrefine, {:vbuiltin, :Int}, :y, {:gt, {:var, :y}, {:lit, 0}}}

      assert {:ok, {:var, 0}, _ctx} = Check.check(ctx, {:var, 0}, weak_ref)
    end

    test "base type mismatch rejects even with valid predicate" do
      ctx = Check.new()
      # Try to check a float literal against {x : Int | x > 0}.
      refine_type = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:error, {:type_mismatch, _, _}} = Check.check(ctx, {:lit, 3.14}, refine_type)
    end
  end

  # ============================================================================
  # Unification of refinement types
  # ============================================================================

  describe "unification of refinement types" do
    test "identical refinement types unify" do
      ms = Haruspex.Unify.MetaState.new()
      v1 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      v2 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:ok, _ms} = Haruspex.Unify.unify(ms, 0, v1, v2)
    end

    test "refinement types with same pred but different var names unify" do
      ms = Haruspex.Unify.MetaState.new()
      v1 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      v2 = {:vrefine, {:vbuiltin, :Int}, :y, {:gt, {:var, :y}, {:lit, 0}}}

      assert {:ok, _ms} = Haruspex.Unify.unify(ms, 0, v1, v2)
    end

    test "refinement types with different predicates fail" do
      ms = Haruspex.Unify.MetaState.new()
      v1 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      v2 = {:vrefine, {:vbuiltin, :Int}, :x, {:lt, {:var, :x}, {:lit, 0}}}

      assert {:error, {:mismatch, _, _}} = Haruspex.Unify.unify(ms, 0, v1, v2)
    end

    test "refinement type unifies with base type (subtyping)" do
      ms = Haruspex.Unify.MetaState.new()
      v1 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}
      v2 = {:vbuiltin, :Int}

      assert {:ok, _ms} = Haruspex.Unify.unify(ms, 0, v1, v2)
    end

    test "base type unifies with refinement type (subtyping)" do
      ms = Haruspex.Unify.MetaState.new()
      v1 = {:vbuiltin, :Int}
      v2 = {:vrefine, {:vbuiltin, :Int}, :x, {:gt, {:var, :x}, {:lit, 0}}}

      assert {:ok, _ms} = Haruspex.Unify.unify(ms, 0, v1, v2)
    end
  end

  # ============================================================================
  # Integration tests from spec
  # ============================================================================

  describe "integration: safe_div" do
    test "y : {y : Int | y != 0} passes non-zero check" do
      ctx = Check.new()
      refined_int = {:vrefine, {:vbuiltin, :Int}, :y, {:neq, {:var, :y}, {:lit, 0}}}
      ctx = extend(ctx, :x, {:vbuiltin, :Int}, :omega)
      ctx = extend(ctx, :y, refined_int, :omega)

      # Checking y (var 0) against {z : Int | z != 0} should pass because
      # y already has the refinement in its type.
      refined_target = {:vrefine, {:vbuiltin, :Int}, :z, {:neq, {:var, :z}, {:lit, 0}}}
      {:ok, _term, _ctx} = Check.check(ctx, {:var, 0}, refined_target)
    end
  end

  describe "integration: positive integer" do
    test "literal 5 passes {n : Int | n > 0}" do
      ctx = Check.new()
      refined = {:vrefine, {:vbuiltin, :Int}, :n, {:gt, {:var, :n}, {:lit, 0}}}
      {:ok, _term, _ctx} = Check.check(ctx, {:lit, 5}, refined)
    end

    test "literal 0 fails {n : Int | n > 0}" do
      ctx = Check.new()
      refined = {:vrefine, {:vbuiltin, :Int}, :n, {:gt, {:var, :n}, {:lit, 0}}}
      assert {:error, {:refinement_failed, _, _}} = Check.check(ctx, {:lit, 0}, refined)
    end

    test "unconstrained variable fails {n : Int | n > 0}" do
      ctx = Check.new()
      ctx = extend(ctx, :x, {:vbuiltin, :Int}, :omega)
      refined = {:vrefine, {:vbuiltin, :Int}, :n, {:gt, {:var, :n}, {:lit, 0}}}
      assert {:error, {:refinement_failed, _, _}} = Check.check(ctx, {:var, 0}, refined)
    end
  end

  # ============================================================================
  # Full pipeline tests (parse → elaborate → check → codegen → eval)
  # ============================================================================

  describe "full pipeline" do
    test "positive integer function compiles and runs" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/refine_pos.hx", """
      def double_pos(n : {n : Int | n > 0}) : Int do
        n + n
      end
      """)

      {:ok, mod} = Roux.Runtime.query(db, :haruspex_compile, "lib/refine_pos.hx")
      assert mod.double_pos(5) == 10
      :code.purge(mod)
      :code.delete(mod)
    end

    test "non-zero divisor function compiles and runs" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/refine_div.hx", """
      def safe_div(x : Int, y : {y : Int | y != 0}) : Int do
        x / y
      end
      """)

      {:ok, mod} = Roux.Runtime.query(db, :haruspex_compile, "lib/refine_div.hx")
      assert mod.safe_div(10, 2) == 5
      :code.purge(mod)
      :code.delete(mod)
    end

    test "multiple refined parameters in same file" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/refine_multi.hx", """
      def double_pos(n : {n : Int | n > 0}) : Int do
        n + n
      end

      def safe_div(x : Int, y : {y : Int | y != 0}) : Int do
        x / y
      end
      """)

      {:ok, mod} = Roux.Runtime.query(db, :haruspex_compile, "lib/refine_multi.hx")
      assert mod.double_pos(3) == 6
      assert mod.safe_div(10, 5) == 2
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp extend(ctx, name, type, mult) do
    %{ctx | context: Context.extend(ctx.context, name, type, mult), names: ctx.names ++ [name]}
  end
end
