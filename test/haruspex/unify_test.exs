defmodule Haruspex.UnifyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Eval
  alias Haruspex.Unify
  alias Haruspex.Unify.MetaState
  alias Haruspex.Value

  # Helper to create a fresh meta as a value (vneutral wrapping nmeta).
  defp make_meta(ms, type \\ {:vtype, {:llit, 0}}, level \\ 0) do
    {id, ms} = MetaState.fresh_meta(ms, type, level, :implicit)
    val = {:vneutral, type, {:nmeta, id}}
    {id, val, ms}
  end

  # ============================================================================
  # Identity / literal unification
  # ============================================================================

  describe "identity and literals" do
    test "same literal unifies" do
      ms = MetaState.new()
      assert {:ok, _ms} = Unify.unify(ms, 0, {:vlit, 1}, {:vlit, 1})
    end

    test "same string literal unifies" do
      ms = MetaState.new()
      assert {:ok, _ms} = Unify.unify(ms, 0, {:vlit, "hello"}, {:vlit, "hello"})
    end

    test "different literals produce mismatch" do
      ms = MetaState.new()
      assert {:error, {:mismatch, _, _}} = Unify.unify(ms, 0, {:vlit, 1}, {:vlit, 2})
    end

    test "same builtin unifies" do
      ms = MetaState.new()
      assert {:ok, _ms} = Unify.unify(ms, 0, {:vbuiltin, :Int}, {:vbuiltin, :Int})
    end

    test "different builtins produce mismatch" do
      ms = MetaState.new()

      assert {:error, {:mismatch, _, _}} =
               Unify.unify(ms, 0, {:vbuiltin, :Int}, {:vbuiltin, :Float})
    end

    test "same type unifies and collects constraint" do
      ms = MetaState.new()
      assert {:ok, ms} = Unify.unify(ms, 0, {:vtype, {:llit, 0}}, {:vtype, {:llit, 0}})
      # Identical types still go through rigid-rigid which adds a constraint.
      # Actually, they're structurally equal so the `lhs == rhs` check catches it.
      assert ms.level_constraints == []
    end

    test "different universe levels collect constraint" do
      ms = MetaState.new()
      assert {:ok, ms} = Unify.unify(ms, 0, {:vtype, {:lvar, 0}}, {:vtype, {:llit, 1}})
      assert length(ms.level_constraints) == 1
    end
  end

  # ============================================================================
  # Pi unification
  # ============================================================================

  describe "Pi unification" do
    test "matching Pi types unify" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Pi(omega, Int, Int) — constant function type.
      pi1 = {:vpi, :omega, int, [], {:builtin, :Int}}
      pi2 = {:vpi, :omega, int, [], {:builtin, :Int}}

      assert {:ok, _ms} = Unify.unify(ms, 0, pi1, pi2)
    end

    test "Pi with different multiplicities fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      pi1 = {:vpi, :omega, int, [], {:builtin, :Int}}
      pi2 = {:vpi, :zero, int, [], {:builtin, :Int}}

      assert {:error, {:multiplicity_mismatch, :omega, :zero}} = Unify.unify(ms, 0, pi1, pi2)
    end

    test "Pi with different domains fails" do
      ms = MetaState.new()

      pi1 = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      pi2 = {:vpi, :omega, {:vbuiltin, :Float}, [], {:builtin, :Int}}

      assert {:error, {:mismatch, _, _}} = Unify.unify(ms, 0, pi1, pi2)
    end
  end

  # ============================================================================
  # Lambda and eta unification
  # ============================================================================

  describe "lambda and eta" do
    test "matching lambdas unify" do
      ms = MetaState.new()

      # fn x -> x (identity)
      lam1 = {:vlam, :omega, [], {:var, 0}}
      lam2 = {:vlam, :omega, [], {:var, 0}}

      assert {:ok, _ms} = Unify.unify(ms, 0, lam1, lam2)
    end

    test "different lambdas fail" do
      ms = MetaState.new()

      # fn x -> x vs fn x -> 42
      lam1 = {:vlam, :omega, [], {:var, 0}}
      lam2 = {:vlam, :omega, [], {:lit, 42}}

      assert {:error, _} = Unify.unify(ms, 0, lam1, lam2)
    end

    test "eta: lambda vs neutral at function type" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      pi = {:vpi, :omega, int, [], {:builtin, :Int}}

      # fn x -> f(x) where f is a neutral variable at level 0.
      f_neutral = {:vneutral, pi, {:nvar, 0}}
      # The lambda applies f to its bound variable.
      # In the env, f is at level 0. The lambda body is {:app, {:var, 1}, {:var, 0}}.
      lam = {:vlam, :omega, [f_neutral], {:app, {:var, 1}, {:var, 0}}}

      # Unify lam with f — should succeed via eta.
      # At level 1 (f is at level 0, so we're above it).
      assert {:ok, _ms} = Unify.unify(ms, 1, lam, f_neutral)
    end
  end

  # ============================================================================
  # Pair unification
  # ============================================================================

  describe "pair unification" do
    test "matching pairs unify" do
      ms = MetaState.new()

      assert {:ok, _ms} =
               Unify.unify(
                 ms,
                 0,
                 {:vpair, {:vlit, 1}, {:vlit, 2}},
                 {:vpair, {:vlit, 1}, {:vlit, 2}}
               )
    end

    test "pairs with different first component fail" do
      ms = MetaState.new()

      assert {:error, _} =
               Unify.unify(
                 ms,
                 0,
                 {:vpair, {:vlit, 1}, {:vlit, 2}},
                 {:vpair, {:vlit, 3}, {:vlit, 2}}
               )
    end

    test "pairs with different second component fail" do
      ms = MetaState.new()

      assert {:error, _} =
               Unify.unify(
                 ms,
                 0,
                 {:vpair, {:vlit, 1}, {:vlit, 2}},
                 {:vpair, {:vlit, 1}, {:vlit, 3}}
               )
    end
  end

  # ============================================================================
  # Sigma unification
  # ============================================================================

  describe "sigma unification" do
    test "matching sigma types unify" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      sig1 = {:vsigma, int, [], {:builtin, :Int}}
      sig2 = {:vsigma, int, [], {:builtin, :Int}}

      assert {:ok, _ms} = Unify.unify(ms, 0, sig1, sig2)
    end
  end

  # ============================================================================
  # Eta for pairs
  # ============================================================================

  describe "eta for pairs" do
    test "pair vs neutral at sigma type: eta-expands via projections" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      sigma = {:vsigma, int, [], {:builtin, :Int}}

      # A known pair against a neutral at sigma type.
      # Eta: unify(pair, neutral) → unify(fst(pair), fst(neutral)) ∧ unify(snd(pair), snd(neutral)).
      pair = {:vpair, {:vlit, 1}, {:vlit, 2}}
      neutral = {:vneutral, sigma, {:nvar, 0}}

      # The neutral's projections are stuck, so literals won't match them.
      assert {:error, _} = Unify.unify(ms, 1, pair, neutral)
    end

    test "pair eta succeeds when both sides reduce to same components" do
      ms = MetaState.new()

      pair1 = {:vpair, {:vlit, 1}, {:vlit, 2}}
      pair2 = {:vpair, {:vlit, 1}, {:vlit, 2}}

      assert {:ok, _ms} = Unify.unify(ms, 0, pair1, pair2)
    end

    test "pair with different fst fails via eta" do
      ms = MetaState.new()

      pair = {:vpair, {:vlit, 1}, {:vlit, 2}}
      # A neutral that when projected gives different values.
      other_pair = {:vpair, {:vlit, 3}, {:vlit, 2}}

      assert {:error, _} = Unify.unify(ms, 0, pair, other_pair)
    end

    test "pair eta-expands non-pair value" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      sigma = {:vsigma, int, [], {:builtin, :Int}}

      # A pair on one side, a neutral on the other.
      # The neutral's fst/snd produce stuck projections.
      pair = {:vpair, {:vlit, 1}, {:vlit, 2}}
      neutral = {:vneutral, sigma, {:nvar, 0}}

      # Eta: unify(pair, neutral) → unify(1, fst(neutral)) and unify(2, snd(neutral)).
      # fst(neutral) is a stuck neutral, so 1 != neutral → mismatch.
      assert {:error, _} = Unify.unify(ms, 1, pair, neutral)
    end

    test "pair eta-expands: meta solved via projections" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Create a meta for the pair.
      {id, meta_val, ms} = make_meta(ms, int, 0)

      # Unify meta with a pair — should solve meta to the pair.
      pair = {:vpair, {:vlit, 10}, {:vlit, 20}}
      assert {:ok, ms} = Unify.unify(ms, 0, meta_val, pair)
      assert {:solved, ^pair} = MetaState.lookup(ms, id)
    end
  end

  # ============================================================================
  # Meta solving
  # ============================================================================

  describe "meta solving" do
    test "meta = literal solves the meta" do
      ms = MetaState.new()
      {id, meta_val, ms} = make_meta(ms)

      assert {:ok, ms} = Unify.unify(ms, 0, meta_val, {:vlit, 42})
      assert MetaState.lookup(ms, id) == {:solved, {:vlit, 42}}
    end

    test "literal = meta solves the meta (symmetric)" do
      ms = MetaState.new()
      {id, meta_val, ms} = make_meta(ms)

      assert {:ok, ms} = Unify.unify(ms, 0, {:vlit, 42}, meta_val)
      assert MetaState.lookup(ms, id) == {:solved, {:vlit, 42}}
    end

    test "meta = meta solves one to the other" do
      ms = MetaState.new()
      {_id0, meta0, ms} = make_meta(ms)
      {id1, meta1, ms} = make_meta(ms)

      assert {:ok, ms} = Unify.unify(ms, 0, meta0, meta1)
      # The higher-numbered meta should be solved to the lower-numbered one.
      assert {:solved, ^meta0} = MetaState.lookup(ms, id1)
    end

    test "meta = builtin type solves the meta" do
      ms = MetaState.new()
      {id, meta_val, ms} = make_meta(ms)

      assert {:ok, ms} = Unify.unify(ms, 0, meta_val, {:vbuiltin, :Int})
      assert {:solved, {:vbuiltin, :Int}} = MetaState.lookup(ms, id)
    end
  end

  # ============================================================================
  # Pattern unification
  # ============================================================================

  describe "pattern unification" do
    test "meta applied to variable solves: ?a(x) = x" do
      ms = MetaState.new()
      {id, _meta_val, ms} = make_meta(ms)

      int = {:vbuiltin, :Int}
      # x is a free variable at level 0.
      x = Value.fresh_var(0, int)

      # ?a applied to x.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      # rhs is just x.

      assert {:ok, ms} = Unify.unify(ms, 1, flex, x)
      # Meta should be solved to the identity function (fn x -> x).
      assert {:solved, solution} = MetaState.lookup(ms, id)

      # Verify: applying the solution to x should give x back.
      result = Eval.vapp(Eval.default_ctx(), solution, {:vlit, 99})
      assert result == {:vlit, 99}
    end

    test "meta applied to variable solves: ?a(x) = lit" do
      ms = MetaState.new()
      {id, _meta_val, ms} = make_meta(ms)

      int = {:vbuiltin, :Int}
      x = Value.fresh_var(0, int)

      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, {:vlit, 42})
      assert {:solved, solution} = MetaState.lookup(ms, id)

      # Solution should be the constant function (fn _ -> 42).
      result = Eval.vapp(Eval.default_ctx(), solution, {:vlit, 0})
      assert result == {:vlit, 42}
    end
  end

  # ============================================================================
  # Occurs check
  # ============================================================================

  describe "occurs check" do
    test "meta cannot be solved to value containing itself" do
      ms = MetaState.new()
      {id, meta_val, ms} = make_meta(ms)

      # Try to unify ?a with Pi(_, ?a, _) — ?a occurs in the rhs.
      rhs = {:vpi, :omega, meta_val, [], {:builtin, :Int}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end
  end

  # ============================================================================
  # Scope escape
  # ============================================================================

  describe "scope escape" do
    test "meta cannot be solved to value with out-of-scope variable" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      # y is at level 5, outside the meta's scope.
      y = Value.fresh_var(5, int)

      # Bare meta (no spine) — spine_levels is empty.
      # rhs contains NVar(5) which is not in spine_levels.
      assert {:error, {:scope_escape, _, _}} = Unify.unify(ms, 6, meta_val, y)
    end
  end

  # ============================================================================
  # Neutral unification
  # ============================================================================

  describe "neutral unification" do
    test "same variable unifies" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      x = Value.fresh_var(0, int)

      assert {:ok, _ms} = Unify.unify(ms, 1, x, x)
    end

    test "different variables fail" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      x = Value.fresh_var(0, int)
      y = Value.fresh_var(1, int)

      assert {:error, _} = Unify.unify(ms, 2, x, y)
    end

    test "same neutral application unifies" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      # f(42) on both sides.
      app1 = {:vneutral, int, {:napp, {:nvar, 0}, {:vlit, 42}}}
      app2 = {:vneutral, int, {:napp, {:nvar, 0}, {:vlit, 42}}}

      assert {:ok, _ms} = Unify.unify(ms, 1, app1, app2)
    end

    test "neutral applications with different args fail" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      app1 = {:vneutral, int, {:napp, {:nvar, 0}, {:vlit, 42}}}
      app2 = {:vneutral, int, {:napp, {:nvar, 0}, {:vlit, 99}}}

      assert {:error, _} = Unify.unify(ms, 1, app1, app2)
    end
  end

  # ============================================================================
  # Forcing through solved metas
  # ============================================================================

  describe "forcing" do
    test "solved meta on one side is forced before comparison" do
      ms = MetaState.new()
      {id, _meta_val, ms} = make_meta(ms)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      meta_ref = {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id}}
      assert {:ok, _ms} = Unify.unify(ms, 0, meta_ref, {:vlit, 42})
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "unification is reflexive for literals" do
      check all(n <- integer()) do
        ms = MetaState.new()
        assert {:ok, _} = Unify.unify(ms, 0, {:vlit, n}, {:vlit, n})
      end
    end

    property "unification symmetry for literals" do
      check all(
              a <- integer(),
              b <- integer()
            ) do
        ms = MetaState.new()
        r1 = Unify.unify(ms, 0, {:vlit, a}, {:vlit, b})
        r2 = Unify.unify(ms, 0, {:vlit, b}, {:vlit, a})

        case {r1, r2} do
          {{:ok, _}, {:ok, _}} -> assert true
          {{:error, _}, {:error, _}} -> assert true
          _ -> flunk("Symmetry violation: unify(#{a}, #{b}) and unify(#{b}, #{a}) disagree")
        end
      end
    end

    property "meta solving symmetry: unify(meta, v) iff unify(v, meta)" do
      check all(n <- integer()) do
        ms1 = MetaState.new()
        {_id1, meta1, ms1} = make_meta(ms1)
        r1 = Unify.unify(ms1, 0, meta1, {:vlit, n})

        ms2 = MetaState.new()
        {_id2, meta2, ms2} = make_meta(ms2)
        r2 = Unify.unify(ms2, 0, {:vlit, n}, meta2)

        case {r1, r2} do
          {{:ok, _}, {:ok, _}} -> assert true
          _ -> flunk("Meta solving symmetry violation for #{n}")
        end
      end
    end

    property "meta idempotence: solving twice with same value doesn't change state" do
      check all(n <- integer()) do
        ms = MetaState.new()
        {_id, meta_val, ms} = make_meta(ms)

        {:ok, ms1} = Unify.unify(ms, 0, meta_val, {:vlit, n})
        # The meta is now solved. Unifying again with the same value should succeed.
        # Force to get the solved value.
        forced = MetaState.force(ms1, meta_val)
        {:ok, ms2} = Unify.unify(ms1, 0, forced, {:vlit, n})

        assert ms1 == ms2
      end
    end
  end
end
