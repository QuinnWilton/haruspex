defmodule Haruspex.MutualTest do
  use ExUnit.Case, async: true

  alias Haruspex.Elaborate
  alias Haruspex.Mutual

  defp span, do: Pentiment.Span.Byte.new(0, 1)

  defp attrs, do: %{total: false, private: false, extern: nil}

  defp make_def(name, params, return_type, body) do
    s = span()
    sig = {:sig, s, name, s, params, return_type, attrs()}
    {:def, s, sig, body}
  end

  defp make_param(name, type_ast) do
    {:param, span(), {name, :omega, false}, type_ast}
  end

  defp int_var, do: {:var, span(), :Int}

  # ============================================================================
  # Signature collection
  # ============================================================================

  describe "collect_signatures" do
    test "collects single signature" do
      ctx = Elaborate.new()
      d = make_def(:f, [make_param(:x, int_var())], int_var(), {:var, span(), :x})

      assert {:ok, ctx, [{:f, type_core}]} = Mutual.collect_signatures(ctx, [d])
      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = type_core
      assert %Elaborate{} = ctx
    end

    test "collects multiple signatures" do
      ctx = Elaborate.new()

      d1 = make_def(:f, [make_param(:x, int_var())], int_var(), {:lit, span(), 0})
      d2 = make_def(:g, [make_param(:y, int_var())], int_var(), {:lit, span(), 0})

      assert {:ok, _ctx, [{:f, _}, {:g, _}]} = Mutual.collect_signatures(ctx, [d1, d2])
    end

    test "missing return type in signature produces error" do
      ctx = Elaborate.new()
      s = span()
      sig = {:sig, s, :f, s, [make_param(:x, int_var())], nil, attrs()}
      d = {:def, s, sig, {:lit, s, 0}}

      assert {:error, {:missing_return_type, :f, ^s}} = Mutual.collect_signatures(ctx, [d])
    end
  end

  # ============================================================================
  # Mutual elaboration
  # ============================================================================

  describe "elaborate_mutual" do
    test "single def through mutual machinery (self-recursion)" do
      ctx = Elaborate.new()
      s = span()

      # def f(x : Int) : Int do f(x) end
      body = {:app, s, {:var, s, :f}, [{:var, s, :x}]}
      d = make_def(:f, [make_param(:x, int_var())], int_var(), body)

      assert {:ok, [{:f, type_core, body_core}], _ctx} = Mutual.elaborate_mutual(ctx, [d])
      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = type_core
      # f is at index 1 (pushed as mutual name), x is at index 0 (pushed as param).
      assert {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} = body_core
    end

    test "mutual pair: both names in scope during body elaboration" do
      ctx = Elaborate.new()
      s = span()

      # def f(x : Int) : Int do g(x) end
      # def g(y : Int) : Int do f(y) end
      body_f = {:app, s, {:var, s, :g}, [{:var, s, :x}]}
      body_g = {:app, s, {:var, s, :f}, [{:var, s, :y}]}

      d_f = make_def(:f, [make_param(:x, int_var())], int_var(), body_f)
      d_g = make_def(:g, [make_param(:y, int_var())], int_var(), body_g)

      assert {:ok, results, _ctx} = Mutual.elaborate_mutual(ctx, [d_f, d_g])
      assert length(results) == 2

      [{:f, _, f_body}, {:g, _, g_body}] = results

      # In the mutual context: f is at level 0, g is at level 1.
      # For f's body: mutual context has f(level 0), g(level 1), then x(level 2).
      # Depth is 3. g = index 1, x = index 0.
      assert {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} = f_body

      # For g's body: mutual context has f(level 0), g(level 1), then y(level 2).
      # Depth is 3. f = index 2, y = index 0.
      assert {:lam, :omega, {:app, {:var, 2}, {:var, 0}}} = g_body
    end

    test "mutual elaboration threads meta state" do
      ctx = Elaborate.new()
      s = span()

      # Two defs whose bodies contain holes.
      body_f = {:hole, s}
      body_g = {:hole, s}

      d_f = make_def(:f, [make_param(:x, int_var())], int_var(), body_f)
      d_g = make_def(:g, [make_param(:y, int_var())], int_var(), body_g)

      assert {:ok, [{:f, _, {:lam, :omega, {:meta, id1}}}, {:g, _, {:lam, :omega, {:meta, id2}}}],
              ctx} =
               Mutual.elaborate_mutual(ctx, [d_f, d_g])

      assert id1 != id2
      assert ctx.meta_state.next_id == 2
    end

    test "mutual def with two params" do
      ctx = Elaborate.new()
      s = span()

      # def f(x : Int, y : Int) : Int do g(x) end
      # def g(z : Int) : Int do f(z, z) end
      body_f = {:app, s, {:var, s, :g}, [{:var, s, :x}]}
      body_g = {:app, s, {:var, s, :f}, [{:var, s, :z}, {:var, s, :z}]}

      d_f =
        make_def(:f, [make_param(:x, int_var()), make_param(:y, int_var())], int_var(), body_f)

      d_g = make_def(:g, [make_param(:z, int_var())], int_var(), body_g)

      assert {:ok, [{:f, f_type, f_body}, {:g, g_type, g_body}], _ctx} =
               Mutual.elaborate_mutual(ctx, [d_f, d_g])

      assert {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}} =
               f_type

      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = g_type

      # f body: mutual has f(0), g(1). Params: x(2), y(3). Depth=4.
      # g = index 2, x = index 1.
      assert {:lam, :omega, {:lam, :omega, {:app, {:var, 2}, {:var, 1}}}} = f_body

      # g body: mutual has f(0), g(1). Param: z(2). Depth=3.
      # f = index 2, z = index 0.
      assert {:lam, :omega, {:app, {:app, {:var, 2}, {:var, 0}}, {:var, 0}}} = g_body
    end

    test "three member mutual block" do
      ctx = Elaborate.new()
      s = span()

      # def f(x : Int) : Int do g(x) end
      # def g(x : Int) : Int do h(x) end
      # def h(x : Int) : Int do f(x) end
      body_f = {:app, s, {:var, s, :g}, [{:var, s, :x}]}
      body_g = {:app, s, {:var, s, :h}, [{:var, s, :x}]}
      body_h = {:app, s, {:var, s, :f}, [{:var, s, :x}]}

      d_f = make_def(:f, [make_param(:x, int_var())], int_var(), body_f)
      d_g = make_def(:g, [make_param(:x, int_var())], int_var(), body_g)
      d_h = make_def(:h, [make_param(:x, int_var())], int_var(), body_h)

      assert {:ok, results, _ctx} = Mutual.elaborate_mutual(ctx, [d_f, d_g, d_h])
      assert length(results) == 3

      [{:f, _, f_body}, {:g, _, g_body}, {:h, _, h_body}] = results

      # Mutual context: f(level 0), g(level 1), h(level 2). Each body adds param x.
      # For f's body: depth = 4 (3 mutual + 1 param). g is at level 1 => ix = 4-1-1 = 2. x => ix = 0.
      assert {:lam, :omega, {:app, {:var, 2}, {:var, 0}}} = f_body
      # For g's body: depth = 4. h is at level 2 => ix = 4-2-1 = 1. x => ix = 0.
      assert {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} = g_body
      # For h's body: depth = 4. f is at level 0 => ix = 4-0-1 = 3. x => ix = 0.
      assert {:lam, :omega, {:app, {:var, 3}, {:var, 0}}} = h_body
    end

    test "error in body propagates" do
      ctx = Elaborate.new()
      s = span()

      body = {:var, s, :unknown}
      d = make_def(:f, [make_param(:x, int_var())], int_var(), body)

      assert {:error, {:unbound_variable, :unknown, _}} = Mutual.elaborate_mutual(ctx, [d])
    end

    test "error in signature propagates" do
      ctx = Elaborate.new()
      s = span()

      # Param type references unbound name.
      bad_param = {:param, s, {:x, :omega, false}, {:var, s, :unknown}}
      sig = {:sig, s, :f, s, [bad_param], int_var(), attrs()}
      d = {:def, s, sig, {:lit, s, 0}}

      assert {:error, {:unbound_variable, :unknown, _}} = Mutual.collect_signatures(ctx, [d])
    end
  end

  # ============================================================================
  # Signature collection — edge cases
  # ============================================================================

  describe "collect_signatures — edge cases" do
    test "implicit parameter produces zero-mult pi" do
      ctx = Elaborate.new()
      s = span()
      implicit_param = {:param, s, {:a, :omega, true}, {:var, s, :Int}}
      d = make_def(:f, [implicit_param, make_param(:x, int_var())], int_var(), {:lit, s, 0})

      assert {:ok, _ctx, [{:f, type_core}]} = Mutual.collect_signatures(ctx, [d])

      assert {:pi, :zero, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}} =
               type_core
    end

    test "no-params def just elaborates return type" do
      ctx = Elaborate.new()
      d = make_def(:f, [], int_var(), {:lit, span(), 0})

      assert {:ok, _ctx, [{:f, {:builtin, :Int}}]} = Mutual.collect_signatures(ctx, [d])
    end
  end

  # ============================================================================
  # Cross-reference checking
  # ============================================================================

  describe "cross-reference checking" do
    test "mutual pair with cross-references returns empty" do
      # Both f and g reference each other.
      # n=2, k=1 (each has 1 lambda). f is at index 0, g is at index 1.
      # In f's body (stripped): g has ix = (2-1-1)+1 = 1. In g's body (stripped): f has ix = (2-1-0)+1 = 2.
      # But references_var? strips lambdas and adjusts, so we need the full body with lambdas.
      # f's body: {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} — g called with x.
      # g's body: {:lam, :omega, {:app, {:var, 2}, {:var, 0}}} — f called with y.
      results = [
        {:f, :type, {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      assert Mutual.check_cross_references(results, [:f, :g]) == []
    end

    test "single def returns empty (self-recursion is fine)" do
      results = [{:f, :type, {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}}]
      assert Mutual.check_cross_references(results, [:f]) == []
    end

    test "unreferenced sibling is reported" do
      # f calls g, but g does NOT call f (just returns x).
      # n=2, k=1 each. In g's body (stripped {:var, 0}): f would need ix = (2-1-0)+1 = 2. Not present.
      results = [
        {:f, :type, {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}},
        {:g, :type, {:lam, :omega, {:var, 0}}}
      ]

      unreferenced = Mutual.check_cross_references(results, [:f, :g])
      assert :f in unreferenced
    end

    test "cross-reference through let binding" do
      # f calls g via let: let z = g(x) in z.
      results = [
        {:f, :type, {:lam, :omega, {:let, {:app, {:var, 1}, {:var, 0}}, {:var, 0}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      assert Mutual.check_cross_references(results, [:f, :g]) == []
    end

    test "cross-reference through pi type" do
      # f references g in a pi type annotation.
      results = [
        {:f, :type,
         {:lam, :omega, {:pi, :omega, {:app, {:var, 1}, {:var, 0}}, {:builtin, :Int}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      assert Mutual.check_cross_references(results, [:f, :g]) == []
    end

    test "cross-reference through sigma type" do
      results = [
        {:f, :type, {:lam, :omega, {:sigma, {:app, {:var, 1}, {:var, 0}}, {:builtin, :Int}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      assert Mutual.check_cross_references(results, [:f, :g]) == []
    end

    test "no cross-reference through meta, lit, builtin, type" do
      # Bodies with only meta/lit/builtin/type — no cross-refs.
      results = [
        {:f, :type, {:lam, :omega, {:meta, 0}}},
        {:g, :type, {:lam, :omega, {:lit, 42}}}
      ]

      unreferenced = Mutual.check_cross_references(results, [:f, :g])
      assert :f in unreferenced
      assert :g in unreferenced
    end

    test "body with builtin returns no cross-ref" do
      results = [
        {:f, :type, {:lam, :omega, {:builtin, :Int}}},
        {:g, :type, {:lam, :omega, {:type, {:llit, 0}}}}
      ]

      unreferenced = Mutual.check_cross_references(results, [:f, :g])
      assert :f in unreferenced
      assert :g in unreferenced
    end

    test "body with nested lambda adjusts target" do
      # f body has 2 lambdas, so target for g shifts.
      # n=2, k=2 for f. g is at index 1, target = (2-1-1)+2 = 2.
      # inner body: {:app, {:var, 2}, {:var, 0}} references ix 2.
      results = [
        {:f, :type, {:lam, :omega, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      assert Mutual.check_cross_references(results, [:f, :g]) == []
    end

    test "three-member block with one unreferenced" do
      # f -> g, g -> h, h does NOT reference f or g.
      results = [
        {:f, :type, {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}},
        {:h, :type, {:lam, :omega, {:var, 0}}}
      ]

      unreferenced = Mutual.check_cross_references(results, [:f, :g, :h])
      # f is not referenced by any sibling (g refs h, h refs nothing).
      # Actually: g refs h (ix = (3-1-2)+1 = 1), h refs nothing.
      # f refs g: inner body {:app, {:var, 1}, {:var, 0}}, target for g = (3-1-1)+1 = 2. No, var 1 != 2.
      # Let me recalculate properly.
      # n=3, f at i=0, g at i=1, h at i=2. Each k=1.
      # For f's body (stripped): sibling g (j=1, i=0): target_ix = (3-1-0)+1 = 3. f calls {:var, 1} — not 3.
      # For f's body: sibling h (j=2, i=0): target_ix = (3-1-0)+1 = 3. Same — not 3.
      # So f is not referenced by g or h? Let me re-check the formula.
      # In sibling j's body, def i has target_ix = (n - 1 - i) + k_j.
      # g's body (j=1, k_j=1): def f (i=0) has target = (3-1-0)+1 = 3. g's inner calls {:var, 1} — doesn't ref f.
      # h's body (j=2, k_j=1): def f (i=0) has target = (3-1-0)+1 = 3. h's inner calls {:var, 0} — doesn't ref f.
      # So f IS unreferenced. Both g and h are also unreferenced by similar logic.
      # This is expected given the bodies.
      assert :f in unreferenced
    end

    test "cross-reference through inner lambda" do
      # f has 1 outer lambda. After stripping, inner body is {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}.
      # n=2. For def g (i=1): target_ix in f's stripped body = (2-1-1)+1 = 1.
      # references_var? on {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}, target=1:
      #   - hits lam clause: references_var?(body, target+1=2)
      #   - body is {:app, {:var, 2}, {:var, 0}}: var(2)==2? yes!
      # So f references g through the inner lambda.
      results = [
        {:f, :type, {:lam, :omega, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      assert Mutual.check_cross_references(results, [:f, :g]) == []
    end

    test "catch-all references_var? returns false for unknown terms" do
      # Some unknown term shape that doesn't match any pattern.
      results = [
        {:f, :type, {:lam, :omega, {:unknown_thing, 1, 2}}},
        {:g, :type, {:lam, :omega, {:app, {:var, 2}, {:var, 0}}}}
      ]

      unreferenced = Mutual.check_cross_references(results, [:f, :g])
      # f is referenced by g (via app {:var, 2}).
      # g is not referenced by f (unknown_thing doesn't match).
      assert :g in unreferenced
    end
  end
end
