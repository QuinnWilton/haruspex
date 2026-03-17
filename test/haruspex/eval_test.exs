defmodule Haruspex.EvalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Eval
  alias Haruspex.Value

  defp ctx(env \\ []), do: Eval.default_ctx(env)

  # ============================================================================
  # Basic term evaluation
  # ============================================================================

  describe "eval/2 basic terms" do
    test "var looks up environment by index" do
      c = ctx([{:vlit, 42}, {:vlit, 10}])
      assert Eval.eval(c, {:var, 0}) == {:vlit, 42}
      assert Eval.eval(c, {:var, 1}) == {:vlit, 10}
    end

    test "lam produces closure" do
      c = ctx([{:vlit, 1}])
      assert {:vlam, :omega, [{:vlit, 1}], {:var, 0}} = Eval.eval(c, {:lam, :omega, {:var, 0}})
    end

    test "app beta-reduces" do
      # (fn x -> x)(42) = 42
      c = ctx()
      lam = {:lam, :omega, {:var, 0}}
      assert Eval.eval(c, {:app, lam, {:lit, 42}}) == {:vlit, 42}
    end

    test "lit evaluates to vlit" do
      assert Eval.eval(ctx(), {:lit, 42}) == {:vlit, 42}
      assert Eval.eval(ctx(), {:lit, "hello"}) == {:vlit, "hello"}
      assert Eval.eval(ctx(), {:lit, 3.14}) == {:vlit, 3.14}
    end

    test "builtin evaluates to vbuiltin" do
      assert Eval.eval(ctx(), {:builtin, :Int}) == {:vbuiltin, :Int}
      assert Eval.eval(ctx(), {:builtin, :add}) == {:vbuiltin, :add}
    end

    test "type evaluates to vtype" do
      assert Eval.eval(ctx(), {:type, {:llit, 0}}) == {:vtype, {:llit, 0}}
    end

    test "pi evaluates domain, captures codomain" do
      c = ctx()

      assert {:vpi, :omega, {:vbuiltin, :Int}, [], {:var, 0}} =
               Eval.eval(c, {:pi, :omega, {:builtin, :Int}, {:var, 0}})
    end

    test "sigma evaluates first type, captures second" do
      c = ctx()

      assert {:vsigma, {:vbuiltin, :Int}, [], {:var, 0}} =
               Eval.eval(c, {:sigma, {:builtin, :Int}, {:var, 0}})
    end

    test "pair evaluates both components" do
      c = ctx()
      assert {:vpair, {:vlit, 1}, {:vlit, 2}} = Eval.eval(c, {:pair, {:lit, 1}, {:lit, 2}})
    end

    test "fst projects first of pair" do
      c = ctx()
      assert Eval.eval(c, {:fst, {:pair, {:lit, 1}, {:lit, 2}}}) == {:vlit, 1}
    end

    test "snd projects second of pair" do
      c = ctx()
      assert Eval.eval(c, {:snd, {:pair, {:lit, 1}, {:lit, 2}}}) == {:vlit, 2}
    end

    test "let evaluates definition and extends env for body" do
      c = ctx()
      # let x = 42 in x
      assert Eval.eval(c, {:let, {:lit, 42}, {:var, 0}}) == {:vlit, 42}
    end

    test "extern evaluates to vextern" do
      assert Eval.eval(ctx(), {:extern, Enum, :map, 2}) == {:vextern, Enum, :map, 2}
    end

    test "spanned is transparent" do
      span = Pentiment.Span.Byte.new(0, 5)
      assert Eval.eval(ctx(), {:spanned, span, {:lit, 42}}) == {:vlit, 42}
    end
  end

  # ============================================================================
  # Delta reduction
  # ============================================================================

  describe "delta reduction" do
    test "add reduces two integer literals" do
      c = ctx()
      term = {:app, {:app, {:builtin, :add}, {:lit, 2}}, {:lit, 3}}
      assert Eval.eval(c, term) == {:vlit, 5}
    end

    test "sub reduces" do
      c = ctx()
      term = {:app, {:app, {:builtin, :sub}, {:lit, 10}}, {:lit, 3}}
      assert Eval.eval(c, term) == {:vlit, 7}
    end

    test "mul reduces" do
      c = ctx()
      term = {:app, {:app, {:builtin, :mul}, {:lit, 4}}, {:lit, 5}}
      assert Eval.eval(c, term) == {:vlit, 20}
    end

    test "div reduces" do
      c = ctx()
      term = {:app, {:app, {:builtin, :div}, {:lit, 10}}, {:lit, 3}}
      assert Eval.eval(c, term) == {:vlit, 3}
    end

    test "neg reduces" do
      c = ctx()
      assert Eval.eval(c, {:app, {:builtin, :neg}, {:lit, 5}}) == {:vlit, -5}
    end

    test "division by zero produces stuck neutral" do
      c = ctx()
      term = {:app, {:app, {:builtin, :div}, {:lit, 1}}, {:lit, 0}}
      assert {:vneutral, _, _} = Eval.eval(c, term)
    end

    test "float division by zero produces stuck neutral" do
      c = ctx()
      term = {:app, {:app, {:builtin, :fdiv}, {:lit, 1.0}}, {:lit, +0.0}}
      assert {:vneutral, _, _} = Eval.eval(c, term)
    end

    test "float operations reduce" do
      c = ctx()

      assert Eval.eval(c, {:app, {:app, {:builtin, :fadd}, {:lit, 1.5}}, {:lit, 2.5}}) ==
               {:vlit, 4.0}

      assert Eval.eval(c, {:app, {:app, {:builtin, :fmul}, {:lit, 2.0}}, {:lit, 3.0}}) ==
               {:vlit, 6.0}
    end

    test "comparison operations reduce" do
      c = ctx()
      assert Eval.eval(c, {:app, {:app, {:builtin, :eq}, {:lit, 1}}, {:lit, 1}}) == {:vlit, true}
      assert Eval.eval(c, {:app, {:app, {:builtin, :eq}, {:lit, 1}}, {:lit, 2}}) == {:vlit, false}
      assert Eval.eval(c, {:app, {:app, {:builtin, :lt}, {:lit, 1}}, {:lit, 2}}) == {:vlit, true}
      assert Eval.eval(c, {:app, {:app, {:builtin, :gt}, {:lit, 1}}, {:lit, 2}}) == {:vlit, false}
    end

    test "boolean operations reduce" do
      c = ctx()

      assert Eval.eval(c, {:app, {:app, {:builtin, :and}, {:lit, true}}, {:lit, false}}) ==
               {:vlit, false}

      assert Eval.eval(c, {:app, {:app, {:builtin, :or}, {:lit, true}}, {:lit, false}}) ==
               {:vlit, true}

      assert Eval.eval(c, {:app, {:builtin, :not}, {:lit, true}}) == {:vlit, false}
    end
  end

  # ============================================================================
  # Partial application
  # ============================================================================

  describe "partial application" do
    test "single arg to binary builtin produces partial" do
      c = ctx()
      result = Eval.eval(c, {:app, {:builtin, :add}, {:lit, 2}})
      assert {:vbuiltin, {:add, [{:vlit, 2}]}} = result
    end

    test "partial then second arg reduces" do
      c = ctx()
      # add(2) then apply 3
      partial = Eval.eval(c, {:app, {:builtin, :add}, {:lit, 2}})
      result = Eval.vapp(c, partial, {:vlit, 3})
      assert result == {:vlit, 5}
    end
  end

  # ============================================================================
  # Stuck terms
  # ============================================================================

  describe "stuck terms" do
    test "add with neutral first arg is stuck" do
      int_type = {:vbuiltin, :Int}
      x = Value.fresh_var(0, int_type)
      c = ctx([x])

      term = {:app, {:app, {:builtin, :add}, {:var, 0}}, {:lit, 3}}
      assert {:vneutral, _, _} = Eval.eval(c, term)
    end

    test "add with neutral second arg is stuck" do
      int_type = {:vbuiltin, :Int}
      x = Value.fresh_var(0, int_type)
      c = ctx([x])

      term = {:app, {:app, {:builtin, :add}, {:lit, 3}}, {:var, 0}}
      assert {:vneutral, _, _} = Eval.eval(c, term)
    end

    test "fst of neutral is stuck" do
      sigma_type = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      p = Value.fresh_var(0, sigma_type)
      c = ctx([p])

      assert {:vneutral, _, {:nfst, {:nvar, 0}}} = Eval.eval(c, {:fst, {:var, 0}})
    end

    test "snd of neutral is stuck" do
      sigma_type = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      p = Value.fresh_var(0, sigma_type)
      c = ctx([p])

      assert {:vneutral, _, {:nsnd, {:nvar, 0}}} = Eval.eval(c, {:snd, {:var, 0}})
    end
  end

  # ============================================================================
  # Metas
  # ============================================================================

  describe "metas" do
    test "unsolved meta produces neutral" do
      c = %{ctx() | metas: %{0 => :unsolved}}
      assert {:vneutral, _, {:nmeta, 0}} = Eval.eval(c, {:meta, 0})
    end

    test "solved meta returns solution" do
      c = %{ctx() | metas: %{0 => {:solved, {:vlit, 42}}}}
      assert Eval.eval(c, {:meta, 0}) == {:vlit, 42}
    end

    test "unknown meta (not in map) produces neutral" do
      assert {:vneutral, _, {:nmeta, 99}} = Eval.eval(ctx(), {:meta, 99})
    end

    test "inserted meta applies to masked env variables" do
      int_type = {:vbuiltin, :Int}
      v0 = Value.fresh_var(0, int_type)
      v1 = Value.fresh_var(1, int_type)
      v2 = Value.fresh_var(2, int_type)

      c = %{ctx([v2, v1, v0]) | metas: %{0 => :unsolved}}

      # mask [true, false, true] → apply meta to level 0 (v0) and level 2 (v2)
      result = Eval.eval(c, {:inserted_meta, 0, [true, false, true]})

      # Result is NApp(NApp(NMeta(0), v0), v2)
      assert {:vneutral, _, {:napp, {:napp, {:nmeta, 0}, ^v0}, ^v2}} = result
    end
  end

  # ============================================================================
  # Application edge cases
  # ============================================================================

  describe "vapp edge cases" do
    test "apply neutral with Pi type computes codomain" do
      int = {:vbuiltin, :Int}
      pi = {:vpi, :omega, int, [], {:builtin, :Int}}
      f = {:vneutral, pi, {:nvar, 0}}
      c = ctx()

      result = Eval.vapp(c, f, {:vlit, 42})
      assert {:vneutral, {:vbuiltin, :Int}, {:napp, {:nvar, 0}, {:vlit, 42}}} = result
    end

    test "apply type builtin produces stuck" do
      c = ctx()
      result = Eval.vapp(c, {:vbuiltin, :Int}, {:vlit, 42})
      assert {:vneutral, _, {:napp, {:nbuiltin, :Int}, {:vlit, 42}}} = result
    end

    test "apply extern produces stuck" do
      c = ctx()
      result = Eval.vapp(c, {:vextern, Enum, :map, 2}, {:vlit, 42})
      assert {:vneutral, _, _} = result
    end

    test "fsub reduces" do
      c = ctx()
      term = {:app, {:app, {:builtin, :fsub}, {:lit, 5.0}}, {:lit, 2.0}}
      assert Eval.eval(c, term) == {:vlit, 3.0}
    end

    test "fdiv reduces" do
      c = ctx()
      term = {:app, {:app, {:builtin, :fdiv}, {:lit, 10.0}}, {:lit, 2.0}}
      assert Eval.eval(c, term) == {:vlit, 5.0}
    end

    test "neq reduces" do
      c = ctx()
      assert Eval.eval(c, {:app, {:app, {:builtin, :neq}, {:lit, 1}}, {:lit, 2}}) == {:vlit, true}
    end

    test "lte and gte reduce" do
      c = ctx()
      assert Eval.eval(c, {:app, {:app, {:builtin, :lte}, {:lit, 1}}, {:lit, 1}}) == {:vlit, true}
      assert Eval.eval(c, {:app, {:app, {:builtin, :gte}, {:lit, 1}}, {:lit, 1}}) == {:vlit, true}
    end

    test "sub reduces" do
      c = ctx()
      term = {:app, {:app, {:builtin, :sub}, {:lit, 5}}, {:lit, 2}}
      assert Eval.eval(c, term) == {:vlit, 3}
    end

    test "snd of neutral without sigma type" do
      int = {:vbuiltin, :Int}
      p = {:vneutral, int, {:nvar, 0}}
      result = Eval.vsnd(p)
      assert {:vneutral, _, {:nsnd, {:nvar, 0}}} = result
    end

    test "fst of neutral without sigma type" do
      int = {:vbuiltin, :Int}
      p = {:vneutral, int, {:nvar, 0}}
      result = Eval.vfst(p)
      assert {:vneutral, _, {:nfst, {:nvar, 0}}} = result
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "delta correctness: add(a, b) == a + b for integers" do
      check all(
              a <- integer(),
              b <- integer()
            ) do
        c = ctx()
        term = {:app, {:app, {:builtin, :add}, {:lit, a}}, {:lit, b}}
        assert Eval.eval(c, term) == {:vlit, a + b}
      end
    end

    property "delta correctness: mul(a, b) == a * b for integers" do
      check all(
              a <- integer(),
              b <- integer()
            ) do
        c = ctx()
        term = {:app, {:app, {:builtin, :mul}, {:lit, a}}, {:lit, b}}
        assert Eval.eval(c, term) == {:vlit, a * b}
      end
    end

    property "delta correctness: div(a, b) == div(a, b) for non-zero b" do
      check all(
              a <- integer(),
              b <- integer() |> StreamData.filter(&(&1 != 0))
            ) do
        c = ctx()
        term = {:app, {:app, {:builtin, :div}, {:lit, a}}, {:lit, b}}
        assert Eval.eval(c, term) == {:vlit, Kernel.div(a, b)}
      end
    end

    property "beta reduction: (fn x -> x)(v) == v for literals" do
      check all(n <- integer()) do
        c = ctx()
        term = {:app, {:lam, :omega, {:var, 0}}, {:lit, n}}
        assert Eval.eval(c, term) == {:vlit, n}
      end
    end
  end

  # ============================================================================
  # Coverage: vcase constructor error — no matching branch
  # ============================================================================

  describe "vcase — constructor no matching branch" do
    test "raises CompilerBug when no branch matches and no wildcard" do
      c = ctx()
      scrutinee = {:vcon, :Color, :Red, []}
      branches = [{:Blue, 0, {:lit, 1}}, {:Green, 0, {:lit, 2}}]

      assert_raise Haruspex.CompilerBug, ~r/no branch for constructor Red/, fn ->
        Eval.vcase(c, scrutinee, branches)
      end
    end
  end

  # ============================================================================
  # Coverage: vcase literal wildcard with arity 0
  # ============================================================================

  describe "vcase — literal wildcard arity 0" do
    test "literal falls through to wildcard with arity 0" do
      c = ctx()
      scrutinee = {:vlit, 99}
      # No literal branch matches 99, wildcard with arity 0 catches it.
      branches = [{:__lit, 1, {:lit, 10}}, {:_, 0, {:lit, 0}}]

      result = Eval.vcase(c, scrutinee, branches)
      assert result == {:vlit, 0}
    end
  end

  # ============================================================================
  # Coverage: vcase literal error — no matching branch
  # ============================================================================

  describe "vcase — literal no matching branch" do
    test "raises CompilerBug when no literal branch matches and no wildcard" do
      c = ctx()
      scrutinee = {:vlit, 99}
      branches = [{:__lit, 1, {:lit, 10}}, {:__lit, 2, {:lit, 20}}]

      assert_raise Haruspex.CompilerBug, ~r/no branch for literal 99/, fn ->
        Eval.vcase(c, scrutinee, branches)
      end
    end
  end

  # ============================================================================
  # Coverage: vcase neutral — stuck case
  # ============================================================================

  describe "vcase — neutral scrutinee" do
    test "neutral scrutinee produces stuck case" do
      c = ctx()
      int = {:vbuiltin, :Int}
      ne_val = {:vneutral, int, {:nvar, 0}}
      branches = [{:Zero, 0, {:lit, 0}}, {:Succ, 1, {:var, 0}}]

      result = Eval.vcase(c, ne_val, branches)
      # Branches are wrapped as closures with the current env.
      expected_closures = [{:Zero, 0, {[], {:lit, 0}}}, {:Succ, 1, {[], {:var, 0}}}]
      assert {:vneutral, ^int, {:ncase, {:nvar, 0}, ^expected_closures}} = result
    end
  end

  # ============================================================================
  # Coverage: do_delta catch-all
  # ============================================================================

  describe "do_delta — stuck reduction paths" do
    test "neg with neutral arg produces stuck neutral" do
      # The do_delta catch-all (line 409) is a defensive fallback for unknown ops.
      # For known builtins with non-literal args, make_stuck_builtin is used instead.
      c = ctx()
      x = Value.fresh_var(0, {:vbuiltin, :Int})
      result = Eval.vapp(c, {:vbuiltin, :neg}, x)
      assert {:vneutral, _, _} = result
    end

    test "integer division by zero returns stuck via do_delta" do
      # div(1, 0) → do_delta(:div, [1, 0]) → :stuck → make_stuck_builtin.
      c = ctx()
      term = {:app, {:app, {:builtin, :div}, {:lit, 1}}, {:lit, 0}}
      assert {:vneutral, _, _} = Eval.eval(c, term)
    end

    test "float division by zero returns stuck via do_delta" do
      # fdiv(1.0, 0.0) → do_delta(:fdiv, [1.0, 0.0]) → :stuck → make_stuck_builtin.
      c = ctx()
      term = {:app, {:app, {:builtin, :fdiv}, {:lit, 1.0}}, {:lit, +0.0}}
      assert {:vneutral, _, _} = Eval.eval(c, term)
    end
  end

  # ============================================================================
  # Coverage: vcase constructor wildcard with arity 0
  # ============================================================================

  describe "vcase — constructor wildcard arity 0" do
    test "constructor falls through to wildcard with arity 0" do
      c = ctx()
      scrutinee = {:vcon, :Color, :Red, []}
      branches = [{:Blue, 0, {:lit, 1}}, {:_, 0, {:lit, 99}}]

      result = Eval.vcase(c, scrutinee, branches)
      assert result == {:vlit, 99}
    end
  end

  # ============================================================================
  # whnf — weak head normal form with meta resolution
  # ============================================================================

  alias Haruspex.Unify.MetaState

  describe "whnf/2" do
    test "non-neutral values pass through unchanged" do
      c = ctx()
      assert Eval.whnf(c, {:vbuiltin, :Int}) == {:vbuiltin, :Int}
      assert Eval.whnf(c, {:vlit, 42}) == {:vlit, 42}
      assert Eval.whnf(c, {:vdata, :Nat, []}) == {:vdata, :Nat, []}
    end

    test "unsolved meta stays neutral" do
      ms = MetaState.new()
      {_id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      c = %{ctx() | metas: ms.entries}

      val = {:vneutral, {:vbuiltin, :Int}, {:nmeta, 0}}
      assert {:vneutral, _, {:nmeta, 0}} = Eval.whnf(c, val)
    end

    test "solved bare meta resolves to solution" do
      ms = MetaState.new()
      {_id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, 0, {:vlit, 42})
      c = %{ctx() | metas: ms.entries}

      val = {:vneutral, {:vbuiltin, :Int}, {:nmeta, 0}}
      assert {:vlit, 42} = Eval.whnf(c, val)
    end

    test "solved meta chain resolves transitively" do
      ms = MetaState.new()
      {_, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {_, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, 0, {:vneutral, {:vbuiltin, :Int}, {:nmeta, 1}})
      {:ok, ms} = MetaState.solve(ms, 1, {:vlit, 99})
      c = %{ctx() | metas: ms.entries}

      val = {:vneutral, {:vbuiltin, :Int}, {:nmeta, 0}}
      assert {:vlit, 99} = Eval.whnf(c, val)
    end

    test "applied solved meta re-reduces" do
      ms = MetaState.new()
      {_, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      # Solve meta 0 to a lambda: fn x -> x
      identity = {:vlam, :omega, [], {:var, 0}}
      {:ok, ms} = MetaState.solve(ms, 0, identity)
      c = %{ctx() | metas: ms.entries}

      # Build: ?0(42) — applied solved meta.
      arg = {:vlit, 42}
      val = {:vneutral, {:vtype, {:llit, 0}}, {:napp, {:nmeta, 0}, arg}}

      assert {:vlit, 42} = Eval.whnf(c, val)
    end

    test "stuck case becomes reducible after scrutinee meta solved" do
      ms = MetaState.new()
      {_, ms} = MetaState.fresh_meta(ms, {:vdata, :Nat, []}, 0, :implicit)

      # Build stuck case: case ?0 of zero -> 1; succ(_) -> 2
      closures = [
        {:zero, 0, {[], {:lit, 1}}},
        {:succ, 1, {[], {:lit, 2}}}
      ]

      stuck =
        {:vneutral, {:vbuiltin, :Int}, {:ncase, {:nmeta, 0}, closures}}

      # Before solving: stays stuck.
      c_unsolved = %{ctx() | metas: ms.entries}
      assert {:vneutral, _, {:ncase, _, _}} = Eval.whnf(c_unsolved, stuck)

      # Solve ?0 to zero, then whnf reduces the case.
      {:ok, ms} = MetaState.solve(ms, 0, {:vcon, :Nat, :zero, []})
      c_solved = %{ctx() | metas: ms.entries}
      assert {:vlit, 1} = Eval.whnf(c_solved, stuck)
    end

    test "stuck fst resolves when inner neutral is solved to pair" do
      ms = MetaState.new()
      {_, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, 0, {:vpair, {:vlit, 1}, {:vlit, 2}})
      c = %{ctx() | metas: ms.entries}

      val = {:vneutral, {:vbuiltin, :Int}, {:nfst, {:nmeta, 0}}}
      assert {:vlit, 1} = Eval.whnf(c, val)
    end
  end
end
