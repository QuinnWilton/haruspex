defmodule Haruspex.ElaborateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Elaborate

  defp span, do: Pentiment.Span.Byte.new(0, 1)

  defp push_binding(ctx, name) do
    # Mirror the internal push_binding for test setup.
    %{
      ctx
      | names: [{name, ctx.level} | ctx.names],
        name_list: ctx.name_list ++ [name],
        level: ctx.level + 1
    }
  end

  # ============================================================================
  # Name resolution
  # ============================================================================

  describe "name resolution" do
    test "single binding resolves to de Bruijn index 0" do
      ctx = Elaborate.new() |> push_binding(:x)
      assert {:ok, {:var, 0}, _} = Elaborate.elaborate(ctx, {:var, span(), :x})
    end

    test "two bindings: older gets higher index" do
      ctx = Elaborate.new() |> push_binding(:x) |> push_binding(:y)
      assert {:ok, {:var, 1}, _} = Elaborate.elaborate(ctx, {:var, span(), :x})
      assert {:ok, {:var, 0}, _} = Elaborate.elaborate(ctx, {:var, span(), :y})
    end

    test "shadowing: inner binding wins" do
      ctx = Elaborate.new() |> push_binding(:x) |> push_binding(:x)
      assert {:ok, {:var, 0}, _} = Elaborate.elaborate(ctx, {:var, span(), :x})
    end

    test "three bindings resolve correctly" do
      ctx = Elaborate.new() |> push_binding(:a) |> push_binding(:b) |> push_binding(:c)
      assert {:ok, {:var, 2}, _} = Elaborate.elaborate(ctx, {:var, span(), :a})
      assert {:ok, {:var, 1}, _} = Elaborate.elaborate(ctx, {:var, span(), :b})
      assert {:ok, {:var, 0}, _} = Elaborate.elaborate(ctx, {:var, span(), :c})
    end
  end

  # ============================================================================
  # Builtin resolution
  # ============================================================================

  describe "builtin resolution" do
    test "Int resolves to builtin" do
      ctx = Elaborate.new()
      assert {:ok, {:builtin, :Int}, _} = Elaborate.elaborate(ctx, {:var, span(), :Int})
    end

    test "add resolves to builtin" do
      ctx = Elaborate.new()
      assert {:ok, {:builtin, :add}, _} = Elaborate.elaborate(ctx, {:var, span(), :add})
    end

    test "Float resolves to builtin" do
      ctx = Elaborate.new()
      assert {:ok, {:builtin, :Float}, _} = Elaborate.elaborate(ctx, {:var, span(), :Float})
    end

    test "String resolves to builtin" do
      ctx = Elaborate.new()
      assert {:ok, {:builtin, :String}, _} = Elaborate.elaborate(ctx, {:var, span(), :String})
    end

    test "all arithmetic builtins resolve" do
      ctx = Elaborate.new()

      for op <- [:add, :sub, :mul, :div, :neg, :fadd, :fsub, :fmul, :fdiv] do
        assert {:ok, {:builtin, ^op}, _} = Elaborate.elaborate(ctx, {:var, span(), op})
      end
    end

    test "all comparison builtins resolve" do
      ctx = Elaborate.new()

      for op <- [:eq, :neq, :lt, :gt, :lte, :gte] do
        assert {:ok, {:builtin, ^op}, _} = Elaborate.elaborate(ctx, {:var, span(), op})
      end
    end

    test "boolean builtins resolve" do
      ctx = Elaborate.new()

      for op <- [:and, :or, :not] do
        assert {:ok, {:builtin, ^op}, _} = Elaborate.elaborate(ctx, {:var, span(), op})
      end
    end
  end

  # ============================================================================
  # Unbound variables
  # ============================================================================

  describe "unbound variable" do
    test "returns error with name and span" do
      ctx = Elaborate.new()
      s = span()

      assert {:error, {:unbound_variable, :unknown, ^s}} =
               Elaborate.elaborate(ctx, {:var, s, :unknown})
    end
  end

  # ============================================================================
  # Literals
  # ============================================================================

  describe "literals" do
    test "integer literal" do
      ctx = Elaborate.new()
      assert {:ok, {:lit, 42}, _} = Elaborate.elaborate(ctx, {:lit, span(), 42})
    end

    test "float literal" do
      ctx = Elaborate.new()
      assert {:ok, {:lit, 3.14}, _} = Elaborate.elaborate(ctx, {:lit, span(), 3.14})
    end

    test "string literal" do
      ctx = Elaborate.new()
      assert {:ok, {:lit, "hello"}, _} = Elaborate.elaborate(ctx, {:lit, span(), "hello"})
    end

    test "boolean literal" do
      ctx = Elaborate.new()
      assert {:ok, {:lit, true}, _} = Elaborate.elaborate(ctx, {:lit, span(), true})
      assert {:ok, {:lit, false}, _} = Elaborate.elaborate(ctx, {:lit, span(), false})
    end

    test "atom literal" do
      ctx = Elaborate.new()
      assert {:ok, {:lit, :foo}, _} = Elaborate.elaborate(ctx, {:lit, span(), :foo})
    end
  end

  # ============================================================================
  # Binary operators
  # ============================================================================

  describe "binary operators" do
    test "add desugars to double application" do
      ctx = Elaborate.new()
      s = span()
      ast = {:binop, s, :add, {:lit, s, 1}, {:lit, s, 2}}

      assert {:ok, {:app, {:app, {:builtin, :add}, {:lit, 1}}, {:lit, 2}}, _} =
               Elaborate.elaborate(ctx, ast)
    end

    test "sub desugars" do
      ctx = Elaborate.new()
      s = span()
      ast = {:binop, s, :sub, {:lit, s, 10}, {:lit, s, 3}}

      assert {:ok, {:app, {:app, {:builtin, :sub}, {:lit, 10}}, {:lit, 3}}, _} =
               Elaborate.elaborate(ctx, ast)
    end

    test "comparison desugars" do
      ctx = Elaborate.new()
      s = span()
      ast = {:binop, s, :eq, {:lit, s, 1}, {:lit, s, 2}}

      assert {:ok, {:app, {:app, {:builtin, :eq}, {:lit, 1}}, {:lit, 2}}, _} =
               Elaborate.elaborate(ctx, ast)
    end

    test "error in left operand propagates" do
      ctx = Elaborate.new()
      s = span()
      ast = {:binop, s, :add, {:var, s, :unknown}, {:lit, s, 2}}
      assert {:error, {:unbound_variable, :unknown, _}} = Elaborate.elaborate(ctx, ast)
    end

    test "error in right operand propagates" do
      ctx = Elaborate.new()
      s = span()
      ast = {:binop, s, :add, {:lit, s, 1}, {:var, s, :unknown}}
      assert {:error, {:unbound_variable, :unknown, _}} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Unary operators
  # ============================================================================

  describe "unary operators" do
    test "neg desugars to single application" do
      ctx = Elaborate.new()
      s = span()
      ast = {:unaryop, s, :neg, {:lit, s, 5}}
      assert {:ok, {:app, {:builtin, :neg}, {:lit, 5}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "not desugars" do
      ctx = Elaborate.new()
      s = span()
      ast = {:unaryop, s, :not, {:lit, s, true}}
      assert {:ok, {:app, {:builtin, :not}, {:lit, true}}, _} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Pipeline
  # ============================================================================

  describe "pipeline" do
    test "pipe applies right to left" do
      ctx = Elaborate.new() |> push_binding(:f)
      s = span()
      ast = {:pipe, s, {:lit, s, 1}, {:var, s, :f}}
      assert {:ok, {:app, {:var, 0}, {:lit, 1}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "pipe with builtin function" do
      ctx = Elaborate.new()
      s = span()
      ast = {:pipe, s, {:lit, s, 5}, {:var, s, :neg}}
      assert {:ok, {:app, {:builtin, :neg}, {:lit, 5}}, _} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Lambda
  # ============================================================================

  describe "lambda" do
    test "single param lambda" do
      ctx = Elaborate.new()
      s = span()
      ast = {:fn, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], {:var, s, :x}}
      assert {:ok, {:lam, :omega, {:var, 0}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "multi param lambda nests" do
      ctx = Elaborate.new()
      s = span()

      ast =
        {:fn, s,
         [
           {:param, s, {:x, :omega, false}, {:var, s, :Int}},
           {:param, s, {:y, :omega, false}, {:var, s, :Int}}
         ], {:var, s, :x}}

      assert {:ok, {:lam, :omega, {:lam, :omega, {:var, 1}}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "lambda body references outer binding" do
      ctx = Elaborate.new() |> push_binding(:z)
      s = span()
      ast = {:fn, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], {:var, s, :z}}
      assert {:ok, {:lam, :omega, {:var, 1}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "zero-multiplicity lambda" do
      ctx = Elaborate.new()
      s = span()
      ast = {:fn, s, [{:param, s, {:x, :zero, false}, {:var, s, :Int}}], {:lit, s, 42}}
      assert {:ok, {:lam, :zero, {:lit, 42}}, _} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Let
  # ============================================================================

  describe "let" do
    test "let binding is in scope for body" do
      ctx = Elaborate.new()
      s = span()
      ast = {:let, s, :x, {:lit, s, 42}, {:var, s, :x}}
      assert {:ok, {:let, {:lit, 42}, {:var, 0}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "let binding shadows outer" do
      ctx = Elaborate.new() |> push_binding(:x)
      s = span()
      ast = {:let, s, :x, {:lit, s, 99}, {:var, s, :x}}
      assert {:ok, {:let, {:lit, 99}, {:var, 0}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "outer binding accessible from let value" do
      ctx = Elaborate.new() |> push_binding(:y)
      s = span()
      ast = {:let, s, :x, {:var, s, :y}, {:var, s, :x}}
      assert {:ok, {:let, {:var, 0}, {:var, 0}}, _} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Holes
  # ============================================================================

  describe "holes" do
    test "hole produces meta and records hole info" do
      ctx = Elaborate.new()
      s = span()
      assert {:ok, {:meta, 0}, ctx} = Elaborate.elaborate(ctx, {:hole, s})
      assert [%{meta_id: 0, span: ^s}] = ctx.holes
    end

    test "multiple holes get distinct meta IDs" do
      ctx = Elaborate.new()
      s = span()
      {:ok, {:meta, id1}, ctx} = Elaborate.elaborate(ctx, {:hole, s})
      {:ok, {:meta, id2}, _ctx} = Elaborate.elaborate(ctx, {:hole, s})
      assert id1 != id2
    end
  end

  # ============================================================================
  # Type universe
  # ============================================================================

  describe "type universe" do
    test "nil level produces fresh level variable" do
      ctx = Elaborate.new()

      assert {:ok, {:type, {:lvar, 0}}, ctx} =
               Elaborate.elaborate_type(ctx, {:type_universe, span(), nil})

      # Second call gets a distinct level var.
      assert {:ok, {:type, {:lvar, 1}}, _} =
               Elaborate.elaborate_type(ctx, {:type_universe, span(), nil})
    end

    test "explicit level 0" do
      ctx = Elaborate.new()

      assert {:ok, {:type, {:llit, 0}}, _} =
               Elaborate.elaborate_type(ctx, {:type_universe, span(), 0})
    end

    test "explicit level 3" do
      ctx = Elaborate.new()

      assert {:ok, {:type, {:llit, 3}}, _} =
               Elaborate.elaborate_type(ctx, {:type_universe, span(), 3})
    end
  end

  # ============================================================================
  # Pi type
  # ============================================================================

  describe "pi type" do
    test "non-dependent pi" do
      ctx = Elaborate.new()
      s = span()
      ast = {:pi, s, {:x, :omega, false}, {:var, s, :Int}, {:var, s, :Int}}

      assert {:ok, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}, _} =
               Elaborate.elaborate_type(ctx, ast)
    end

    test "dependent pi — codomain references bound variable" do
      ctx = Elaborate.new()
      s = span()
      ast = {:pi, s, {:x, :omega, false}, {:var, s, :Int}, {:var, s, :x}}

      assert {:ok, {:pi, :omega, {:builtin, :Int}, {:var, 0}}, _} =
               Elaborate.elaborate_type(ctx, ast)
    end

    test "implicit pi uses :zero multiplicity" do
      ctx = Elaborate.new()
      s = span()
      ast = {:pi, s, {:a, :omega, true}, {:type_universe, s, nil}, {:var, s, :a}}

      assert {:ok, {:pi, :zero, {:type, {:lvar, _}}, {:var, 0}}, _} =
               Elaborate.elaborate_type(ctx, ast)
    end
  end

  # ============================================================================
  # Sigma type
  # ============================================================================

  describe "sigma type" do
    test "non-dependent sigma" do
      ctx = Elaborate.new()
      s = span()
      ast = {:sigma, s, :x, {:var, s, :Int}, {:var, s, :Int}}

      assert {:ok, {:sigma, {:builtin, :Int}, {:builtin, :Int}}, _} =
               Elaborate.elaborate_type(ctx, ast)
    end

    test "dependent sigma — second type references first" do
      ctx = Elaborate.new()
      s = span()
      ast = {:sigma, s, :x, {:var, s, :Int}, {:var, s, :x}}

      assert {:ok, {:sigma, {:builtin, :Int}, {:var, 0}}, _} =
               Elaborate.elaborate_type(ctx, ast)
    end
  end

  # ============================================================================
  # Application
  # ============================================================================

  describe "application" do
    test "single argument" do
      ctx = Elaborate.new() |> push_binding(:f)
      s = span()
      ast = {:app, s, {:var, s, :f}, [{:lit, s, 1}]}

      assert {:ok, {:app, {:var, 0}, {:lit, 1}}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "multi argument folds left" do
      ctx = Elaborate.new() |> push_binding(:f)
      s = span()
      ast = {:app, s, {:var, s, :f}, [{:lit, s, 1}, {:lit, s, 2}]}

      assert {:ok, {:app, {:app, {:var, 0}, {:lit, 1}}, {:lit, 2}}, _} =
               Elaborate.elaborate(ctx, ast)
    end

    test "no arguments returns function" do
      ctx = Elaborate.new() |> push_binding(:f)
      s = span()
      ast = {:app, s, {:var, s, :f}, []}
      assert {:ok, {:var, 0}, _} = Elaborate.elaborate(ctx, ast)
    end

    test "error in function position propagates" do
      ctx = Elaborate.new()
      s = span()
      ast = {:app, s, {:var, s, :unknown}, [{:lit, s, 1}]}
      assert {:error, {:unbound_variable, :unknown, _}} = Elaborate.elaborate(ctx, ast)
    end

    test "error in argument propagates" do
      ctx = Elaborate.new() |> push_binding(:f)
      s = span()
      ast = {:app, s, {:var, s, :f}, [{:var, s, :unknown}]}
      assert {:error, {:unbound_variable, :unknown, _}} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Annotation
  # ============================================================================

  describe "annotation" do
    test "elaborates expression and type, returns expression" do
      ctx = Elaborate.new()
      s = span()
      ast = {:ann, s, {:lit, s, 42}, {:var, s, :Int}}
      assert {:ok, {:lit, 42}, _} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # If desugaring
  # ============================================================================

  describe "if expression" do
    test "desugars to case on true/false" do
      ctx = Elaborate.new()
      s = span()
      ast = {:if, s, {:lit, s, true}, {:lit, s, 1}, {:lit, s, 2}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)

      # Should produce: case true do true -> 1; false -> 2 end
      assert {:case, {:lit, true}, [{:__lit, true, {:lit, 1}}, {:__lit, false, {:lit, 2}}]} = core
    end
  end

  # ============================================================================
  # Nullary constructor pattern resolution
  # ============================================================================

  describe "nullary constructor in case pattern" do
    test "bare identifier resolves as constructor, not variable" do
      source = "type Nat = zero | succ(Nat)"
      {:ok, forms} = Haruspex.Parser.parse(source)
      ctx = Elaborate.new()

      ctx =
        Enum.reduce(forms, ctx, fn
          {:type_decl, _, _, _, _} = td, ctx ->
            {:ok, _decl, ctx} = Elaborate.elaborate_type_decl(ctx, td)
            ctx

          _, ctx ->
            ctx
        end)

      s = span()

      # case n do zero -> 1; succ(m) -> 2 end
      # "zero" should elaborate as {:zero, 0, ...} not {:_, 1, ...}
      ast =
        {:case, s, {:var, s, :n},
         [
           {:branch, s, {:pat_var, s, :zero}, {:lit, s, 1}},
           {:branch, s, {:pat_constructor, s, :succ, [{:pat_var, s, :m}]}, {:lit, s, 2}}
         ]}

      inner_ctx = push_binding(ctx, :n)
      {:ok, core, _ctx} = Elaborate.elaborate(inner_ctx, ast)

      assert {:case, {:var, 0}, [{:zero, 0, {:lit, 1}}, {:succ, 1, {:lit, 2}}]} = core
    end

    test "non-constructor bare identifier still elaborates as variable pattern" do
      ctx = Elaborate.new()
      s = span()

      # Without any ADTs, "x" should be a variable pattern.
      ast =
        {:case, s, {:lit, s, 42},
         [
           {:branch, s, {:pat_var, s, :x}, {:var, s, :x}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:case, {:lit, 42}, [{:_, 1, {:var, 0}}]} = core
    end
  end

  # ============================================================================
  # Def elaboration
  # ============================================================================

  describe "def elaboration" do
    test "simple identity function" do
      ctx = Elaborate.new()
      s = span()

      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], {:var, s, :Int},
         %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      assert {:ok, {:f, type_core, body_core}, _} = Elaborate.elaborate_def(ctx, def_ast)
      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = type_core
      assert {:lam, :omega, {:var, 0}} = body_core
    end

    test "self-recursive def: name is in scope in body" do
      ctx = Elaborate.new()
      s = span()

      # def f(x : Int) : Int do f(x) end
      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], {:var, s, :Int},
         %{total: false, private: false, extern: nil}}

      body = {:app, s, {:var, s, :f}, [{:var, s, :x}]}
      def_ast = {:def, s, sig, body}

      assert {:ok, {:f, _type_core, body_core}, _} = Elaborate.elaborate_def(ctx, def_ast)
      # In the body: f is at level 0 (pushed first), x at level 1 (pushed second).
      # Body depth is 2: x has index 0, f has index 1.
      assert {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} = body_core
    end

    test "two param def" do
      ctx = Elaborate.new()
      s = span()

      sig =
        {:sig, s, :add2, s,
         [
           {:param, s, {:x, :omega, false}, {:var, s, :Int}},
           {:param, s, {:y, :omega, false}, {:var, s, :Int}}
         ], {:var, s, :Int}, %{total: false, private: false, extern: nil}}

      # Body references both params via binop.
      body = {:binop, s, :add, {:var, s, :x}, {:var, s, :y}}
      def_ast = {:def, s, sig, body}

      assert {:ok, {:add2, type_core, body_core}, _} = Elaborate.elaborate_def(ctx, def_ast)

      assert {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}} =
               type_core

      # In body: add2 at depth offset 0 from base, x at 1, y at 2.
      # Total depth is 3. x=index 1, y=index 0.
      assert {:lam, :omega,
              {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 1}}, {:var, 0}}}} = body_core
    end

    test "missing return type produces error" do
      ctx = Elaborate.new()
      s = span()

      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], nil,
         %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      assert {:error, {:missing_return_type, :f, ^s}} = Elaborate.elaborate_def(ctx, def_ast)
    end
  end

  # ============================================================================
  # Auto-implicits registration
  # ============================================================================

  describe "auto-implicits" do
    test "register_implicits adds to context" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      assert Map.has_key?(ctx.auto_implicits, :a)
    end
  end

  # ============================================================================
  # Meta state threading
  # ============================================================================

  describe "meta state threading" do
    test "holes accumulate across elaborations" do
      ctx = Elaborate.new()
      s = span()

      {:ok, _, ctx} = Elaborate.elaborate(ctx, {:hole, s})
      {:ok, _, ctx} = Elaborate.elaborate(ctx, {:hole, s})
      {:ok, _, ctx} = Elaborate.elaborate(ctx, {:hole, s})

      assert length(ctx.holes) == 3
      assert ctx.meta_state.next_id == 3
    end

    test "level vars accumulate across type elaborations" do
      ctx = Elaborate.new()
      s = span()

      {:ok, {:type, {:lvar, 0}}, ctx} = Elaborate.elaborate_type(ctx, {:type_universe, s, nil})
      {:ok, {:type, {:lvar, 1}}, ctx} = Elaborate.elaborate_type(ctx, {:type_universe, s, nil})
      assert ctx.next_level_var == 2
    end
  end

  # ============================================================================
  # Type expressions used as regular expressions
  # ============================================================================

  describe "type expressions via elaborate/2" do
    test "pi type via elaborate falls through to elaborate_type" do
      ctx = Elaborate.new()
      s = span()
      ast = {:pi, s, {:x, :omega, false}, {:var, s, :Int}, {:var, s, :Int}}

      assert {:ok, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}, _} =
               Elaborate.elaborate(ctx, ast)
    end

    test "sigma type via elaborate falls through" do
      ctx = Elaborate.new()
      s = span()
      ast = {:sigma, s, :x, {:var, s, :Int}, {:var, s, :Int}}

      assert {:ok, {:sigma, {:builtin, :Int}, {:builtin, :Int}}, _} =
               Elaborate.elaborate(ctx, ast)
    end

    test "type universe via elaborate falls through" do
      ctx = Elaborate.new()
      ast = {:type_universe, span(), 0}
      assert {:ok, {:type, {:llit, 0}}, _} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Auto-implicit resolution
  # ============================================================================

  describe "auto-implicit resolution" do
    test "prepends implicit param for free type variable" do
      ctx = Elaborate.new()
      s = span()

      # Register `a` as auto-implicit with type `Type`.
      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : a) : a do x end — `a` is free, matches auto-implicit.
      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:var, s, :a}}], {:var, s, :a},
         %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      assert length(params) == 2
      [{:param, _, {name, _, implicit?}, _} | _] = params
      assert name == :a
      assert implicit? == true
    end

    test "does not prepend for already-explicit params" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(a : Type, x : a) : a do x end — `a` is already a param.
      sig =
        {:sig, s, :f, s,
         [
           {:param, s, {:a, :omega, false}, {:type_universe, s, nil}},
           {:param, s, {:x, :omega, false}, {:var, s, :a}}
         ], {:var, s, :a}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      assert length(params) == 2
    end

    test "does not prepend for builtins" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:Int, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], {:var, s, :Int},
         %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      assert length(params) == 1
    end

    test "preserves order of first occurrence" do
      ctx = Elaborate.new()
      s = span()

      decl =
        {:implicit_decl, s,
         [
           {:param, s, {:a, :omega, true}, {:type_universe, s, nil}},
           {:param, s, {:b, :omega, true}, {:type_universe, s, nil}}
         ]}

      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : b, y : a) : a — b appears first, then a.
      sig =
        {:sig, s, :f, s,
         [
           {:param, s, {:x, :omega, false}, {:var, s, :b}},
           {:param, s, {:y, :omega, false}, {:var, s, :a}}
         ], {:var, s, :a}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      assert length(params) == 4
      [first, second | _] = params
      {:param, _, {name1, _, true}, _} = first
      {:param, _, {name2, _, true}, _} = second
      assert name1 == :b
      assert name2 == :a
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "well-scoped: all var indices less than context depth" do
      check all(
              depth <- integer(1..10),
              target <- integer(0..(depth - 1))
            ) do
        # Build a context with `depth` bindings.
        ctx =
          Enum.reduce(0..(depth - 1), Elaborate.new(), fn i, acc ->
            push_binding(acc, :"x#{i}")
          end)

        name = :"x#{target}"
        {:ok, {:var, ix}, _} = Elaborate.elaborate(ctx, {:var, span(), name})
        assert ix < depth
      end
    end

    property "determinism: same input produces same output" do
      check all(n <- integer()) do
        ctx = Elaborate.new()
        s = span()
        ast = {:lit, s, n}
        {:ok, result1, _} = Elaborate.elaborate(ctx, ast)
        {:ok, result2, _} = Elaborate.elaborate(ctx, ast)
        assert result1 == result2
      end
    end

    property "every meta in output has a corresponding MetaState entry" do
      check all(n <- integer(0..5)) do
        ctx = Elaborate.new()
        s = span()

        {meta_ids, ctx} =
          if n == 0 do
            {[], ctx}
          else
            Enum.reduce(1..n, {[], ctx}, fn _, {ids, c} ->
              {:ok, {:meta, id}, c} = Elaborate.elaborate(c, {:hole, s})
              {[id | ids], c}
            end)
          end

        for id <- meta_ids do
          entry = Haruspex.Unify.MetaState.lookup(ctx.meta_state, id)
          assert entry != nil
        end
      end
    end

    property "binop elaboration preserves operand order" do
      check all(
              a <- integer(),
              b <- integer()
            ) do
        ctx = Elaborate.new()
        s = span()
        ast = {:binop, s, :add, {:lit, s, a}, {:lit, s, b}}

        {:ok, {:app, {:app, {:builtin, :add}, {:lit, left}}, {:lit, right}}, _} =
          Elaborate.elaborate(ctx, ast)

        assert left == a
        assert right == b
      end
    end
  end
end
