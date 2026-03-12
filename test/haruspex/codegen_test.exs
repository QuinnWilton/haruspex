defmodule Haruspex.CodegenTest do
  use ExUnit.Case, async: true

  alias Haruspex.Codegen
  alias Haruspex.Erase

  # ============================================================================
  # Literal compilation
  # ============================================================================

  describe "literals" do
    test "integer" do
      assert Codegen.eval_expr({:lit, 42}) == 42
    end

    test "float" do
      assert Codegen.eval_expr({:lit, 3.14}) == 3.14
    end

    test "string" do
      assert Codegen.eval_expr({:lit, "hello"}) == "hello"
    end

    test "boolean" do
      assert Codegen.eval_expr({:lit, true}) == true
      assert Codegen.eval_expr({:lit, false}) == false
    end

    test "atom" do
      assert Codegen.eval_expr({:lit, :foo}) == :foo
    end
  end

  # ============================================================================
  # Variable compilation
  # ============================================================================

  describe "variables" do
    test "variable in lambda body" do
      # fn(x) -> x end — identity
      term = {:lam, :omega, {:var, 0}}
      fun = Codegen.eval_expr(term)

      assert fun.(42) == 42
      assert fun.("hello") == "hello"
    end

    test "nested variable reference" do
      # fn(x) -> fn(y) -> x end end — const
      term = {:lam, :omega, {:lam, :omega, {:var, 1}}}
      fun = Codegen.eval_expr(term)

      assert fun.(1).(2) == 1
    end
  end

  # ============================================================================
  # Lambda and application
  # ============================================================================

  describe "lambda and application" do
    test "lambda compiles to fn" do
      term = {:lam, :omega, {:var, 0}}
      ast = Codegen.compile_expr(term)

      # Should be a fn expression.
      assert {:fn, _, _} = ast
    end

    test "application compiles to function call" do
      # (fn(x) -> x end).(42)
      term = {:app, {:lam, :omega, {:var, 0}}, {:lit, 42}}

      assert Codegen.eval_expr(term) == 42
    end

    test "curried multi-arg function" do
      # fn(x) -> fn(y) -> x + y end end applied to 3 then 4
      add = {:lam, :omega, {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 1}}, {:var, 0}}}}
      term = {:app, {:app, add, {:lit, 3}}, {:lit, 4}}

      assert Codegen.eval_expr(term) == 7
    end
  end

  # ============================================================================
  # Let bindings
  # ============================================================================

  describe "let" do
    test "let binding" do
      # let x = 42 in x
      term = {:let, {:lit, 42}, {:var, 0}}

      assert Codegen.eval_expr(term) == 42
    end

    test "let with computation" do
      # let x = 10 in add(x, 5)
      term = {:let, {:lit, 10}, {:app, {:app, {:builtin, :add}, {:var, 0}}, {:lit, 5}}}

      assert Codegen.eval_expr(term) == 15
    end
  end

  # ============================================================================
  # Builtin compilation
  # ============================================================================

  describe "builtins" do
    test "fully-applied add is inlined" do
      term = {:app, {:app, {:builtin, :add}, {:lit, 1}}, {:lit, 2}}

      assert Codegen.eval_expr(term) == 3

      # Verify it's inlined (not using captures).
      ast = Codegen.compile_expr(term)
      refute match?({:., _, _}, ast)
    end

    test "fully-applied sub" do
      term = {:app, {:app, {:builtin, :sub}, {:lit, 10}}, {:lit, 3}}

      assert Codegen.eval_expr(term) == 7
    end

    test "fully-applied mul" do
      term = {:app, {:app, {:builtin, :mul}, {:lit, 6}}, {:lit, 7}}

      assert Codegen.eval_expr(term) == 42
    end

    test "fully-applied div" do
      term = {:app, {:app, {:builtin, :div}, {:lit, 10}}, {:lit, 3}}

      assert Codegen.eval_expr(term) == 3
    end

    test "fully-applied eq" do
      assert Codegen.eval_expr({:app, {:app, {:builtin, :eq}, {:lit, 1}}, {:lit, 1}}) == true
      assert Codegen.eval_expr({:app, {:app, {:builtin, :eq}, {:lit, 1}}, {:lit, 2}}) == false
    end

    test "fully-applied lt" do
      assert Codegen.eval_expr({:app, {:app, {:builtin, :lt}, {:lit, 1}}, {:lit, 2}}) == true
      assert Codegen.eval_expr({:app, {:app, {:builtin, :lt}, {:lit, 2}}, {:lit, 1}}) == false
    end

    test "fully-applied gt" do
      assert Codegen.eval_expr({:app, {:app, {:builtin, :gt}, {:lit, 2}}, {:lit, 1}}) == true
    end

    test "fully-applied neg" do
      assert Codegen.eval_expr({:app, {:builtin, :neg}, {:lit, 5}}) == -5
    end

    test "fully-applied not" do
      assert Codegen.eval_expr({:app, {:builtin, :not}, {:lit, true}}) == false
      assert Codegen.eval_expr({:app, {:builtin, :not}, {:lit, false}}) == true
    end

    test "fully-applied and" do
      assert Codegen.eval_expr({:app, {:app, {:builtin, :and}, {:lit, true}}, {:lit, false}}) ==
               false
    end

    test "fully-applied or" do
      assert Codegen.eval_expr({:app, {:app, {:builtin, :or}, {:lit, false}}, {:lit, true}}) ==
               true
    end

    test "unapplied builtin compiles to capture" do
      fun = Codegen.eval_expr({:builtin, :add})

      assert fun.(3, 4) == 7
    end

    test "partially-applied builtin compiles to closure" do
      # add(5) -> fn(b) -> 5 + b end
      fun = Codegen.eval_expr({:app, {:builtin, :add}, {:lit, 5}})

      assert is_function(fun, 1)
      assert fun.(3) == 8
    end
  end

  # ============================================================================
  # Extern compilation
  # ============================================================================

  describe "externs" do
    test "unapplied extern compiles to capture" do
      term = {:extern, :math, :sqrt, 1}
      fun = Codegen.eval_expr(term)

      assert fun.(4.0) == 2.0
    end

    test "fully-applied extern compiles to direct call" do
      term = {:app, {:extern, :math, :sqrt, 1}, {:lit, 9.0}}

      assert Codegen.eval_expr(term) == 3.0
    end

    test "fully-applied multi-arg extern" do
      term = {:app, {:app, {:extern, :math, :pow, 2}, {:lit, 2.0}}, {:lit, 10.0}}

      assert Codegen.eval_expr(term) == 1024.0
    end

    test "partially-applied multi-arg extern" do
      term = {:app, {:extern, :math, :pow, 2}, {:lit, 2.0}}
      fun = Codegen.eval_expr(term)

      assert is_function(fun, 1)
      assert fun.(10.0) == 1024.0
    end
  end

  # ============================================================================
  # Pair and projections
  # ============================================================================

  describe "pairs" do
    test "pair compiles to tuple" do
      term = {:pair, {:lit, 1}, {:lit, 2}}

      assert Codegen.eval_expr(term) == {1, 2}
    end

    test "fst extracts first element" do
      term = {:fst, {:pair, {:lit, 1}, {:lit, 2}}}

      assert Codegen.eval_expr(term) == 1
    end

    test "snd extracts second element" do
      term = {:snd, {:pair, {:lit, 1}, {:lit, 2}}}

      assert Codegen.eval_expr(term) == 2
    end
  end

  # ============================================================================
  # Erased nodes
  # ============================================================================

  describe "erased" do
    test "erased node compiles to nil" do
      ast = Codegen.compile_expr(:erased)

      assert ast == nil
    end
  end

  # ============================================================================
  # Module compilation
  # ============================================================================

  describe "compile_module" do
    test "simple function becomes def" do
      # def add(x : Int, y : Int) : Int do x + y end
      body =
        {:lam, :omega, {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 1}}, {:var, 0}}}}

      type = {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      ast = Codegen.compile_module(TestMod1, :all, [{:add, type, body}])
      Code.eval_quoted(ast)

      assert TestMod1.add(3, 4) == 7
    after
      :code.purge(TestMod1)
      :code.delete(TestMod1)
    end

    test "unexported function becomes defp" do
      # priv(x) = x + 1
      priv_body =
        {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 0}}, {:lit, 1}}}

      priv_type = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}

      # pub(x) = x * 2
      pub_body =
        {:lam, :omega, {:app, {:app, {:builtin, :mul}, {:var, 0}}, {:lit, 2}}}

      pub_type = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}

      ast =
        Codegen.compile_module(
          TestMod2,
          [:pub],
          [{:priv, priv_type, priv_body}, {:pub, pub_type, pub_body}]
        )

      Code.eval_quoted(ast)

      assert function_exported?(TestMod2, :pub, 1)
      refute function_exported?(TestMod2, :priv, 1)
    after
      :code.purge(TestMod2)
      :code.delete(TestMod2)
    end

    test "polymorphic identity erases type parameter" do
      # def id({a : Type}, x : a) : a do x end
      body = {:lam, :zero, {:lam, :omega, {:var, 0}}}
      type = {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 1}}}

      ast = Codegen.compile_module(TestMod3, :all, [{:id, type, body}])
      Code.eval_quoted(ast)

      # After erasure, id takes one argument.
      assert TestMod3.id(42) == 42
      assert TestMod3.id("hello") == "hello"
    after
      :code.purge(TestMod3)
      :code.delete(TestMod3)
    end

    test "multiple definitions in one module" do
      add_body =
        {:lam, :omega, {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 1}}, {:var, 0}}}}

      add_type =
        {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      neg_body = {:lam, :omega, {:app, {:builtin, :neg}, {:var, 0}}}
      neg_type = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}

      ast =
        Codegen.compile_module(TestMod4, :all, [
          {:add, add_type, add_body},
          {:negate, neg_type, neg_body}
        ])

      Code.eval_quoted(ast)

      assert TestMod4.add(1, 2) == 3
      assert TestMod4.negate(5) == -5
    after
      :code.purge(TestMod4)
      :code.delete(TestMod4)
    end
  end

  # ============================================================================
  # Integration: erase + codegen
  # ============================================================================

  describe "erase + codegen integration" do
    test "polymorphic const: two erased params" do
      # def const({a : Type}, {b : Type}, x : a, y : b) : a do x end
      body = {:lam, :zero, {:lam, :zero, {:lam, :omega, {:lam, :omega, {:var, 1}}}}}

      type =
        {:pi, :zero, {:type, {:llit, 0}},
         {:pi, :zero, {:type, {:llit, 0}},
          {:pi, :omega, {:var, 1}, {:pi, :omega, {:var, 1}, {:var, 3}}}}}

      erased = Erase.erase(body, type)
      fun = Codegen.eval_expr(erased)

      assert fun.(42).("ignored") == 42
    end
  end
end
