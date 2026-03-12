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
end
