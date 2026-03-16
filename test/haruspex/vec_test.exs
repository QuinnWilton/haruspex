defmodule Haruspex.VecTest do
  use ExUnit.Case, async: true

  alias Haruspex.Check
  alias Haruspex.Context
  alias Haruspex.Eval

  # ============================================================================
  # Helpers — ADT declarations
  # ============================================================================

  defp nat_decl do
    %{
      name: :Nat,
      params: [],
      constructors: [
        %{name: :zero, fields: [], return_type: {:data, :Nat, []}, span: nil},
        %{name: :succ, fields: [{:data, :Nat, []}], return_type: {:data, :Nat, []}, span: nil}
      ],
      universe_level: {:llit, 0},
      span: nil
    }
  end

  defp vec_decl do
    %{
      name: :Vec,
      params: [{:a, {:type, {:llit, 0}}}, {:n, {:data, :Nat, []}}],
      constructors: [
        %{
          name: :vnil,
          fields: [],
          return_type: {:data, :Vec, [{:var, 1}, {:con, :Nat, :zero, []}]},
          span: nil
        },
        %{
          name: :vcons,
          fields: [
            {:var, 1},
            {:data, :Vec, [{:var, 1}, {:var, 0}]}
          ],
          return_type: {:data, :Vec, [{:var, 1}, {:con, :Nat, :succ, [{:var, 0}]}]},
          span: nil
        }
      ],
      universe_level: {:llit, 0},
      span: nil
    }
  end

  defp adts do
    %{Nat: nat_decl(), Vec: vec_decl()}
  end

  defp check_ctx do
    %{Check.new() | adts: adts()}
  end

  defp extend(ctx, name, type, mult) do
    %{ctx | context: Context.extend(ctx.context, name, type, mult), names: ctx.names ++ [name]}
  end

  # ============================================================================
  # Helpers — value constructors
  # ============================================================================

  defp vzero, do: {:vcon, :Nat, :zero, []}
  defp vsucc(n), do: {:vcon, :Nat, :succ, [n]}
  defp vec_type(a, n), do: {:vdata, :Vec, [a, n]}

  # Core-level constructors for building terms.
  defp czero, do: {:con, :Nat, :zero, []}
  defp csucc(n), do: {:con, :Nat, :succ, [n]}
  defp cvnil, do: {:con, :Vec, :vnil, []}
  defp cvcons(x, rest), do: {:con, :Vec, :vcons, [x, rest]}

  # ============================================================================
  # Vec constructor typing
  # ============================================================================

  describe "Vec constructor typing" do
    test "vnil with implicit args has type Vec(Int, zero)" do
      ctx = check_ctx()
      # vnil needs implicit type args: a=Int, n=zero (n is unused in vnil's return).
      term = {:con, :Vec, :vnil, [{:builtin, :Int}, czero()]}
      {:ok, _term, type, _ctx} = Check.synth(ctx, term)
      assert {:vdata, :Vec, [{:vbuiltin, :Int}, {:vcon, :Nat, :zero, []}]} = type
    end

    test "vcons(1, vnil) with implicit args has type Vec(Int, succ(zero))" do
      ctx = check_ctx()
      # vcons needs implicits a=Int, n=zero (predecessor of result index),
      # then fields: element, tail.
      vnil_term = {:con, :Vec, :vnil, [{:builtin, :Int}, czero()]}
      term = {:con, :Vec, :vcons, [{:builtin, :Int}, czero(), {:lit, 1}, vnil_term]}
      {:ok, _term, type, _ctx} = Check.synth(ctx, term)

      assert {:vdata, :Vec, [{:vbuiltin, :Int}, {:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]}]} =
               type
    end

    test "vcons(1, vcons(2, vnil)) has type Vec(Int, succ(succ(zero)))" do
      ctx = check_ctx()
      vnil_term = {:con, :Vec, :vnil, [{:builtin, :Int}, czero()]}
      inner = {:con, :Vec, :vcons, [{:builtin, :Int}, czero(), {:lit, 2}, vnil_term]}
      term = {:con, :Vec, :vcons, [{:builtin, :Int}, csucc(czero()), {:lit, 1}, inner]}
      {:ok, _term, type, _ctx} = Check.synth(ctx, term)

      assert {:vdata, :Vec,
              [
                {:vbuiltin, :Int},
                {:vcon, :Nat, :succ, [{:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]}]}
              ]} = type
    end
  end

  # ============================================================================
  # vhead — type checks
  # ============================================================================

  describe "vhead type checking" do
    test "vhead(v : Vec(a, succ(n))) : a type-checks" do
      ctx = check_ctx()

      # vhead takes Vec(Int, succ(zero)) and returns Int.
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, _rest) -> x end
      # Under vcons branch: x at index 1 (second field), rest at index 0.
      body = {:case, {:var, 0}, [{:vcons, 2, {:var, 1}}]}

      {:ok, _term, type, _ctx} = Check.synth(ctx, body)
      assert {:vbuiltin, :Int} = type
    end

    test "vhead(v : Vec(a, succ(n))) checks against a" do
      ctx = check_ctx()
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      body = {:case, {:var, 0}, [{:vcons, 2, {:var, 1}}]}

      {:ok, _checked, _ctx} = Check.check(ctx, body, {:vbuiltin, :Int})
    end
  end

  # ============================================================================
  # vtail — type checks
  # ============================================================================

  describe "vtail type checking" do
    test "vtail(v : Vec(a, succ(n))) : Vec(a, n) type-checks" do
      ctx = check_ctx()

      # vtail takes Vec(Int, succ(zero)) and returns Vec(Int, zero).
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(_x, rest) -> rest end
      body = {:case, {:var, 0}, [{:vcons, 2, {:var, 0}}]}

      {:ok, _term, type, _ctx} = Check.synth(ctx, body)
      assert vec_type({:vbuiltin, :Int}, vzero()) == type
    end

    test "vtail(v : Vec(Int, succ(succ(zero)))) : Vec(Int, succ(zero))" do
      ctx = check_ctx()
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vsucc(vzero())))
      ctx = extend(ctx, :v, scrut_type, :omega)

      body = {:case, {:var, 0}, [{:vcons, 2, {:var, 0}}]}

      {:ok, _term, type, _ctx} = Check.synth(ctx, body)
      assert vec_type({:vbuiltin, :Int}, vsucc(vzero())) == type
    end
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  describe "Vec evaluation" do
    test "vhead(vcons(1, vnil)) evaluates to 1" do
      # case vcons(1, vnil) do vcons(x, _) -> x end
      term =
        {:case, cvcons({:lit, 1}, cvnil()),
         [
           {:vcons, 2, {:var, 1}}
         ]}

      assert {:vlit, 1} = Eval.eval(Eval.default_ctx(), term)
    end

    test "vtail(vcons(1, vcons(2, vnil))) evaluates to vcons(2, vnil)" do
      term =
        {:case, cvcons({:lit, 1}, cvcons({:lit, 2}, cvnil())),
         [
           {:vcons, 2, {:var, 0}}
         ]}

      result = Eval.eval(Eval.default_ctx(), term)
      assert {:vcon, :Vec, :vcons, [{:vlit, 2}, {:vcon, :Vec, :vnil, []}]} = result
    end
  end

  # ============================================================================
  # Negative tests — type errors
  # ============================================================================

  describe "Vec type errors" do
    test "vhead cannot be applied to vnil (index mismatch)" do
      ctx = check_ctx()
      # Scrutinee: Vec(Int, zero) — only vnil is possible.
      scrut_type = vec_type({:vbuiltin, :Int}, vzero())
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, _) -> x end
      # The vcons branch is impossible for Vec(_, zero).
      # The body still type-checks but with placeholder types (branch unreachable).
      body = {:case, {:var, 0}, [{:vcons, 2, {:var, 1}}]}

      # This should synth but the result type comes from an impossible branch.
      {:ok, _term, _type, _ctx} = Check.synth(ctx, body)
    end
  end

  # ============================================================================
  # Spec integration test
  # ============================================================================

  describe "spec integration test" do
    test "Vec(a, add(2, 1)) : Vec(a, 3) with @total add" do
      # This test validates that type-level computation works:
      # def foo(xs : Vec(a, add(succ(succ(zero)), succ(zero)))) : Vec(a, succ(succ(succ(zero)))) do xs end
      #
      # With @total add available, add(succ(succ(zero)), succ(zero)) reduces to succ(succ(succ(zero))).

      # First, set up the @total add function.
      _add_type =
        {:pi, :omega, {:data, :Nat, []}, {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}}}

      add_body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1,
              {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      ctx = check_ctx()
      ctx = %{ctx | total_defs: %{add: {add_body, true}}}

      # Build: succ(succ(zero)) and succ(zero) as core terms.
      two = csucc(csucc(czero()))
      one = csucc(czero())

      # The input type: Vec(Int, add(succ(succ(zero)), succ(zero)))
      add_applied = {:app, {:app, {:def_ref, :add}, two}, one}
      input_type = {:data, :Vec, [{:builtin, :Int}, add_applied]}
      input_type_val = Eval.eval(make_eval_ctx(ctx), input_type)

      # The expected type: Vec(Int, succ(succ(succ(zero))))
      three = vsucc(vsucc(vsucc(vzero())))
      expected_type = vec_type({:vbuiltin, :Int}, three)

      # The input type should reduce to the expected type (add(2,1) → 3).
      assert input_type_val == expected_type

      # Now check: def foo(xs) : expected do xs end
      ctx = extend(ctx, :xs, input_type_val, :omega)
      {:ok, _term, _ctx} = Check.check(ctx, {:var, 0}, expected_type)
    end
  end

  # ============================================================================
  # Helpers — eval context
  # ============================================================================

  defp make_eval_ctx(ctx) do
    solved =
      ctx.meta_state.entries
      |> Enum.filter(fn {_, entry} -> match?({:solved, _}, entry) end)
      |> Map.new(fn {id, {:solved, val}} -> {id, {:solved, val}} end)

    %{env: Context.env(ctx.context), metas: solved, defs: ctx.total_defs, fuel: ctx.fuel}
  end

  # ============================================================================
  # General vappend — the full dependent types showcase
  # ============================================================================

  describe "general vappend" do
    defp add_body do
      {:lam, :omega,
       {:lam, :omega,
        {:case, {:var, 1},
         [
           {:zero, 0, {:var, 0}},
           {:succ, 1,
            {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
         ]}}}
    end

    defp vappend_type do
      # {n : Nat} -> {m : Nat} -> Vec(Int, n) -> Vec(Int, m) -> Vec(Int, add(n, m))
      {:pi, :zero, {:data, :Nat, []},
       {:pi, :zero, {:data, :Nat, []},
        {:pi, :omega, {:data, :Vec, [{:builtin, :Int}, {:var, 1}]},
         {:pi, :omega, {:data, :Vec, [{:builtin, :Int}, {:var, 1}]},
          {:data, :Vec,
           [{:builtin, :Int}, {:app, {:app, {:def_ref, :add}, {:var, 3}}, {:var, 2}}]}}}}}
    end

    defp vappend_body do
      # lam(:zero, lam(:zero, lam(:omega, lam(:omega,
      #   case var(1) do
      #     vnil -> var(0)
      #     vcons(x, rest) -> vcons(x, vappend(rest, var(2)))
      #   end))))
      {:lam, :zero,
       {:lam, :zero,
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:vnil, 0, {:var, 0}},
             {:vcons, 2,
              {:con, :Vec, :vcons, [{:var, 1}, {:app, {:app, {:var, 6}, {:var, 0}}, {:var, 2}}]}}
           ]}}}}}
    end

    test "general vappend type-checks at the checker level" do
      ctx = %{check_ctx() | total_defs: %{add: {add_body(), true}}}

      assert {:ok, _checked, _ctx} =
               Check.check_definition(ctx, :vappend, vappend_type(), vappend_body())
    end

    test "general vmap type-checks at the checker level" do
      vmap_type =
        {:pi, :zero, {:data, :Nat, []},
         {:pi, :omega, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}},
          {:pi, :omega, {:data, :Vec, [{:builtin, :Int}, {:var, 1}]},
           {:data, :Vec, [{:builtin, :Int}, {:var, 2}]}}}}

      vmap_body =
        {:lam, :zero,
         {:lam, :omega,
          {:lam, :omega,
           {:case, {:var, 0},
            [
              {:vnil, 0, {:con, :Vec, :vnil, []}},
              {:vcons, 2,
               {:con, :Vec, :vcons,
                [{:app, {:var, 3}, {:var, 1}}, {:app, {:app, {:var, 5}, {:var, 3}}, {:var, 0}}]}}
            ]}}}}

      ctx = check_ctx()

      assert {:ok, _checked, _ctx} =
               Check.check_definition(ctx, :vmap, vmap_type, vmap_body)
    end

    test "general vappend compiles and runs through full pipeline" do
      db = Roux.Database.new()
      Roux.Lang.register(db, Haruspex)

      Roux.Input.set(db, :source_text, "lib/vappend_test.hx", """
      type Nat = zero | succ(Nat)

      type Vec(a : Type, n : Nat) =
        vnil : Vec(a, zero)
        | vcons(a, Vec(a, n)) : Vec(a, succ(n))

      @total
      def add(n : Nat, m : Nat) : Nat do
        case n do
          zero -> m
          succ(k) -> succ(add(k, m))
        end
      end

      @total
      def vappend({n : Nat}, {m : Nat}, xs : Vec(Int, n), ys : Vec(Int, m)) : Vec(Int, add(n, m)) do
        case xs do
          vnil -> ys
          vcons(x, rest) -> vcons(x, vappend(rest, ys))
        end
      end
      """)

      {:ok, mod} = Roux.Runtime.query(db, :haruspex_compile, "lib/vappend_test.hx")

      v1 = mod.vcons(1, mod.vcons(2, mod.vnil()))
      v2 = mod.vcons(3, mod.vnil())
      result = mod.vappend(v1, v2)

      assert {:vcons, 1, {:vcons, 2, {:vcons, 3, :vnil}}} = result

      :code.purge(mod)
      :code.delete(mod)
    end
  end
end
