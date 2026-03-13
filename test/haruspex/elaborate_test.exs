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

  # ============================================================================
  # Record literal with unknown record name
  # ============================================================================

  describe "record literal with unknown record name" do
    test "returns :unknown_record error" do
      ctx = Elaborate.new()
      s = span()

      # A record construction referencing a record name that was never registered.
      ast = {:record_construct, s, :UnknownRec, [{:x, {:lit, s, 1}}]}

      assert {:error, {:unknown_record, :UnknownRec, ^s}} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # ADT constructor with explicit return type annotation
  # ============================================================================

  describe "ADT constructor with explicit return type" do
    test "elaborates constructor with return type annotation" do
      source = "type Wrap(a : Type) = wrap(a) : Wrap(a)"
      {:ok, forms} = Haruspex.Parser.parse(source)
      ctx = Elaborate.new()

      result =
        Enum.reduce_while(forms, {:ok, nil, ctx}, fn
          {:type_decl, _, _, _, _} = td, {:ok, _, ctx} ->
            case Elaborate.elaborate_type_decl(ctx, td) do
              {:ok, decl, ctx} -> {:cont, {:ok, decl, ctx}}
              err -> {:halt, err}
            end

          _, acc ->
            {:cont, acc}
        end)

      assert {:ok, decl, _ctx} = result
      assert decl.name == :Wrap
      # The constructor should have a return_type that is not nil.
      [con] = decl.constructors
      assert con.return_type != nil
    end
  end

  # ============================================================================
  # collect_free_vars coverage (via auto-implicit resolution with various term shapes)
  # ============================================================================

  describe "auto-implicit resolution with varied type shapes" do
    test "free vars in pi type annotations trigger auto-implicit" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : a -> a) : a — pi type in parameter references `a`.
      sig =
        {:sig, s, :f, s,
         [
           {:param, s, {:x, :omega, false},
            {:pi, s, {:y, :omega, false}, {:var, s, :a}, {:var, s, :a}}}
         ], {:var, s, :a}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      # `a` should be prepended as an implicit param.
      assert length(params) == 2
      [{:param, _, {name, _, true}, _} | _] = params
      assert name == :a
    end

    test "free vars in sigma type annotations trigger auto-implicit" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : Sigma(y, a, a)) : a
      sig =
        {:sig, s, :f, s,
         [{:param, s, {:x, :omega, false}, {:sigma, s, :y, {:var, s, :a}, {:var, s, :a}}}],
         {:var, s, :a}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      assert length(params) == 2
      [{:param, _, {name, _, true}, _} | _] = params
      assert name == :a
    end

    test "free vars in applied type annotations trigger auto-implicit" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : List(a)) : a — application in type references `a`.
      sig =
        {:sig, s, :f, s,
         [{:param, s, {:x, :omega, false}, {:app, s, {:var, s, :List}, [{:var, s, :a}]}}],
         {:var, s, :a}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      assert length(params) == 2
      [{:param, _, {name, _, true}, _} | _] = params
      assert name == :a
    end

    test "type universe and literal type annotations have no free vars" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : Type) : Int — no free type vars.
      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:type_universe, s, 0}}],
         {:var, s, :Int}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      # No auto-implicit should be added.
      assert length(params) == 1
    end

    test "literal type annotation produces no free type vars" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : 42) : Int — literal in type annotation has no free vars.
      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:lit, s, 42}}], {:var, s, :Int},
         %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      # No auto-implicit should be added for a literal.
      assert length(params) == 1
    end

    test "unknown form in type annotation produces no free type vars" do
      ctx = Elaborate.new()
      s = span()

      decl = {:implicit_decl, s, [{:param, s, {:a, :omega, true}, {:type_universe, s, nil}}]}
      ctx = Elaborate.register_implicits(ctx, decl)

      # def f(x : some_unknown_form) : Int — unknown AST form falls through.
      sig =
        {:sig, s, :f, s, [{:param, s, {:x, :omega, false}, {:unknown_form, s, :stuff}}],
         {:var, s, :Int}, %{total: false, private: false, extern: nil}}

      def_ast = {:def, s, sig, {:var, s, :x}}

      resolved = Elaborate.resolve_auto_implicits(ctx, def_ast)
      {:def, _, {:sig, _, :f, _, params, _, _}, _} = resolved
      # No auto-implicit for unknown forms.
      assert length(params) == 1
    end
  end

  # ============================================================================
  # Record update with dependent fields (collect_free_vars coverage)
  # ============================================================================

  describe "record update with dependent fields" do
    defp elaborate_source(source) do
      {:ok, forms} = Haruspex.Parser.parse(source)
      ctx = Elaborate.new()

      Enum.reduce(forms, ctx, fn
        {:type_decl, _, _, _, _} = type_decl, ctx ->
          {:ok, _decl, ctx} = Elaborate.elaborate_type_decl(ctx, type_decl)
          ctx

        {:record_decl, _, _, _, _} = record_decl, ctx ->
          {:ok, _decl, ctx} = Elaborate.elaborate_record_decl(ctx, record_decl)
          ctx

        _, ctx ->
          ctx
      end)
    end

    test "record update elaborates and exercises collect_free_vars on field types" do
      # Create a record with a dependent field manually, then do a record update.
      # This exercises: elaborate_record_update -> check_dependent_field_updates
      #   -> field_type_dependencies -> collect_free_vars
      decl = %{
        name: :DepRec,
        params: [],
        # snd's type {:var, 0} depends on fst (de Bruijn var 0 refers to fst).
        fields: [{:fst, {:builtin, :Int}}, {:snd, {:var, 0}}],
        constructor_name: :mk_DepRec,
        span: nil
      }

      ctx = Elaborate.new()
      # Register the record and its ADT.
      adt = Haruspex.Record.record_to_adt(decl)

      ctx = %{
        ctx
        | records: Map.put(ctx.records, :DepRec, decl),
          adts: Map.put(ctx.adts, :DepRec, adt)
      }

      # Push a binding for the target variable.
      ctx = push_binding(ctx, :p)

      # Update only snd (does NOT depend on updated fields, so should succeed).
      update_ast =
        {:record_update, nil, :DepRec, {:var, nil, :p}, [{:snd, {:lit, nil, 99}}]}

      assert {:ok, core, _ctx} = Elaborate.elaborate(ctx, update_ast)
      assert {:case, {:var, 0}, [{:mk_DepRec, 2, {:con, :DepRec, :mk_DepRec, _}}]} = core
    end

    test "record update with various core term shapes in field types exercises collect_free_vars" do
      # Test collect_free_vars with different core term shapes:
      # :pi, :sigma, :app, :lam, :let, :data, :con, :meta, :erased, :type, :lit, :builtin
      decl = %{
        name: :Complex,
        params: [],
        fields: [
          {:a, {:builtin, :Int}},
          # b's type is a pi that references a (var 0).
          {:b, {:pi, :omega, {:var, 0}, {:builtin, :Int}}},
          # c's type is a sigma that references a (var 1 under pi).
          {:c, {:sigma, {:var, 1}, {:var, 0}}},
          # d's type is an application.
          {:d, {:app, {:var, 2}, {:var, 1}}},
          # e's type is a lambda.
          {:e, {:lam, :omega, {:var, 0}}},
          # f's type is a let.
          {:f, {:let, {:var, 3}, {:var, 0}}},
          # g's type is a data form.
          {:g, {:data, :Maybe, [{:var, 5}]}},
          # h's type is a con form.
          {:h, {:con, :Maybe, :Just, [{:var, 6}]}},
          # i's type has no free vars (meta, erased, type, lit, builtin).
          {:i, {:meta, 0}},
          {:j, {:erased}},
          {:k, {:type, {:llit, 0}}},
          {:l, {:lit, 42}},
          {:m, {:builtin, :Float}}
        ],
        constructor_name: :mk_Complex,
        span: nil
      }

      # Just updating i (no dependencies).
      updated_fields = MapSet.new([:i])

      # This exercises collect_free_vars on every branch.
      result = Elaborate.check_dependent_field_updates(decl, updated_fields, nil)
      assert :ok = result
    end

    test "record update with all fields updated on dependent record succeeds" do
      decl = %{
        name: :DepRec,
        params: [],
        fields: [{:fst, {:builtin, :Int}}, {:snd, {:var, 0}}],
        constructor_name: :mk_DepRec,
        span: nil
      }

      ctx = Elaborate.new()
      adt = Haruspex.Record.record_to_adt(decl)

      ctx = %{
        ctx
        | records: Map.put(ctx.records, :DepRec, decl),
          adts: Map.put(ctx.adts, :DepRec, adt)
      }

      ctx = push_binding(ctx, :p)

      # Update both fields — should succeed even though snd depends on fst.
      update_ast =
        {:record_update, nil, :DepRec, {:var, nil, :p},
         [{:fst, {:lit, nil, 1}}, {:snd, {:lit, nil, 2}}]}

      assert {:ok, _, _} = Elaborate.elaborate(ctx, update_ast)
    end

    test "record update with dependent field not updated produces error" do
      decl = %{
        name: :DepRec,
        params: [],
        fields: [{:fst, {:builtin, :Int}}, {:snd, {:var, 0}}],
        constructor_name: :mk_DepRec,
        span: nil
      }

      ctx = Elaborate.new()
      adt = Haruspex.Record.record_to_adt(decl)

      ctx = %{
        ctx
        | records: Map.put(ctx.records, :DepRec, decl),
          adts: Map.put(ctx.adts, :DepRec, adt)
      }

      ctx = push_binding(ctx, :p)

      # Update only fst but snd depends on fst — should fail.
      update_ast =
        {:record_update, nil, :DepRec, {:var, nil, :p}, [{:fst, {:lit, nil, 1}}]}

      assert {:error, {:dependent_field_not_updated, :DepRec, :snd, [:fst], _}} =
               Elaborate.elaborate(ctx, update_ast)
    end
  end

  # ============================================================================
  # Record pattern with unknown record
  # ============================================================================

  describe "record pattern with unknown record" do
    test "returns :unknown_record error" do
      ctx = Elaborate.new()
      s = span()

      # Case with a record pattern for an unregistered record.
      ast =
        {:case, s, {:lit, s, 42},
         [
           {:branch, s, {:pat_record, s, :UnknownRec, [{:x, {:pat_var, s, :x}}]}, {:var, s, :x}}
         ]}

      assert {:error, {:unknown_record, :UnknownRec, _}} = Elaborate.elaborate(ctx, ast)
    end
  end

  # ============================================================================
  # Literal sub-pattern in constructor
  # ============================================================================

  describe "literal sub-pattern in constructor" do
    test "literal inside constructor pattern is treated as binding" do
      source = "type Wrap = wrap(Int)"
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
      inner_ctx = push_binding(ctx, :val)

      # case val do wrap(42) -> 1 end — literal 42 as sub-pattern.
      ast =
        {:case, s, {:var, s, :val},
         [
           {:branch, s, {:pat_constructor, s, :wrap, [{:pat_lit, s, 42}]}, {:lit, s, 1}}
         ]}

      assert {:ok, {:case, {:var, 0}, [{:wrap, 1, {:lit, 1}}]}, _} =
               Elaborate.elaborate(inner_ctx, ast)
    end
  end

  # ============================================================================
  # Extern missing return type
  # ============================================================================

  describe "extern missing return type" do
    test "extern def without return type produces error" do
      ctx = Elaborate.new()
      s = span()

      sig =
        {:sig, s, :ext_fn, s, [{:param, s, {:x, :omega, false}, {:var, s, :Int}}], nil,
         %{total: false, private: false, extern: {Enum, :count, 1}}}

      def_ast = {:def, s, sig, nil}

      assert {:error, {:missing_return_type, :ext_fn, ^s}} =
               Elaborate.elaborate_def(ctx, def_ast)
    end
  end
end
