defmodule Haruspex.ReductionGateTest do
  use ExUnit.Case, async: true

  alias Haruspex.Eval
  alias Haruspex.Quote

  # ============================================================================
  # Unit tests: evaluator unfolds total definitions
  # ============================================================================

  describe "evaluator unfolding" do
    test "@total add(succ(succ(zero)), succ(zero)) reduces to succ(succ(succ(zero)))" do
      # add body: lam(n, lam(m, case n of zero -> m; succ(k) -> succ(add(k, m))))
      # As a core term using {:def_ref, :add} for self-reference:
      add_body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1,
              {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      ctx = %{env: [], metas: %{}, defs: %{add: {add_body, true}}, fuel: 100}

      # Build: add(succ(succ(zero)), succ(zero))
      two = {:con, :Nat, :succ, [{:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}]}
      one = {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}
      term = {:app, {:app, {:def_ref, :add}, two}, one}

      result = Eval.eval(ctx, term)

      # Should reduce to succ(succ(succ(zero))) = 3
      three =
        {:vcon, :Nat, :succ,
         [{:vcon, :Nat, :succ, [{:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]}]}]}

      assert result == three
    end

    test "non-total definition does NOT reduce — remains stuck" do
      fib_body = {:lam, :omega, {:lit, 0}}

      ctx = %{env: [], metas: %{}, defs: %{fib: {fib_body, false}}, fuel: 100}

      term = {:app, {:def_ref, :fib}, {:lit, 3}}
      result = Eval.eval(ctx, term)

      # Should be a stuck neutral application on the def_ref.
      assert {:vneutral, _, {:napp, {:ndef_ref, :fib}, {:vlit, 3}}} = result
    end

    test "fuel exhaustion produces stuck neutral" do
      # Self-recursive body that consumes fuel quickly.
      add_body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1,
              {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      # Set fuel to 0 — no unfolding allowed.
      ctx = %{env: [], metas: %{}, defs: %{add: {add_body, true}}, fuel: 0}

      term = {:def_ref, :add}
      result = Eval.eval(ctx, term)

      # Fuel exhausted — stuck neutral.
      assert {:vneutral, _, {:ndef_ref, :add}} = result
    end

    test "unknown definition produces stuck neutral" do
      ctx = %{env: [], metas: %{}, defs: %{}, fuel: 100}

      term = {:def_ref, :nonexistent}
      result = Eval.eval(ctx, term)

      assert {:vneutral, _, {:ndef_ref, :nonexistent}} = result
    end
  end

  # ============================================================================
  # Quote round-trip
  # ============================================================================

  describe "quote round-trip" do
    test "stuck def_ref quotes back to {:def_ref, name}" do
      val = {:vneutral, {:vtype, {:llit, 0}}, {:ndef_ref, :mystery}}
      quoted = Quote.quote_untyped(0, val)
      assert {:def_ref, :mystery} = quoted
    end

    test "stuck def_ref application quotes correctly" do
      val = {:vneutral, {:vtype, {:llit, 0}}, {:napp, {:ndef_ref, :f}, {:vlit, 42}}}
      quoted = Quote.quote_untyped(0, val)
      assert {:app, {:def_ref, :f}, {:lit, 42}} = quoted
    end
  end

  # ============================================================================
  # Type-level reduction: total definitions reduce in types
  # ============================================================================

  describe "type-level reduction" do
    test "total definition reduces in type during unification" do
      # If add(succ(succ(zero)), succ(zero)) reduces to succ(succ(succ(zero))),
      # then unifying the two should succeed.
      add_body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1,
              {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      ctx = %{env: [], metas: %{}, defs: %{add: {add_body, true}}, fuel: 100}

      # Evaluate add(2, 1) — should reduce to 3
      two = {:con, :Nat, :succ, [{:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}]}
      one = {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}
      result = Eval.eval(ctx, {:app, {:app, {:def_ref, :add}, two}, one})

      # Evaluate the literal 3
      three_core =
        {:con, :Nat, :succ,
         [{:con, :Nat, :succ, [{:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}]}]}

      three = Eval.eval(ctx, three_core)

      # They should be equal.
      assert result == three
    end

    test "non-total definition stays opaque — trivially equal to itself" do
      ctx = %{
        env: [],
        metas: %{},
        defs: %{mystery: {{:lam, :omega, {:var, 0}}, false}},
        fuel: 100
      }

      val1 = Eval.eval(ctx, {:app, {:def_ref, :mystery}, {:lit, 1}})
      val2 = Eval.eval(ctx, {:app, {:def_ref, :mystery}, {:lit, 1}})

      # Both are the same stuck neutral — should unify.
      ms = Haruspex.Unify.MetaState.new()
      assert {:ok, _ms} = Haruspex.Unify.unify(ms, 0, val1, val2)
    end

    test "non-total definition does NOT equal a different value" do
      ctx = %{
        env: [],
        metas: %{},
        defs: %{mystery: {{:lam, :omega, {:var, 0}}, false}},
        fuel: 100
      }

      val1 = Eval.eval(ctx, {:app, {:def_ref, :mystery}, {:lit, 1}})
      val2 = {:vlit, 2}

      # Opaque neutral ≠ literal — should fail.
      ms = Haruspex.Unify.MetaState.new()
      assert {:error, _} = Haruspex.Unify.unify(ms, 0, val1, val2)
    end
  end

  # ============================================================================
  # Core term operations
  # ============================================================================

  describe "core term operations" do
    test "subst passes through def_ref" do
      term = {:app, {:def_ref, :add}, {:var, 0}}
      result = Haruspex.Core.subst(term, 0, {:lit, 42})
      assert {:app, {:def_ref, :add}, {:lit, 42}} = result
    end

    test "shift passes through def_ref" do
      term = {:app, {:def_ref, :add}, {:var, 0}}
      result = Haruspex.Core.shift(term, 1, 0)
      assert {:app, {:def_ref, :add}, {:var, 1}} = result
    end
  end

  # ============================================================================
  # Pipeline integration: total defs populated in checker
  # ============================================================================

  describe "pipeline: total defs in checker" do
    test "@total definition body is available in eval context" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/test.hx", """
      type Nat = zero | succ(Nat)

      @total
      def add(n : Nat, m : Nat) : Nat do
        case n do
          zero -> m
          succ(k) -> succ(add(k, m))
        end
      end

      def identity(x : Int) : Int do x end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")

      # Check identity (which triggers collect_total_defs).
      {:ok, {_type, _body}} =
        Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :identity})

      # Check add too.
      {:ok, {_type, _body}} =
        Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :add})
    end
  end

  # ============================================================================
  # Pipeline integration: def_ref in types
  # ============================================================================

  describe "pipeline: def_ref in types" do
    test "same-file definition reference resolves in type annotation" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/test.hx", """
      type Nat = zero | succ(Nat)

      @total
      def add(n : Nat, m : Nat) : Nat do
        case n do
          zero -> m
          succ(k) -> succ(add(k, m))
        end
      end

      def use_add(x : Nat) : Nat do
        add(x, zero)
      end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      # use_add references add (a same-file def) — should elaborate and check.
      {:ok, {_type, _body}} =
        Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :use_add})
    end

    test "non-total same-file def reference stays opaque in types" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/test.hx", """
      type Nat = zero | succ(Nat)

      def mystery(n : Nat) : Nat do n end

      def use_mystery(x : Nat) : Nat do
        mystery(x)
      end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      # mystery is not @total — stays opaque, but the function still checks fine.
      {:ok, {_type, _body}} =
        Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :use_mystery})
    end
  end

  # ============================================================================
  # @fuel annotation
  # ============================================================================

  describe "@fuel annotation" do
    test "parses @fuel N before def" do
      {:ok, [form]} = Haruspex.Parser.parse("@fuel 5000\ndef f(x : Int) : Int do x end")
      {:def, _, {:sig, _, :f, _, _, _, attrs}, _} = form
      assert attrs.fuel == 5000
    end

    test "parses @total @fuel combination" do
      {:ok, [form]} =
        Haruspex.Parser.parse("@total\n@fuel 100\ndef f(x : Int) : Int do x end")

      {:def, _, {:sig, _, :f, _, _, _, attrs}, _} = form
      assert attrs.total == true
      assert attrs.fuel == 100
    end

    test "fuel stored on Definition entity" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/test.hx", """
      @fuel 500
      def f(x : Int) : Int do x end
      """)

      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      assert 500 == Roux.Runtime.field(db, Haruspex.Definition, entity_id, :fuel)
    end

    test "no @fuel defaults to nil" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/test.hx", "def f(x : Int) : Int do x end")
      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      assert nil == Roux.Runtime.field(db, Haruspex.Definition, entity_id, :fuel)
    end
  end
end
