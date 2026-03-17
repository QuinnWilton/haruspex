defmodule Haruspex.QuoteTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Eval
  alias Haruspex.Quote

  defp ctx(env \\ []), do: Eval.default_ctx(env)

  # ============================================================================
  # Basic readback
  # ============================================================================

  describe "quote/3 basic readback" do
    test "literal" do
      assert Quote.quote(0, {:vbuiltin, :Int}, {:vlit, 42}) == {:lit, 42}
    end

    test "type" do
      assert Quote.quote(0, {:vtype, {:llit, 1}}, {:vtype, {:llit, 0}}) == {:type, {:llit, 0}}
    end

    test "builtin type" do
      assert Quote.quote(0, {:vtype, {:llit, 0}}, {:vbuiltin, :Int}) == {:builtin, :Int}
    end

    test "neutral variable — level to index conversion" do
      # At depth 3, level 0 → index 2, level 1 → index 1, level 2 → index 0.
      int = {:vbuiltin, :Int}
      assert Quote.quote(3, int, {:vneutral, int, {:nvar, 0}}) == {:var, 2}
      assert Quote.quote(3, int, {:vneutral, int, {:nvar, 1}}) == {:var, 1}
      assert Quote.quote(3, int, {:vneutral, int, {:nvar, 2}}) == {:var, 0}
    end

    test "neutral application" do
      int = {:vbuiltin, :Int}

      val =
        {:vneutral, int, {:napp, {:nvar, 0}, {:vlit, 42}}}

      assert Quote.quote(1, int, val) == {:app, {:var, 0}, {:lit, 42}}
    end

    test "neutral fst" do
      int = {:vbuiltin, :Int}
      val = {:vneutral, int, {:nfst, {:nvar, 0}}}
      assert Quote.quote(1, int, val) == {:fst, {:var, 0}}
    end

    test "neutral snd" do
      int = {:vbuiltin, :Int}
      val = {:vneutral, int, {:nsnd, {:nvar, 0}}}
      assert Quote.quote(1, int, val) == {:snd, {:var, 0}}
    end

    test "neutral meta" do
      int = {:vbuiltin, :Int}
      val = {:vneutral, int, {:nmeta, 5}}
      assert Quote.quote(0, int, val) == {:meta, 5}
    end

    test "neutral builtin" do
      int = {:vbuiltin, :Int}
      val = {:vneutral, int, {:nbuiltin, :add}}
      assert Quote.quote(0, int, val) == {:builtin, :add}
    end
  end

  # ============================================================================
  # Eta expansion
  # ============================================================================

  describe "eta expansion at Pi type" do
    test "lambda at Pi type is read back as lambda" do
      int = {:vbuiltin, :Int}
      pi = {:vpi, :omega, int, [], {:builtin, :Int}}

      # Identity function closure.
      val = {:vlam, :omega, [], {:var, 0}}
      result = Quote.quote(0, pi, val)

      assert {:lam, :omega, _body} = result
    end

    test "neutral at Pi type is eta-expanded to lambda" do
      int = {:vbuiltin, :Int}
      pi = {:vpi, :omega, int, [], {:builtin, :Int}}

      # Neutral function f (level 0).
      f = {:vneutral, pi, {:nvar, 0}}
      result = Quote.quote(1, pi, f)

      # Should be Lam(ω, App(Var(1), Var(0))) — eta-expanded.
      # At depth 1, f is at level 0 → index 0. But under the new lambda,
      # depth becomes 2, so level 0 → index 1. The fresh arg is level 1 → index 0.
      assert {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} = result
    end
  end

  describe "eta expansion at Sigma type" do
    test "pair at Sigma type is read back as pair" do
      int = {:vbuiltin, :Int}
      sigma = {:vsigma, int, [], {:builtin, :Int}}

      val = {:vpair, {:vlit, 1}, {:vlit, 2}}
      result = Quote.quote(0, sigma, val)

      assert {:pair, {:lit, 1}, {:lit, 2}} = result
    end

    test "neutral at Sigma type is eta-expanded to pair" do
      int = {:vbuiltin, :Int}
      sigma = {:vsigma, int, [], {:builtin, :Int}}

      p = {:vneutral, sigma, {:nvar, 0}}
      result = Quote.quote(1, sigma, p)

      # Should be Pair(Fst(Var(0)), Snd(Var(0))).
      assert {:pair, {:fst, {:var, 0}}, {:snd, {:var, 0}}} = result
    end
  end

  describe "quote — other value forms" do
    test "partially applied builtin is quoted structurally" do
      int = {:vbuiltin, :Int}
      val = {:vbuiltin, {:add, [{:vlit, 2}]}}
      assert Quote.quote(0, int, val) == {:app, {:builtin, :add}, {:lit, 2}}
    end

    test "pair without Sigma type is quoted structurally" do
      int = {:vbuiltin, :Int}
      val = {:vpair, {:vlit, 1}, {:vlit, 2}}
      result = Quote.quote(0, int, val)
      assert {:pair, {:lit, 1}, {:lit, 2}} = result
    end

    test "lambda without Pi type is quoted structurally" do
      int = {:vbuiltin, :Int}
      val = {:vlam, :omega, [], {:var, 0}}
      result = Quote.quote(0, int, val)
      assert {:lam, :omega, _} = result
    end

    test "extern is quoted" do
      int = {:vbuiltin, :Int}
      assert Quote.quote(0, int, {:vextern, Enum, :map, 2}) == {:extern, Enum, :map, 2}
    end

    test "neutral ndef is quoted" do
      int = {:vbuiltin, :Int}
      val = {:vneutral, int, {:ndef, :foo, [{:vlit, 1}]}}
      result = Quote.quote(0, int, val)
      assert {:app, {:builtin, :foo}, {:lit, 1}} = result
    end
  end

  describe "quote at Type — Pi and Sigma types" do
    test "Pi value quoted at Type" do
      int = {:vbuiltin, :Int}
      pi_val = {:vpi, :omega, int, [], {:builtin, :Int}}

      result = Quote.quote(0, {:vtype, {:llit, 1}}, pi_val)
      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = result
    end

    test "Sigma value quoted at Type" do
      int = {:vbuiltin, :Int}
      sigma_val = {:vsigma, int, [], {:builtin, :Int}}

      result = Quote.quote(0, {:vtype, {:llit, 1}}, sigma_val)
      assert {:sigma, {:builtin, :Int}, {:builtin, :Int}} = result
    end
  end

  # ============================================================================
  # Untyped readback
  # ============================================================================

  describe "quote_untyped/2" do
    test "literal" do
      assert Quote.quote_untyped(0, {:vlit, 42}) == {:lit, 42}
    end

    test "type" do
      assert Quote.quote_untyped(0, {:vtype, {:llit, 0}}) == {:type, {:llit, 0}}
    end

    test "builtin" do
      assert Quote.quote_untyped(0, {:vbuiltin, :Int}) == {:builtin, :Int}
    end

    test "neutral" do
      int = {:vbuiltin, :Int}
      assert Quote.quote_untyped(1, {:vneutral, int, {:nvar, 0}}) == {:var, 0}
    end

    test "pair" do
      val = {:vpair, {:vlit, 1}, {:vlit, 2}}
      assert Quote.quote_untyped(0, val) == {:pair, {:lit, 1}, {:lit, 2}}
    end

    test "lambda" do
      val = {:vlam, :omega, [], {:var, 0}}
      result = Quote.quote_untyped(0, val)
      assert {:lam, :omega, _} = result
    end

    test "pi" do
      int = {:vbuiltin, :Int}
      val = {:vpi, :omega, int, [], {:builtin, :Int}}
      result = Quote.quote_untyped(0, val)
      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = result
    end

    test "sigma" do
      int = {:vbuiltin, :Int}
      val = {:vsigma, int, [], {:builtin, :Int}}
      result = Quote.quote_untyped(0, val)
      assert {:sigma, {:builtin, :Int}, {:builtin, :Int}} = result
    end

    test "extern" do
      assert Quote.quote_untyped(0, {:vextern, Enum, :map, 2}) == {:extern, Enum, :map, 2}
    end

    test "partially applied builtin" do
      val = {:vbuiltin, {:add, [{:vlit, 2}]}}
      assert Quote.quote_untyped(0, val) == {:app, {:builtin, :add}, {:lit, 2}}
    end
  end

  # ============================================================================
  # NbE roundtrip
  # ============================================================================

  describe "NbE roundtrip" do
    test "literal roundtrips" do
      c = ctx()
      int = {:vbuiltin, :Int}

      val = Eval.eval(c, {:lit, 42})
      assert Quote.quote(0, int, val) == {:lit, 42}
    end

    test "identity function roundtrips" do
      c = ctx()
      int = {:vbuiltin, :Int}
      pi = {:vpi, :omega, int, [], {:builtin, :Int}}

      val = Eval.eval(c, {:lam, :omega, {:var, 0}})
      result = Quote.quote(0, pi, val)

      assert {:lam, :omega, {:var, 0}} = result
    end

    test "beta reduction through NbE" do
      c = ctx()
      int = {:vbuiltin, :Int}

      # (fn x -> x)(42) normalizes to 42.
      val = Eval.eval(c, {:app, {:lam, :omega, {:var, 0}}, {:lit, 42}})
      assert Quote.quote(0, int, val) == {:lit, 42}
    end

    test "arithmetic through NbE" do
      c = ctx()
      int = {:vbuiltin, :Int}

      # (fn x -> x + 1)(2) normalizes to 3.
      body = {:app, {:app, {:builtin, :add}, {:var, 0}}, {:lit, 1}}
      term = {:app, {:lam, :omega, body}, {:lit, 2}}

      val = Eval.eval(c, term)
      assert Quote.quote(0, int, val) == {:lit, 3}
    end

    test "NbE stability: quote(eval(quote(eval(t)))) == quote(eval(t)) for closed terms" do
      c = ctx()
      int = {:vbuiltin, :Int}

      term = {:app, {:app, {:builtin, :add}, {:lit, 2}}, {:lit, 3}}

      val1 = Eval.eval(c, term)
      nf1 = Quote.quote(0, int, val1)

      val2 = Eval.eval(c, nf1)
      nf2 = Quote.quote(0, int, val2)

      assert nf1 == nf2
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "level-to-index roundtrip: l - (l - lvl - 1) - 1 == lvl" do
      check all(
              l <- integer(1..1000),
              lvl <- integer(0..(l - 1))
            ) do
        ix = l - lvl - 1
        assert l - ix - 1 == lvl
      end
    end

    property "eta: quote(neutral_f, Pi(Int, Int)) is always Lam(...)" do
      check all(level <- integer(0..50)) do
        int = {:vbuiltin, :Int}
        pi = {:vpi, :omega, int, [], {:builtin, :Int}}
        f = {:vneutral, pi, {:nvar, level}}

        result = Quote.quote(level + 1, pi, f)
        assert {:lam, :omega, _} = result
      end
    end

    property "NbE stability for arithmetic" do
      check all(
              a <- integer(-100..100),
              b <- integer(-100..100)
            ) do
        c = ctx()
        int = {:vbuiltin, :Int}

        term = {:app, {:app, {:builtin, :add}, {:lit, a}}, {:lit, b}}

        val1 = Eval.eval(c, term)
        nf1 = Quote.quote(0, int, val1)

        val2 = Eval.eval(c, nf1)
        nf2 = Quote.quote(0, int, val2)

        assert nf1 == nf2
      end
    end
  end

  # ============================================================================
  # Coverage: quote_untyped for vdata
  # ============================================================================

  describe "quote_untyped — vdata" do
    test "vdata with args is read back as data term" do
      val = {:vdata, :Nat, [{:vlit, 42}]}
      result = Quote.quote_untyped(0, val)
      assert result == {:data, :Nat, [{:lit, 42}]}
    end

    test "vdata with no args" do
      val = {:vdata, :Bool, []}
      assert Quote.quote_untyped(0, val) == {:data, :Bool, []}
    end
  end

  # ============================================================================
  # Coverage: quote_untyped for vglobal
  # ============================================================================

  describe "quote_untyped — vglobal" do
    test "vglobal is read back as global term" do
      val = {:vglobal, MyMod, :my_fun, 2}
      assert Quote.quote_untyped(0, val) == {:global, MyMod, :my_fun, 2}
    end
  end

  # ============================================================================
  # Coverage: quote for vglobal (typed readback)
  # ============================================================================

  describe "quote — vglobal" do
    test "vglobal is read back as global term at any type" do
      int = {:vbuiltin, :Int}
      val = {:vglobal, MyMod, :my_fun, 2}
      assert Quote.quote(0, int, val) == {:global, MyMod, :my_fun, 2}
    end
  end

  # ============================================================================
  # Coverage: quote_neutral for ncase (__lit branch)
  # ============================================================================

  describe "quote — neutral case with __lit branch" do
    test "ncase with __lit branch is read back" do
      int = {:vbuiltin, :Int}
      ne = {:ncase, {:nvar, 0}, [{:__lit, 42, {[], {:lit, 1}}}, {:Foo, 1, {[], {:var, 0}}}]}
      val = {:vneutral, int, ne}
      result = Quote.quote(1, int, val)
      assert {:case, {:var, 0}, [{:__lit, 42, {:lit, 1}}, {:Foo, 1, {:var, 0}}]} = result
    end
  end
end
