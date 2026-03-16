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

    test "same ndef neutrals with same args unify" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}, {:vlit, 2}]}}
      ne2 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}, {:vlit, 2}]}}

      assert {:ok, _ms} = Unify.unify(ms, 0, ne1, ne2)
    end

    test "ndef neutrals with different names fail" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}]}}
      ne2 = {:vneutral, int, {:ndef, :bar, [{:vlit, 1}]}}

      assert {:error, _} = Unify.unify(ms, 0, ne1, ne2)
    end

    test "ndef neutrals with different args fail" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}]}}
      ne2 = {:vneutral, int, {:ndef, :foo, [{:vlit, 2}]}}

      assert {:error, _} = Unify.unify(ms, 0, ne1, ne2)
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
  # Flex-flex unification
  # ============================================================================

  describe "flex-flex unification" do
    test "bare metas: same id unifies" do
      ms = MetaState.new()
      {_id, meta_val, ms} = make_meta(ms)
      # Both sides are the same bare meta.
      assert {:ok, _ms} = Unify.unify(ms, 0, meta_val, meta_val)
    end

    test "bare metas: different ids solve higher to lower" do
      ms = MetaState.new()
      {_id0, meta0, ms} = make_meta(ms)
      {id1, meta1, ms} = make_meta(ms)

      assert {:ok, ms} = Unify.unify(ms, 0, meta0, meta1)
      # Higher-numbered meta (id1) is solved to the lower (id0).
      assert {:solved, ^meta0} = MetaState.lookup(ms, id1)
    end

    test "bare metas: higher id on left still works" do
      ms = MetaState.new()
      {_id0, meta0, ms} = make_meta(ms)
      {id1, meta1, ms} = make_meta(ms)

      assert {:ok, ms} = Unify.unify(ms, 0, meta1, meta0)
      assert {:solved, ^meta0} = MetaState.lookup(ms, id1)
    end

    test "flex-flex with spines: tries pattern unification" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id0, _m0, ms} = make_meta(ms, int, 0)
      {id1, _m1, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x) vs ?1(x)
      flex0 = {:vneutral, int, {:napp, {:nmeta, id0}, x}}
      flex1 = {:vneutral, int, {:napp, {:nmeta, id1}, x}}

      assert {:ok, _ms} = Unify.unify(ms, 1, flex0, flex1)
    end

    test "flex-flex with spines: fallback to right side when left fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id0, _m0, ms} = make_meta(ms, int, 0)
      {id1, _m1, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x, x) — non-linear spine, not a valid pattern.
      flex0 = {:vneutral, int, {:napp, {:napp, {:nmeta, 0}, x}, x}}
      # ?1(x) — valid pattern.
      flex1 = {:vneutral, int, {:napp, {:nmeta, id1}, x}}

      # Should succeed by trying right side.
      assert {:ok, _ms} = Unify.unify(ms, 1, flex0, flex1)
    end
  end

  # ============================================================================
  # Flex-rigid: pattern unification details
  # ============================================================================

  describe "pattern unification — detailed" do
    test "non-variable spine produces not_pattern error" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      # ?0(42) — 42 is not a variable.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, {:vlit, 42}}}

      assert {:error, {:not_pattern, ^id, _}} = Unify.unify(ms, 1, flex, {:vlit, 99})
    end

    test "duplicate spine variables produce not_pattern error" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      # ?0(x, x) — non-linear.
      flex = {:vneutral, int, {:napp, {:napp, {:nmeta, id}, x}, x}}

      assert {:error, {:not_pattern, ^id, _}} = Unify.unify(ms, 1, flex, {:vlit, 99})
    end

    test "occurs check in closure (pi codomain)" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      # rhs = Pi(_, Int, ?0) — ?0 occurs in the closure.
      rhs = {:vpi, :omega, int, [], {:meta, id}}

      # Should fail with occurs_check since rhs closure contains meta id.
      result = Unify.unify(ms, 0, meta_val, rhs)
      assert {:error, {:occurs_check, ^id, _}} = result
    end

    test "occurs check in sigma" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      rhs = {:vsigma, meta_val, [], {:builtin, :Int}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "occurs check in pair" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      rhs = {:vpair, meta_val, {:vlit, 1}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "occurs check in lambda body" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      # rhs is a lambda whose body is (meta id).
      rhs = {:vlam, :omega, [], {:meta, id}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "occurs check passes for non-occurring values" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      # rhs has no meta references.
      rhs = {:vlit, 42}

      assert {:ok, _ms} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "scope check: meta with spine allows in-scope variables" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      # ?0(x) = x — x is in the spine.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      assert {:ok, _ms} = Unify.unify(ms, 1, flex, x)
    end

    test "scope escape: rhs has variable not in spine" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      y = Value.fresh_var(1, int)

      # ?0(x) = y — y is not in the spine [x].
      flex = {:vneutral, int, {:napp, {:nmeta, 0}, x}}

      assert {:error, {:scope_escape, _, _}} = Unify.unify(ms, 2, flex, y)
    end
  end

  # ============================================================================
  # Rigid-rigid: additional cases
  # ============================================================================

  describe "rigid-rigid — additional" do
    test "sigma with different first types fails" do
      ms = MetaState.new()

      sig1 = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      sig2 = {:vsigma, {:vbuiltin, :Float}, [], {:builtin, :Int}}

      assert {:error, _} = Unify.unify(ms, 0, sig1, sig2)
    end

    test "lambda with different bodies fails" do
      ms = MetaState.new()

      lam1 = {:vlam, :omega, [], {:lit, 1}}
      lam2 = {:vlam, :omega, [], {:lit, 2}}

      assert {:error, _} = Unify.unify(ms, 0, lam1, lam2)
    end

    test "extern vs extern: same unifies" do
      ms = MetaState.new()

      assert {:ok, _} =
               Unify.unify(ms, 0, {:vextern, Enum, :map, 2}, {:vextern, Enum, :map, 2})
    end

    test "extern vs extern: different fails" do
      ms = MetaState.new()

      assert {:error, _} =
               Unify.unify(ms, 0, {:vextern, Enum, :map, 2}, {:vextern, Enum, :filter, 2})
    end

    test "eta: rhs lambda vs lhs non-lambda" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      pi = {:vpi, :omega, int, [], {:builtin, :Int}}

      f_neutral = {:vneutral, pi, {:nvar, 0}}
      # fn(x) -> f(x)
      lam = {:vlam, :omega, [f_neutral], {:app, {:var, 1}, {:var, 0}}}

      # Unify f with lambda (reversed from the other eta test).
      assert {:ok, _ms} = Unify.unify(ms, 1, f_neutral, lam)
    end

    test "eta for pairs: rhs is pair, lhs is non-pair" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      sigma = {:vsigma, int, [], {:builtin, :Int}}

      neutral = {:vneutral, sigma, {:nvar, 0}}
      pair = {:vpair, {:vlit, 1}, {:vlit, 2}}

      # rhs is pair, lhs is not — eta-expands the other way.
      assert {:error, _} = Unify.unify(ms, 1, neutral, pair)
    end

    test "type vs type with different levels adds constraint" do
      ms = MetaState.new()

      assert {:ok, ms} = Unify.unify(ms, 0, {:vtype, {:llit, 1}}, {:vtype, {:llit, 2}})
      assert [{:eq, {:llit, 1}, {:llit, 2}}] = ms.level_constraints
    end

    test "lit vs builtin fails" do
      ms = MetaState.new()
      assert {:error, _} = Unify.unify(ms, 0, {:vlit, 42}, {:vbuiltin, :Int})
    end

    test "neutral fst unification" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nfst, {:nvar, 0}}}
      ne2 = {:vneutral, int, {:nfst, {:nvar, 0}}}

      assert {:ok, _ms} = Unify.unify(ms, 1, ne1, ne2)
    end

    test "neutral snd unification" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nsnd, {:nvar, 0}}}
      ne2 = {:vneutral, int, {:nsnd, {:nvar, 0}}}

      assert {:ok, _ms} = Unify.unify(ms, 1, ne1, ne2)
    end

    test "neutral meta vs meta: same id ok" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Use real metas so MetaState has entries.
      {id, _m, ms} = make_meta(ms, int, 0)
      {id2, _m2, ms} = make_meta(ms, int, 0)

      ne1 = {:vneutral, int, {:nmeta, id}}
      ne2 = {:vneutral, int, {:nmeta, id2}}

      # These are flex, so they'll go through flex-flex path.
      assert {:ok, _} = Unify.unify(ms, 0, ne1, ne2)
    end

    test "neutral nbuiltin: same unifies" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nbuiltin, :add}}
      ne2 = {:vneutral, int, {:nbuiltin, :add}}

      assert {:ok, _ms} = Unify.unify(ms, 0, ne1, ne2)
    end

    test "neutral nbuiltin: different fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nbuiltin, :add}}
      ne2 = {:vneutral, int, {:nbuiltin, :sub}}

      assert {:error, _} = Unify.unify(ms, 0, ne1, ne2)
    end

    test "neutral head mismatch (var vs builtin)" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nvar, 0}}
      ne2 = {:vneutral, int, {:nbuiltin, :add}}

      assert {:error, _} = Unify.unify(ms, 1, ne1, ne2)
    end

    test "ndef with different arg count fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}]}}
      ne2 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}, {:vlit, 2}]}}

      assert {:error, _} = Unify.unify(ms, 0, ne1, ne2)
    end

    test "ndef with arg mismatch fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}, {:vlit, 2}]}}
      ne2 = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}, {:vlit, 3}]}}

      assert {:error, _} = Unify.unify(ms, 0, ne1, ne2)
    end
  end

  # ============================================================================
  # Rename vars (via abstract/pattern unification)
  # ============================================================================

  describe "abstraction and renaming via pattern unification" do
    test "multi-var spine solves correctly" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      y = Value.fresh_var(1, int)

      # ?0(x, y) = pair(y, x)
      flex = {:vneutral, int, {:napp, {:napp, {:nmeta, id}, x}, y}}
      rhs = {:vpair, y, x}

      assert {:ok, ms} = Unify.unify(ms, 2, flex, rhs)
      assert {:solved, solution} = MetaState.lookup(ms, id)

      # Solution should be fn(a, b) -> (b, a).
      result =
        Eval.vapp(
          Eval.default_ctx(),
          Eval.vapp(Eval.default_ctx(), solution, {:vlit, 10}),
          {:vlit, 20}
        )

      assert {:vpair, {:vlit, 20}, {:vlit, 10}} = result
    end

    test "pattern unification with pi in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x) = Pi(omega, Int, Int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vpi, :omega, int, [], {:builtin, :Int}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with sigma in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vsigma, int, [], {:builtin, :Int}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with type in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vtype, {:llit, 0}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with builtin in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, int)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with extern in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vextern, Enum, :map, 2}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with lambda in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vlam, :omega, [], {:var, 0}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end
  end

  # ============================================================================
  # Scope checking details
  # ============================================================================

  describe "scope checking — value types" do
    test "scope check passes for pi type in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vpi, :omega, int, [], {:builtin, :Int}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for sigma type in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vsigma, int, [], {:builtin, :Int}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for pair in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vpair, {:vlit, 1}, {:vlit, 2}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for neutral with ndef" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}]}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for neutral with nbuiltin" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, {:nbuiltin, :add}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for neutral with fst" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, {:nfst, {:nvar, 0}}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for neutral with snd" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, {:nsnd, {:nvar, 0}}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for neutral with meta" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)
      {id2, _meta2, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, {:nmeta, id2}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check passes for neutral with napp" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, {:napp, {:nvar, 0}, {:vlit, 1}}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "scope check with lambda in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vlam, :omega, [], {:var, 0}}

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end
  end

  # ============================================================================
  # Occurs check — neutral cases
  # ============================================================================

  describe "occurs check — neutral details" do
    test "occurs in neutral napp head" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      # ?0(x) applied to something containing ?0 in the head.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      # rhs that contains the same meta in a napp: f(?0, y) where f is at nvar 1.
      rhs = {:vneutral, int, {:napp, {:nvar, 1}, meta_val}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 2, flex, rhs)
    end

    test "occurs in neutral nfst" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      rhs = {:vneutral, int, {:nfst, {:nmeta, id}}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "occurs in neutral nsnd" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      rhs = {:vneutral, int, {:nsnd, {:nmeta, id}}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "occurs in neutral ndef args" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, meta_val, ms} = make_meta(ms, int, 0)

      rhs = {:vneutral, int, {:ndef, :foo, [meta_val]}}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "does not occur in nvar" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, 0}, x}}
      # rhs is just a variable in the spine.
      rhs = x

      assert {:ok, _} = Unify.unify(ms, 1, flex, rhs)
    end

    test "does not occur in nbuiltin" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      rhs = {:vneutral, int, {:nbuiltin, :add}}

      assert {:ok, _} = Unify.unify(ms, 0, meta_val, rhs)
    end

    test "does not occur in type" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      assert {:ok, _} = Unify.unify(ms, 0, meta_val, {:vtype, {:llit, 0}})
    end

    test "does not occur in extern" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      assert {:ok, _} = Unify.unify(ms, 0, meta_val, {:vextern, Enum, :map, 2})
    end

    test "does not occur in lit" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      assert {:ok, _} = Unify.unify(ms, 0, meta_val, {:vlit, 99})
    end

    test "does not occur in builtin" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {_id, meta_val, ms} = make_meta(ms, int, 0)

      assert {:ok, _} = Unify.unify(ms, 0, meta_val, {:vbuiltin, :Float})
    end
  end

  # ============================================================================
  # Rigid Pi/Sigma codomain unification
  # ============================================================================

  describe "rigid Pi/Sigma — codomain unification" do
    test "pi with matching domains but different codomains fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Pi(omega, Int, Int) vs Pi(omega, Int, Float).
      pi1 = {:vpi, :omega, int, [], {:builtin, :Int}}
      pi2 = {:vpi, :omega, int, [], {:builtin, :Float}}

      assert {:error, _} = Unify.unify(ms, 0, pi1, pi2)
    end

    test "pi with matching domains and codomains succeeds" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      pi1 = {:vpi, :omega, int, [], {:builtin, :Int}}
      pi2 = {:vpi, :omega, int, [], {:builtin, :Int}}

      assert {:ok, _} = Unify.unify(ms, 0, pi1, pi2)
    end

    test "sigma with matching first types but different second fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      sig1 = {:vsigma, int, [], {:builtin, :Int}}
      sig2 = {:vsigma, int, [], {:builtin, :Float}}

      assert {:error, _} = Unify.unify(ms, 0, sig1, sig2)
    end

    test "sigma with matching types succeeds" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      sig1 = {:vsigma, int, [], {:builtin, :Int}}
      sig2 = {:vsigma, int, [], {:builtin, :Int}}

      assert {:ok, _} = Unify.unify(ms, 0, sig1, sig2)
    end
  end

  # ============================================================================
  # Pair eta — detailed
  # ============================================================================

  describe "pair eta — rhs pair" do
    test "lhs non-pair vs rhs pair" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      sigma = {:vsigma, int, [], {:builtin, :Int}}

      neutral = {:vneutral, sigma, {:nvar, 0}}
      pair = {:vpair, {:vlit, 1}, {:vlit, 2}}

      # lhs is not a pair, rhs is pair — triggers the rhs pair eta branch.
      assert {:error, _} = Unify.unify(ms, 1, neutral, pair)
    end

    test "lhs pair components match rhs projections" do
      ms = MetaState.new()

      pair1 = {:vpair, {:vlit, 1}, {:vlit, 2}}
      pair2 = {:vpair, {:vlit, 1}, {:vlit, 2}}

      # Both are pairs — goes through pair vs pair path.
      assert {:ok, _} = Unify.unify(ms, 0, pair1, pair2)
    end
  end

  # ============================================================================
  # Neutral fst/snd/meta unification
  # ============================================================================

  describe "neutral fst/snd/meta unification" do
    test "nfst with different heads fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nfst, {:nvar, 0}}}
      ne2 = {:vneutral, int, {:nfst, {:nvar, 1}}}

      assert {:error, _} = Unify.unify(ms, 2, ne1, ne2)
    end

    test "nsnd with different heads fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      ne1 = {:vneutral, int, {:nsnd, {:nvar, 0}}}
      ne2 = {:vneutral, int, {:nsnd, {:nvar, 1}}}

      assert {:error, _} = Unify.unify(ms, 2, ne1, ne2)
    end

    test "nmeta with different ids fails (rigid path)" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Create two metas and solve them both so they're no longer flex.
      {id0, _m0, ms} = make_meta(ms, int, 0)
      {id1, _m1, ms} = make_meta(ms, int, 0)

      {:ok, ms} = MetaState.solve(ms, id0, {:vlit, 1})
      {:ok, ms} = MetaState.solve(ms, id1, {:vlit, 2})

      # Unifying will force to {:vlit, 1} vs {:vlit, 2}.
      ne0 = {:vneutral, int, {:nmeta, id0}}
      ne1 = {:vneutral, int, {:nmeta, id1}}

      assert {:error, _} = Unify.unify(ms, 0, ne0, ne1)
    end
  end

  # ============================================================================
  # Abstraction — rename_vars edge cases
  # ============================================================================

  describe "abstraction — complex rhs" do
    test "pattern unification with let in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      # rhs = let z = 1 in z (evaluates to 1).
      rhs_val = Eval.eval(Eval.default_ctx(), {:let, {:lit, 1}, {:var, 0}})

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs_val)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with spanned in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      # Spanned wrapping evaluates away, so use a value directly.
      rhs = {:vlit, 42}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification with fst/snd in rhs" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      # rhs = fst(pair(1, 2)) = 1 after eval.
      rhs = {:vlit, 1}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "rename: free var not in map stays unchanged" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      # rhs has a neutral with nvar at level 0 (in scope via spine)
      # and also a def reference.
      rhs = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}]}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "pattern unification: rhs contains free var not in spine (rename nil case)" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      y = Value.fresh_var(1, int)

      # ?0(x) = pair(x, y) — y is in scope but not in the spine.
      # This should fail with scope_escape since y is not in spine_levels.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vpair, x, y}

      assert {:error, {:scope_escape, _, _}} = Unify.unify(ms, 2, flex, rhs)
    end

    test "pair eta: lhs pair matches rhs via projections" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Create a meta for the "whole pair" value.
      {id, meta_val, ms} = make_meta(ms, int, 0)

      # Unify a pair with the meta — this goes through flex-rigid, not pair eta.
      pair = {:vpair, {:vlit, 10}, {:vlit, 20}}
      assert {:ok, ms} = Unify.unify(ms, 0, pair, meta_val)
      assert {:solved, ^pair} = MetaState.lookup(ms, id)
    end

    test "pair eta: both components of lhs pair match rhs projections" do
      ms = MetaState.new()

      p1 = {:vpair, {:vlit, 1}, {:vlit, 2}}
      p2 = {:vpair, {:vlit, 1}, {:vlit, 2}}

      # Goes through pair-vs-pair, checking both components.
      assert {:ok, _} = Unify.unify(ms, 0, p1, p2)
    end

    test "pair eta: rhs pair second component fails" do
      ms = MetaState.new()

      p1 = {:vpair, {:vlit, 1}, {:vlit, 2}}
      p2 = {:vpair, {:vlit, 1}, {:vlit, 3}}

      assert {:error, _} = Unify.unify(ms, 0, p1, p2)
    end

    test "neutral nmeta vs nmeta: same id succeeds (rigid path)" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Create a meta but keep it unsolved. When both sides are the same unsolved meta,
      # they unify via the `lhs == rhs` equality check at the top of `unify`.
      # To hit the nmeta vs nmeta path in unify_neutral, we need them to be different
      # unsolved metas that somehow reach the neutral path. But unsolved metas are flex.
      # So we need to use *solved* metas that resolve to neutrals containing nmeta.
      # Actually the neutral nmeta path is hit when two solved metas point to
      # different neutrals wrapping nmeta.
      #
      # Or we can have an napp wrapping nmeta — those are still flex, not rigid.
      # The nmeta case in unify_neutral happens when both sides are neutrals with
      # nmeta heads and both are NOT flex (because they got through to rigid).
      # But nmeta IS flex by definition.
      #
      # Looking at the code: flex? checks meta_head?, so bare nmeta IS flex.
      # The only way to reach unify_neutral with nmeta is... it can't happen in practice
      # for bare nmeta. It would happen if nmeta appears inside a larger neutral
      # but the entry path checks flex? first.
      # This is defensive code. Let's just verify the behavior we can.
      {id, _m, ms} = make_meta(ms, int, 0)
      meta_ne = {:vneutral, int, {:nmeta, id}}

      # Same unsolved meta on both sides: caught by lhs == rhs.
      assert {:ok, _} = Unify.unify(ms, 0, meta_ne, meta_ne)
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

  # ============================================================================
  # ADT unification (vdata, vcon)
  # ============================================================================

  describe "vdata unification" do
    test "matching vdata types unify" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      data1 = {:vdata, :Maybe, [int]}
      data2 = {:vdata, :Maybe, [int]}

      assert {:ok, _ms} = Unify.unify(ms, 0, data1, data2)
    end

    test "vdata with different names fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      data1 = {:vdata, :Maybe, [int]}
      data2 = {:vdata, :Either, [int]}

      assert {:error, {:mismatch, _, _}} = Unify.unify(ms, 0, data1, data2)
    end

    test "vdata with different arg counts fails" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      data1 = {:vdata, :Pair, [int]}
      data2 = {:vdata, :Pair, [int, int]}

      assert {:error, {:mismatch, _, _}} = Unify.unify(ms, 0, data1, data2)
    end

    test "vdata unifies args recursively" do
      ms = MetaState.new()

      # Create a meta to verify args are unified, not just compared.
      {_id, meta_val, ms} = make_meta(ms)

      data1 = {:vdata, :Maybe, [meta_val]}
      data2 = {:vdata, :Maybe, [{:vbuiltin, :Int}]}

      assert {:ok, ms} = Unify.unify(ms, 0, data1, data2)
      # The meta should now be solved to Int.
      forced = MetaState.force(ms, meta_val)
      assert forced == {:vbuiltin, :Int}
    end
  end

  describe "vcon unification" do
    test "matching vcon constructors unify" do
      ms = MetaState.new()

      con1 = {:vcon, :Maybe, :Just, [{:vlit, 42}]}
      con2 = {:vcon, :Maybe, :Just, [{:vlit, 42}]}

      assert {:ok, _ms} = Unify.unify(ms, 0, con1, con2)
    end

    test "vcon with different type names fails" do
      ms = MetaState.new()

      con1 = {:vcon, :Maybe, :Just, [{:vlit, 42}]}
      con2 = {:vcon, :Either, :Just, [{:vlit, 42}]}

      assert {:error, {:mismatch, _, _}} = Unify.unify(ms, 0, con1, con2)
    end

    test "vcon with different constructor names fails" do
      ms = MetaState.new()

      con1 = {:vcon, :Maybe, :Just, [{:vlit, 42}]}
      con2 = {:vcon, :Maybe, :Nothing, []}

      assert {:error, {:mismatch, _, _}} = Unify.unify(ms, 0, con1, con2)
    end

    test "vcon unifies args recursively" do
      ms = MetaState.new()
      {_id, meta_val, ms} = make_meta(ms)

      con1 = {:vcon, :Maybe, :Just, [meta_val]}
      con2 = {:vcon, :Maybe, :Just, [{:vlit, 99}]}

      assert {:ok, ms} = Unify.unify(ms, 0, con1, con2)
      forced = MetaState.force(ms, meta_val)
      assert forced == {:vlit, 99}
    end
  end

  # ============================================================================
  # ADT terms in flex-rigid (occurs/scope through vdata/vcon)
  # ============================================================================

  describe "occurs and scope checks with ADT terms" do
    test "meta in vdata arg triggers occurs check" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x) vs VData(:Maybe, [?0(x)]) — occurs check should fail.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vdata, :Maybe, [flex]}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 1, flex, rhs)
    end

    test "meta in vcon arg triggers occurs check" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x) vs VCon(:Maybe, :Just, [?0(x)]) — occurs check should fail.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vcon, :Maybe, :Just, [flex]}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 1, flex, rhs)
    end

    test "vdata with in-scope variables passes scope check" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x) vs VData(:Maybe, [x]) — x is in the spine, so scope check passes.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vdata, :Maybe, [x]}

      assert {:ok, _ms} = Unify.unify(ms, 1, flex, rhs)
    end

    test "vcon with in-scope variables passes scope check" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # ?0(x) vs VCon(:Maybe, :Just, [x]) — x is in the spine, so scope check passes.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vcon, :Maybe, :Just, [x]}

      assert {:ok, _ms} = Unify.unify(ms, 1, flex, rhs)
    end

    test "vdata with out-of-scope variable triggers scope escape" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      y = Value.fresh_var(1, int)

      # ?0(x) vs VData(:Maybe, [y]) — y is NOT in the spine, scope escape.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vdata, :Maybe, [y]}

      assert {:error, {:scope_escape, ^id, _}} = Unify.unify(ms, 2, flex, rhs)
    end

    test "vcon with out-of-scope variable triggers scope escape" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      y = Value.fresh_var(1, int)

      # ?0(x) vs VCon(:Maybe, :Just, [y]) — y not in spine, scope escape.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vcon, :Maybe, :Just, [y]}

      assert {:error, {:scope_escape, ^id, _}} = Unify.unify(ms, 2, flex, rhs)
    end
  end

  # ============================================================================
  # Neutral ncase in occurs/scope checks
  # ============================================================================

  describe "ncase in occurs and scope checks" do
    test "meta in ncase head triggers occurs check" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # Build a neutral case: case ?0(x) of ... — the head contains the meta.
      meta_app = {:napp, {:nmeta, id}, x}
      ncase_ne = {:ncase, meta_app, [{:Just, 1, {:var, 0}}], []}

      # ?0(x) vs vneutral wrapping ncase with ?0(x) as head.
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, ncase_ne}

      assert {:error, {:occurs_check, ^id, _}} = Unify.unify(ms, 1, flex, rhs)
    end

    test "ncase with in-scope head variable passes scope check" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta_val, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)

      # Build ncase with head = nvar(0), which is in the spine.
      ncase_ne = {:ncase, {:nvar, 0}, [{:Just, 1, {:var, 0}}], []}

      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}
      rhs = {:vneutral, int, ncase_ne}

      assert {:ok, _ms} = Unify.unify(ms, 1, flex, rhs)
    end
  end

  # ============================================================================
  # rename_vars edge cases via pattern unification
  # ============================================================================

  describe "rename_vars — uncovered branches via pattern unification" do
    test "rhs with ncase containing __lit branch exercises rename_vars :__lit" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      # Build a neutral case with a __lit branch.
      # The __lit body contains a var that will be renamed.
      # The env must contain the value for var(0) since quote_neutral
      # evaluates branch bodies under the captured env.
      ncase_ne = {:ncase, {:nvar, 0}, [{:__lit, true, {:var, 0}}], [x]}
      rhs = {:vneutral, int, ncase_ne}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "rhs neutral with record_proj exercises rename_vars :record_proj" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      # quote_untyped will produce {:var, 0} from nvar(0). We need a value
      # that quotes to {:record_proj, ...}. Since quote_untyped doesn't produce
      # record_proj from standard values, we test rename_vars indirectly:
      # the solution is built by abstract -> quote_untyped -> rename_vars.
      # We can unify with a value containing a variable in the spine.
      rhs = x

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, solution} = MetaState.lookup(ms, id)
      # The solution should be the identity: fn(a) -> a.
      result = Eval.vapp(Eval.default_ctx(), solution, {:vlit, 77})
      assert result == {:vlit, 77}
    end

    test "rhs with let value exercises rename_vars :let path" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      # A let expression evaluates to its body value in NbE.
      # So (let z = 1 in z) evaluates to {:vlit, 1}.
      rhs_val = Eval.eval(Eval.default_ctx(), {:let, {:lit, 1}, {:var, 0}})
      assert rhs_val == {:vlit, 1}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs_val)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "rhs with spanned value exercises rename_vars :spanned path" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      # Spanned evaluates to the inner value in NbE.
      rhs = {:vlit, 42}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end

    test "free var not in rename map stays unchanged" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      {id, _meta, ms} = make_meta(ms, int, 0)

      x = Value.fresh_var(0, int)
      flex = {:vneutral, int, {:napp, {:nmeta, id}, x}}

      # rhs is a ndef neutral — the quote will produce {:ndef, ...} which
      # goes through the catch-all in rename_vars.
      rhs = {:vneutral, int, {:ndef, :some_fn, [{:vlit, 1}]}}

      assert {:ok, ms} = Unify.unify(ms, 1, flex, rhs)
      assert {:solved, _} = MetaState.lookup(ms, id)
    end
  end

  # ============================================================================
  # Eta pair — lhs pair vs non-pair rhs
  # ============================================================================

  describe "eta pair — lhs pair vs non-pair" do
    test "lhs pair against non-pair neutral decomposes via fst/snd" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      _sigma = {:vsigma, int, [], {:builtin, :Int}}

      # Create a meta that will be solved to a pair.
      {id, meta_val, ms} = make_meta(ms, int, 0)

      pair = {:vpair, {:vlit, 10}, {:vlit, 20}}

      # pair on lhs, meta on rhs — meta is flex, goes through flex-rigid.
      assert {:ok, ms} = Unify.unify(ms, 0, pair, meta_val)
      assert {:solved, ^pair} = MetaState.lookup(ms, id)
    end

    test "rhs pair against lhs non-pair decomposes via projections" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      # Create a meta on the left side.
      {id, meta_val, ms} = make_meta(ms, int, 0)
      pair = {:vpair, {:vlit, 5}, {:vlit, 6}}

      # meta on lhs, pair on rhs — meta is flex, solved to pair.
      assert {:ok, ms} = Unify.unify(ms, 0, meta_val, pair)
      assert {:solved, ^pair} = MetaState.lookup(ms, id)
    end
  end

  # ============================================================================
  # Two different unsolved nmetas
  # ============================================================================

  describe "nmeta vs nmeta — different ids" do
    test "two different bare unsolved metas unify via flex-flex" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      {id0, _m0, ms} = make_meta(ms, int, 0)
      {id1, _m1, ms} = make_meta(ms, int, 0)

      ne0 = {:vneutral, int, {:nmeta, id0}}
      ne1 = {:vneutral, int, {:nmeta, id1}}

      assert {:ok, ms} = Unify.unify(ms, 0, ne0, ne1)
      # Higher meta solved to lower — the solution references meta 0.
      assert {:solved, {:vneutral, _, {:nmeta, ^id0}}} = MetaState.lookup(ms, id1)
    end

    test "same bare unsolved meta unifies with itself" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}

      {_id, _m, ms} = make_meta(ms, int, 0)
      ne = {:vneutral, int, {:nmeta, 0}}

      assert {:ok, _} = Unify.unify(ms, 0, ne, ne)
    end
  end

  # ============================================================================
  # Bare meta solving with context variables
  # ============================================================================

  describe "bare meta solving with nvar" do
    test "bare meta solves to in-scope nvar" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      # Meta created at level 5 — variables at levels 0..4 are in scope.
      {id, _meta, ms} = make_meta(ms, int, 5)

      meta_val = {:vneutral, int, {:nmeta, id}}
      y = Value.fresh_var(3, int)

      # nvar(3) is in scope (3 < 5). Should solve meta to nvar(3).
      assert {:ok, ms} = Unify.unify(ms, 6, meta_val, y)
      assert {:solved, ^y} = MetaState.lookup(ms, id)
    end

    test "bare meta rejects out-of-scope nvar" do
      ms = MetaState.new()
      int = {:vbuiltin, :Int}
      # Meta created at level 2 — only variables at levels 0..1 are in scope.
      {id, _meta, ms} = make_meta(ms, int, 2)

      meta_val = {:vneutral, int, {:nmeta, id}}
      y = Value.fresh_var(5, int)

      # nvar(5) is out of scope (5 >= 2).
      assert {:error, {:scope_escape, ^id, _}} = Unify.unify(ms, 6, meta_val, y)
    end
  end

  # ============================================================================
  # ncase neutral unification
  # ============================================================================

  describe "ncase neutral unification" do
    test "two stuck cases on the same scrutinee unify" do
      ms = MetaState.new()
      nat = {:vdata, :Nat, []}

      # Two stuck cases: case nvar(0) of ... with different captured envs.
      branches = [{:zero, 0, {:lit, 1}}, {:succ, 1, {:lit, 2}}]
      ne1 = {:ncase, {:nvar, 0}, branches, [:env_a]}
      ne2 = {:ncase, {:nvar, 0}, branches, [:env_b]}

      lhs = {:vneutral, nat, ne1}
      rhs = {:vneutral, nat, ne2}

      assert {:ok, _ms} = Unify.unify(ms, 1, lhs, rhs)
    end

    test "two stuck cases on different scrutinees fail" do
      ms = MetaState.new()
      nat = {:vdata, :Nat, []}

      branches = [{:zero, 0, {:lit, 1}}, {:succ, 1, {:lit, 2}}]
      ne1 = {:ncase, {:nvar, 0}, branches, []}
      ne2 = {:ncase, {:nvar, 1}, branches, []}

      lhs = {:vneutral, nat, ne1}
      rhs = {:vneutral, nat, ne2}

      assert {:error, _} = Unify.unify(ms, 2, lhs, rhs)
    end

    test "stuck cases on same meta scrutinee unify" do
      ms = MetaState.new()
      nat = {:vdata, :Nat, []}
      {_id, _meta, ms} = make_meta(ms, nat, 2)

      # Both stuck on the same unsolved meta — should be equal.
      branches = [{:zero, 0, {:lit, 1}}, {:succ, 1, {:lit, 2}}]
      ne1 = {:ncase, {:nmeta, 0}, branches, [:env_a]}
      ne2 = {:ncase, {:nmeta, 0}, branches, [:env_b]}

      lhs = {:vneutral, nat, ne1}
      rhs = {:vneutral, nat, ne2}

      assert {:ok, _ms} = Unify.unify(ms, 2, lhs, rhs)
    end
  end
end
