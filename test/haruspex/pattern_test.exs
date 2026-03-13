defmodule Haruspex.PatternTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Check
  alias Haruspex.Codegen
  alias Haruspex.Elaborate
  alias Haruspex.Erase
  alias Haruspex.Eval
  alias Haruspex.Parser
  alias Haruspex.Pattern

  # ============================================================================
  # Helpers
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

  defp option_decl do
    %{
      name: :Option,
      params: [{:a, {:type, {:llit, 0}}}],
      constructors: [
        %{name: :none, fields: [], return_type: {:data, :Option, [{:var, 0}]}, span: nil},
        %{name: :some, fields: [{:var, 0}], return_type: {:data, :Option, [{:var, 0}]}, span: nil}
      ],
      universe_level: {:lsucc, {:llit, 0}},
      span: nil
    }
  end

  defp check_ctx(adts) do
    %{Check.new() | adts: adts}
  end

  defp eval_ctx, do: Eval.default_ctx()

  # Elaborate source, registering type decls.
  defp elaborate_source(source) do
    {:ok, forms} = Parser.parse(source)
    ctx = Elaborate.new()

    Enum.reduce(forms, ctx, fn
      {:type_decl, _, _, _, _} = type_decl, ctx ->
        {:ok, _decl, ctx} = Elaborate.elaborate_type_decl(ctx, type_decl)
        ctx

      _, ctx ->
        ctx
    end)
  end

  # ============================================================================
  # Wildcard branches
  # ============================================================================

  describe "wildcard branches" do
    test "eval: wildcard matches any constructor" do
      # case zero do _ -> 42 end
      term =
        {:case, {:con, :Nat, :zero, []},
         [
           {:_, 1, {:lit, 42}}
         ]}

      assert {:vlit, 42} = Eval.eval(eval_ctx(), term)
    end

    test "eval: wildcard with variable binding" do
      # case succ(zero) do n -> n end
      # The wildcard binds the scrutinee at index 0.
      term =
        {:case, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]},
         [
           {:_, 1, {:var, 0}}
         ]}

      result = Eval.eval(eval_ctx(), term)
      assert {:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]} = result
    end

    test "codegen: wildcard with arity 0" do
      term = {:case, {:lit, 1}, [{:_, 0, {:lit, 99}}]}
      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert 99 = result
    end

    test "codegen: wildcard with arity 1 binds scrutinee" do
      # case 42 do n -> n end
      term = {:case, {:lit, 42}, [{:_, 1, {:var, 0}}]}
      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert 42 = result
    end

    test "constructor fallback to wildcard" do
      # case succ(zero) do zero -> 0; _ -> 1 end
      term =
        {:case, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]},
         [
           {:zero, 0, {:lit, 0}},
           {:_, 1, {:lit, 1}}
         ]}

      assert {:vlit, 1} = Eval.eval(eval_ctx(), term)
    end

    test "codegen: mixed constructor + wildcard" do
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [
           {:none, 0, {:lit, 0}},
           {:_, 1, {:lit, 1}}
         ]}

      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert 1 = result
    end
  end

  # ============================================================================
  # Literal branches
  # ============================================================================

  describe "literal branches" do
    test "eval: literal match" do
      # case 42 do 0 -> "zero"; 42 -> "forty-two"; _ -> "other" end
      term =
        {:case, {:lit, 42},
         [
           {:__lit, 0, {:lit, "zero"}},
           {:__lit, 42, {:lit, "forty-two"}},
           {:_, 1, {:lit, "other"}}
         ]}

      assert {:vlit, "forty-two"} = Eval.eval(eval_ctx(), term)
    end

    test "eval: literal fallback to wildcard" do
      term =
        {:case, {:lit, 99},
         [
           {:__lit, 0, {:lit, "zero"}},
           {:_, 1, {:lit, "other"}}
         ]}

      assert {:vlit, "other"} = Eval.eval(eval_ctx(), term)
    end

    test "eval: literal wildcard binds scrutinee" do
      # case 7 do 0 -> 0; n -> n end
      term =
        {:case, {:lit, 7},
         [
           {:__lit, 0, {:lit, 0}},
           {:_, 1, {:var, 0}}
         ]}

      assert {:vlit, 7} = Eval.eval(eval_ctx(), term)
    end

    test "codegen: literal patterns" do
      term =
        {:case, {:lit, 42},
         [
           {:__lit, 0, {:lit, "zero"}},
           {:__lit, 42, {:lit, "forty-two"}},
           {:_, 0, {:lit, "other"}}
         ]}

      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert "forty-two" = result
    end

    test "codegen: literal fallback to wildcard" do
      term =
        {:case, {:lit, 99},
         [
           {:__lit, 0, {:lit, "zero"}},
           {:_, 0, {:lit, "other"}}
         ]}

      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert "other" = result
    end

    test "erasure: literal branch passes through" do
      term =
        {:case, {:lit, 42},
         [
           {:__lit, 0, {:lit, "zero"}},
           {:_, 0, {:lit, "other"}}
         ]}

      erased = Erase.erase(term, {:builtin, :String})

      assert {:case, {:lit, 42},
              [
                {:__lit, 0, {:lit, "zero"}},
                {:_, 0, {:lit, "other"}}
              ]} = erased
    end
  end

  # ============================================================================
  # Type refinement
  # ============================================================================

  describe "type refinement" do
    test "constructor fields get actual types from ADT" do
      ctx = check_ctx(%{Nat: nat_decl()})

      # case zero do zero -> 1; succ(n) -> n end
      # In the succ branch, n should have type Nat (not placeholder).
      term =
        {:case, {:con, :Nat, :zero, []},
         [
           {:zero, 0, {:lit, 1}},
           {:succ, 1, {:var, 0}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end

    test "parameterized constructor fields get substituted types" do
      ctx = check_ctx(%{Option: option_decl()})

      # case some({Int}, 42) do none -> 0; some(x) -> x end
      # The constructor needs the implicit type arg first.
      # x should have type Int (the type arg of Option(Int)).
      term =
        {:case, {:con, :Option, :some, [{:builtin, :Int}, {:lit, 42}]},
         [
           {:none, 0, {:lit, 0}},
           {:some, 1, {:var, 0}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end

    test "wildcard branch binds scrutinee type" do
      ctx = check_ctx(%{Nat: nat_decl()})

      # case zero do n -> n end
      # n should have type Nat.
      term =
        {:case, {:con, :Nat, :zero, []},
         [
           {:_, 1, {:var, 0}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vdata, :Nat, []} = type
    end
  end

  # ============================================================================
  # Exhaustiveness checking
  # ============================================================================

  describe "exhaustiveness" do
    test "all constructors covered — ok" do
      adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}, {:succ, 1, nil}]
      assert :ok = Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
    end

    test "missing constructor detected" do
      adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}]

      assert {:warning, {:missing_patterns, [:succ]}} =
               Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
    end

    test "wildcard covers remaining constructors" do
      adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}, {:_, 1, nil}]
      assert :ok = Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
    end

    test "wildcard alone covers all" do
      adts = %{Nat: nat_decl()}
      branches = [{:_, 1, nil}]
      assert :ok = Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
    end

    test "literal patterns without wildcard warns" do
      branches = [{:__lit, 0, nil}, {:__lit, 1, nil}]

      assert {:warning, {:missing_patterns, [:_]}} =
               Pattern.check_exhaustiveness(%{}, {:vbuiltin, :Int}, branches)
    end

    test "literal patterns with wildcard is ok" do
      branches = [{:__lit, 0, nil}, {:_, 0, nil}]
      assert :ok = Pattern.check_exhaustiveness(%{}, {:vbuiltin, :Int}, branches)
    end

    test "unknown type is ok" do
      branches = [{:foo, 0, nil}]
      assert :ok = Pattern.check_exhaustiveness(%{}, {:vbuiltin, :Int}, branches)
    end

    test "empty branches on empty type is ok" do
      void_decl = %{
        name: :Void,
        params: [],
        constructors: [],
        universe_level: {:llit, 0},
        span: nil
      }

      assert :ok =
               Pattern.check_exhaustiveness(%{Void: void_decl}, {:vdata, :Void, []}, [])
    end
  end

  # ============================================================================
  # Nested pattern flattening
  # ============================================================================

  describe "nested pattern flattening" do
    test "cons(cons(x, _), _) flattens to nested case" do
      source = """
      type List(a : Type) = nil | cons(a, List(a))
      """

      ctx = elaborate_source(source)

      # case expr do cons(cons(x, _), _) -> x end
      case_ast =
        {:case, nil, {:var, nil, nil},
         [
           {:branch, nil,
            {:pat_constructor, nil, :cons,
             [
               {:pat_constructor, nil, :cons,
                [
                  {:pat_var, nil, :x},
                  {:pat_wildcard, nil}
                ]},
               {:pat_wildcard, nil}
             ]}, {:var, nil, :x}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, case_ast)

      # Should produce a case with cons(fresh_var, _) -> case fresh_var do cons(x, _) -> x end.
      assert {:case, _, [{:cons, 2, inner_case}]} = core
      assert {:case, {:var, _}, [{:cons, 2, {:var, _}}]} = inner_case
    end

    test "nested pattern produces correct evaluation" do
      # Build the core term directly: case cons(cons(1, nil), nil) do
      #   cons(inner, _) -> case inner do cons(x, _) -> x end
      # end
      inner_case =
        {:case, {:var, 1},
         [
           {:cons, 2, {:var, 1}}
         ]}

      term =
        {:case,
         {:con, :List, :cons,
          [
            {:con, :List, :cons, [{:lit, 1}, {:con, :List, nil, []}]},
            {:con, :List, nil, []}
          ]},
         [
           {:cons, 2, inner_case}
         ]}

      assert {:vlit, 1} = Eval.eval(eval_ctx(), term)
    end
  end

  # ============================================================================
  # Core infrastructure (subst/shift)
  # ============================================================================

  describe "core subst/shift for literal branches" do
    test "subst passes through literal branch bodies" do
      alias Haruspex.Core

      # case var(0) do __lit(42) -> var(1) end
      term = {:case, {:var, 0}, [{:__lit, 42, {:var, 1}}]}
      result = Core.subst(term, 1, {:lit, 99})

      assert {:case, {:var, 0}, [{:__lit, 42, {:lit, 99}}]} = result
    end

    test "shift handles literal branches with no offset" do
      alias Haruspex.Core

      term = {:case, {:var, 0}, [{:__lit, 42, {:var, 1}}]}
      result = Core.shift(term, 1, 0)

      # Both vars should be shifted since both >= cutoff 0.
      assert {:case, {:var, 1}, [{:__lit, 42, {:var, 2}}]} = result
    end
  end

  # ============================================================================
  # End-to-end tests
  # ============================================================================

  describe "end-to-end" do
    test "literal case: eval → erase → codegen" do
      term =
        {:case, {:lit, 42},
         [
           {:__lit, 0, {:lit, "zero"}},
           {:__lit, 42, {:lit, "answer"}},
           {:_, 0, {:lit, "other"}}
         ]}

      # Eval.
      assert {:vlit, "answer"} = Eval.eval(eval_ctx(), term)

      # Erase and codegen.
      erased = Erase.erase(term, {:builtin, :String})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert "answer" = result
    end

    test "wildcard case: eval → erase → codegen" do
      term =
        {:case, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]},
         [
           {:zero, 0, {:lit, 0}},
           {:_, 1, {:lit, 1}}
         ]}

      # Eval.
      assert {:vlit, 1} = Eval.eval(eval_ctx(), term)

      # Erase and codegen.
      erased = Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 1 = result
    end

    test "mixed constructor + literal + wildcard" do
      # case some(42) do none -> -1; some(x) -> x; _ -> 0 end
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [
           {:none, 0, {:lit, -1}},
           {:some, 1, {:var, 0}},
           {:_, 1, {:lit, 0}}
         ]}

      assert {:vlit, 42} = Eval.eval(eval_ctx(), term)

      erased = Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 42 = result
    end

    test "constructor not found falls to wildcard in codegen" do
      # Test that wildcard catches constructors not listed.
      term =
        {:case, {:con, :Option, :some, [{:lit, 7}]},
         [
           {:none, 0, {:lit, 0}},
           {:_, 1, {:lit, 99}}
         ]}

      erased = Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 99 = result
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "property tests" do
    property "exhaustiveness always accepts when all constructors present" do
      check all(n_extra <- integer(0..5)) do
        adts = %{Nat: nat_decl()}

        # Always include both constructors.
        branches = [{:zero, 0, nil}, {:succ, 1, nil}]

        # Add extra wildcards or literals (shouldn't affect result).
        extras =
          Enum.map(1..n_extra//1, fn _ -> {:_, 1, nil} end)

        assert :ok = Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches ++ extras)
      end
    end

    property "missing any single constructor is detected" do
      # For Nat, removing either zero or succ should produce a warning.
      check all(remove <- member_of([:zero, :succ])) do
        adts = %{Nat: nat_decl()}

        branches =
          [{:zero, 0, nil}, {:succ, 1, nil}]
          |> Enum.reject(fn {name, _, _} -> name == remove end)

        assert {:warning, {:missing_patterns, [^remove]}} =
                 Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
      end
    end

    property "literal case with wildcard is always exhaustive" do
      check all(n_lits <- integer(0..10)) do
        branches =
          Enum.map(0..(n_lits - 1)//1, fn i -> {:__lit, i, nil} end)

        # Add wildcard.
        branches = branches ++ [{:_, 0, nil}]

        assert :ok = Pattern.check_exhaustiveness(%{}, {:vbuiltin, :Int}, branches)
      end
    end

    property "eval literal case always selects correct branch" do
      check all(target <- integer(0..5)) do
        branches =
          Enum.map(0..5, fn i ->
            {:__lit, i, {:lit, i * 10}}
          end) ++ [{:_, 0, {:lit, -1}}]

        term = {:case, {:lit, target}, branches}
        result = Eval.eval(eval_ctx(), term)
        assert {:vlit, expected} = result
        assert expected == target * 10
      end
    end
  end

  # ============================================================================
  # Coverage: exhaustiveness edge cases
  # ============================================================================

  describe "coverage: exhaustiveness edge cases" do
    test "unknown ADT name returns ok" do
      adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}]
      assert :ok = Pattern.check_exhaustiveness(adts, {:vdata, :Unknown, []}, branches)
    end

    test "literal branch mixed with constructor branches in ADT" do
      adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}, {:succ, 1, nil}, {:__lit, 42, nil}]
      assert :ok = Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
    end

    test "literal-only branches for ADT without wildcard" do
      adts = %{Nat: nat_decl()}
      branches = [{:__lit, 0, nil}]

      assert {:warning, {:missing_patterns, [:succ, :zero]}} =
               Pattern.check_exhaustiveness(adts, {:vdata, :Nat, []}, branches)
    end
  end
end
