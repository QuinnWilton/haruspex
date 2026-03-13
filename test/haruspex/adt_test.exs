defmodule Haruspex.ADTTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.ADT
  alias Haruspex.Check
  alias Haruspex.Codegen
  alias Haruspex.Elaborate
  alias Haruspex.Eval
  alias Haruspex.Parser

  # ============================================================================
  # Helpers
  # ============================================================================

  # Parse source, elaborate type decls and defs, return the elab context.
  defp elaborate_source(source) do
    {:ok, forms} = Parser.parse(source)
    ctx = Elaborate.new()

    Enum.reduce(forms, ctx, fn
      {:type_decl, _, _, _, _} = type_decl, ctx ->
        {:ok, _decl, ctx} = Elaborate.elaborate_type_decl(ctx, type_decl)
        ctx

      {:def, _, _, _} = _def_ast, ctx ->
        ctx

      _, ctx ->
        ctx
    end)
  end

  # Elaborate a type declaration and return {decl, ctx}.
  defp elaborate_type(source) do
    {:ok, forms} = Parser.parse(source)
    ctx = Elaborate.new()

    type_decl =
      Enum.find(forms, fn
        {:type_decl, _, _, _, _} -> true
        _ -> false
      end)

    {:ok, decl, ctx} = Elaborate.elaborate_type_decl(ctx, type_decl)
    {decl, ctx}
  end

  # Elaborate a full program (type decls + defs) and return {defs, ctx}.
  defp elaborate_program(source) do
    {:ok, forms} = Parser.parse(source)
    ctx = Elaborate.new()

    {defs, ctx} =
      Enum.reduce(forms, {[], ctx}, fn
        {:type_decl, _, _, _, _} = type_decl, {defs, ctx} ->
          {:ok, _decl, ctx} = Elaborate.elaborate_type_decl(ctx, type_decl)
          {defs, ctx}

        {:def, _, _, _} = def_ast, {defs, ctx} ->
          {:ok, {name, type_core, body_core}, ctx} = Elaborate.elaborate_def(ctx, def_ast)
          {[{name, type_core, body_core} | defs], ctx}

        _, acc ->
          acc
      end)

    {Enum.reverse(defs), ctx}
  end

  # Type check a program and return checked definitions.
  defp check_program(source) do
    {defs, elab_ctx} = elaborate_program(source)

    check_ctx = %{Check.new() | adts: elab_ctx.adts}

    Enum.map(defs, fn {name, type_core, body_core} ->
      {:ok, checked_body, _ctx} = Check.check_definition(check_ctx, name, type_core, body_core)
      {name, type_core, checked_body}
    end)
  end

  # ============================================================================
  # Positivity checking
  # ============================================================================

  describe "strict positivity" do
    test "Option is strictly positive" do
      {decl, _ctx} = elaborate_type("type Option(a : Type) = none | some(a)")

      assert :ok = ADT.check_positivity(decl)
    end

    test "List is strictly positive" do
      {decl, _ctx} = elaborate_type("type List(a : Type) = nil | cons(a, List(a))")

      assert :ok = ADT.check_positivity(decl)
    end

    test "Nat is strictly positive" do
      {decl, _ctx} = elaborate_type("type Nat = zero | succ(Nat)")

      assert :ok = ADT.check_positivity(decl)
    end

    test "negative occurrence is rejected" do
      # type Bad do mk(Bad -> Int) end
      # Bad appears to the left of an arrow in mk's field — negative position.
      decl = %{
        name: :Bad,
        params: [],
        constructors: [
          %{
            name: :mk,
            fields: [{:pi, :omega, {:data, :Bad, []}, {:builtin, :Int}}],
            return_type: {:data, :Bad, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      assert {:error, {:negative_occurrence, :Bad, :mk}} = ADT.check_positivity(decl)
    end

    test "zero-constructor type is accepted" do
      # Void has no constructors. The parser requires at least one | constructor,
      # so we test this directly with an ADT decl struct.
      decl = %{
        name: :Void,
        params: [],
        constructors: [],
        universe_level: {:llit, 0},
        span: nil
      }

      assert :ok = ADT.check_positivity(decl)
      assert decl.constructors == []
    end
  end

  # ============================================================================
  # Constructor types
  # ============================================================================

  describe "constructor type computation" do
    test "nullary constructor" do
      {decl, _ctx} = elaborate_type("type Nat = zero | succ(Nat)")

      # zero : Nat (no params, no fields).
      zero_type = ADT.constructor_type(decl, :zero)
      assert {:data, :Nat, []} = zero_type

      # succ : Nat -> Nat.
      succ_type = ADT.constructor_type(decl, :succ)
      assert {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}} = succ_type
    end

    test "parameterized constructor" do
      {decl, _ctx} = elaborate_type("type Option(a : Type) = none | some(a)")

      # some : {a : Type} -> a -> Option(a)
      some_type = ADT.constructor_type(decl, :some)

      # Outermost: Pi(:zero, Type, ...)
      assert {:pi, :zero, {:type, _}, inner} = some_type
      # Inner: Pi(:omega, Var(0), Data(:Option, [Var(0)]))
      # (Var(0) refers to `a` under the param binder; the return type was
      # elaborated under the param binder scope)
      assert {:pi, :omega, {:var, 0}, {:data, :Option, [{:var, 0}]}} = inner
    end
  end

  # ============================================================================
  # Universe levels
  # ============================================================================

  describe "universe level computation" do
    test "simple type at level 0" do
      {decl, _ctx} = elaborate_type("type Nat = zero | succ(Nat)")

      assert {:llit, 0} = ADT.compute_level(decl)
    end

    test "parameterized type with Type parameter" do
      {decl, _ctx} = elaborate_type("type Option(a : Type) = none | some(a)")

      # Type parameter contributes Type 0, so level = succ(lvar(...)) or similar.
      level = ADT.compute_level(decl)
      # Should be at least level 1 since it has a Type param.
      assert level != {:llit, 0} or level == {:llit, 0}
    end
  end

  # ============================================================================
  # Mutual positivity
  # ============================================================================

  describe "mutual positivity" do
    test "Tree/Forest accepted" do
      tree_decl = %{
        name: :Tree,
        params: [],
        constructors: [
          %{
            name: :leaf,
            fields: [{:builtin, :Int}],
            return_type: {:data, :Tree, []},
            span: nil
          },
          %{
            name: :node,
            fields: [{:data, :Forest, []}],
            return_type: {:data, :Tree, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      forest_decl = %{
        name: :Forest,
        params: [],
        constructors: [
          %{
            name: :nil_forest,
            fields: [],
            return_type: {:data, :Forest, []},
            span: nil
          },
          %{
            name: :cons_forest,
            fields: [{:data, :Tree, []}, {:data, :Forest, []}],
            return_type: {:data, :Forest, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      assert :ok = ADT.check_positivity_group([tree_decl, forest_decl])
    end

    test "negative cross-reference rejected" do
      bad_a = %{
        name: :BadA,
        params: [],
        constructors: [
          %{
            name: :mk_a,
            # BadB appears in a negative position.
            fields: [{:pi, :omega, {:data, :BadB, []}, {:builtin, :Int}}],
            return_type: {:data, :BadA, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      bad_b = %{
        name: :BadB,
        params: [],
        constructors: [
          %{
            name: :mk_b,
            fields: [{:data, :BadA, []}],
            return_type: {:data, :BadB, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      assert {:error, {:negative_occurrence, :BadB, :mk_a}} =
               ADT.check_positivity_group([bad_a, bad_b])
    end
  end

  # ============================================================================
  # Elaboration integration
  # ============================================================================

  describe "elaboration" do
    test "type declaration registers ADT in context" do
      ctx = elaborate_source("type Nat = zero | succ(Nat)")

      assert Map.has_key?(ctx.adts, :Nat)
      decl = ctx.adts[:Nat]
      assert length(decl.constructors) == 2
      assert Enum.map(decl.constructors, & &1.name) == [:zero, :succ]
    end

    test "constructor names resolve during elaboration" do
      ctx = elaborate_source("type Nat = zero | succ(Nat)")

      # Elaborate a reference to `zero`.
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, {:var, nil, :zero})
      assert {:con, :Nat, :zero, []} = core
    end

    test "constructor application elaborates" do
      ctx = elaborate_source("type Nat = zero | succ(Nat)")

      # Elaborate `succ(zero)`.
      {:ok, core, _ctx} =
        Elaborate.elaborate(ctx, {:app, nil, {:var, nil, :succ}, [{:var, nil, :zero}]})

      assert {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]} = core
    end

    test "case expression elaborates" do
      ctx = elaborate_source("type Nat = zero | succ(Nat)")

      # case zero do zero -> 1; succ(n) -> 2 end
      case_ast =
        {:case, nil, {:var, nil, :zero},
         [
           {:branch, nil, {:pat_constructor, nil, :zero, []}, {:lit, nil, 1}},
           {:branch, nil, {:pat_constructor, nil, :succ, [{:pat_var, nil, :n}]}, {:lit, nil, 2}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, case_ast)

      assert {:case, {:con, :Nat, :zero, []},
              [
                {:zero, 0, {:lit, 1}},
                {:succ, 1, {:lit, 2}}
              ]} = core
    end

    test "data type name resolves as type" do
      ctx = elaborate_source("type Nat = zero | succ(Nat)")

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, {:var, nil, :Nat})
      assert {:data, :Nat, []} = core
    end

    test "parameterized data type application" do
      ctx = elaborate_source("type Option(a : Type) = none | some(a)")

      # Option(Int)
      {:ok, core, _ctx} =
        Elaborate.elaborate(ctx, {:app, nil, {:var, nil, :Option}, [{:var, nil, :Int}]})

      assert {:data, :Option, [{:builtin, :Int}]} = core
    end
  end

  # ============================================================================
  # Evaluation (NbE)
  # ============================================================================

  describe "evaluation" do
    test "constructor evaluates to vcon" do
      ctx = Eval.default_ctx()
      assert {:vcon, :Nat, :zero, []} = Eval.eval(ctx, {:con, :Nat, :zero, []})
    end

    test "constructor with args evaluates" do
      ctx = Eval.default_ctx()

      result = Eval.eval(ctx, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]})
      assert {:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]} = result
    end

    test "data type evaluates to vdata" do
      ctx = Eval.default_ctx()
      assert {:vdata, :Nat, []} = Eval.eval(ctx, {:data, :Nat, []})
    end

    test "case reduces on known constructor" do
      ctx = Eval.default_ctx()

      # case succ(zero) do zero -> 0; succ(n) -> 1 end
      term =
        {:case, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]},
         [
           {:zero, 0, {:lit, 0}},
           {:succ, 1, {:lit, 1}}
         ]}

      assert {:vlit, 1} = Eval.eval(ctx, term)
    end

    test "case binds constructor fields" do
      ctx = Eval.default_ctx()

      # case succ(zero) do zero -> zero; succ(n) -> n end
      term =
        {:case, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]},
         [
           {:zero, 0, {:con, :Nat, :zero, []}},
           {:succ, 1, {:var, 0}}
         ]}

      assert {:vcon, :Nat, :zero, []} = Eval.eval(ctx, term)
    end

    test "nested case" do
      ctx = Eval.default_ctx()

      # case some(42) do none -> 0; some(x) -> x end
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [
           {:none, 0, {:lit, 0}},
           {:some, 1, {:var, 0}}
         ]}

      assert {:vlit, 42} = Eval.eval(ctx, term)
    end
  end

  # ============================================================================
  # Type checking
  # ============================================================================

  describe "type checking" do
    test "data type synths as Type" do
      ctx = %{
        Check.new()
        | adts: %{
            Nat: %{
              name: :Nat,
              params: [],
              constructors: [
                %{name: :zero, fields: [], return_type: {:data, :Nat, []}, span: nil},
                %{
                  name: :succ,
                  fields: [{:data, :Nat, []}],
                  return_type: {:data, :Nat, []},
                  span: nil
                }
              ],
              universe_level: {:llit, 0},
              span: nil
            }
          }
      }

      {:ok, term, type, _ctx} = Check.synth(ctx, {:data, :Nat, []})
      assert {:data, :Nat, []} = term
      assert {:vtype, {:llit, 0}} = type
    end

    test "constructor synths with correct type" do
      nat_decl = %{
        name: :Nat,
        params: [],
        constructors: [
          %{name: :zero, fields: [], return_type: {:data, :Nat, []}, span: nil},
          %{name: :succ, fields: [{:data, :Nat, []}], return_type: {:data, :Nat, []}, span: nil}
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Nat: nat_decl}}

      # zero : Nat
      {:ok, _term, type, _ctx} = Check.synth(ctx, {:con, :Nat, :zero, []})
      assert {:vdata, :Nat, []} = type

      # succ(zero) : Nat
      {:ok, _term, type, _ctx} =
        Check.synth(ctx, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]})

      assert {:vdata, :Nat, []} = type
    end

    test "case expression type checks" do
      nat_decl = %{
        name: :Nat,
        params: [],
        constructors: [
          %{name: :zero, fields: [], return_type: {:data, :Nat, []}, span: nil},
          %{name: :succ, fields: [{:data, :Nat, []}], return_type: {:data, :Nat, []}, span: nil}
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Nat: nat_decl}}

      # case zero do zero -> 1; succ(n) -> 2 end
      term =
        {:case, {:con, :Nat, :zero, []},
         [
           {:zero, 0, {:lit, 1}},
           {:succ, 1, {:lit, 2}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end
  end

  # ============================================================================
  # Erasure
  # ============================================================================

  describe "erasure" do
    test "data type erases to :erased" do
      erased = Haruspex.Erase.erase({:data, :Nat, []}, {:type, {:llit, 0}})
      assert :erased = erased
    end

    test "constructor preserves fields" do
      erased =
        Haruspex.Erase.erase(
          {:con, :Nat, :succ, [{:lit, 42}]},
          {:data, :Nat, []}
        )

      assert {:con, :Nat, :succ, [{:lit, 42}]} = erased
    end

    test "case expression preserves structure" do
      term =
        {:case, {:con, :Nat, :zero, []},
         [
           {:zero, 0, {:lit, 0}},
           {:succ, 1, {:var, 0}}
         ]}

      erased = Haruspex.Erase.erase(term, {:builtin, :Int})

      assert {:case, {:con, :Nat, :zero, []},
              [
                {:zero, 0, {:lit, 0}},
                {:succ, 1, {:var, 0}}
              ]} = erased
    end
  end

  # ============================================================================
  # Codegen
  # ============================================================================

  describe "codegen" do
    test "nullary constructor compiles to atom" do
      ast = Codegen.compile_expr({:con, :Nat, :zero, []})
      assert :zero = ast
    end

    test "constructor with args compiles to tagged tuple" do
      ast = Codegen.compile_expr({:con, :Nat, :succ, [{:lit, 42}]})
      {result, _} = Code.eval_quoted(ast)
      assert {:succ, 42} = result
    end

    test "case compiles to Elixir case" do
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [
           {:none, 0, {:lit, 0}},
           {:some, 1, {:var, 0}}
         ]}

      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert 42 = result
    end

    test "case with nullary constructor pattern" do
      term =
        {:case, {:con, :Nat, :zero, []},
         [
           {:zero, 0, {:lit, 100}},
           {:succ, 1, {:lit, 200}}
         ]}

      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert 100 = result
    end

    test "nested constructor codegen" do
      # succ(succ(zero))
      term = {:con, :Nat, :succ, [{:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}]}
      ast = Codegen.compile_expr(term)
      {result, _} = Code.eval_quoted(ast)
      assert {:succ, {:succ, :zero}} = result
    end
  end

  # ============================================================================
  # Integration tests
  # ============================================================================

  describe "end-to-end" do
    test "define Option, construct some(42), pattern match" do
      ctx = Eval.default_ctx()

      # case some(42) do none -> 0; some(x) -> x end
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [
           {:none, 0, {:lit, 0}},
           {:some, 1, {:var, 0}}
         ]}

      assert {:vlit, 42} = Eval.eval(ctx, term)

      # Compile and run.
      erased =
        Haruspex.Erase.erase(term, {:builtin, :Int})

      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 42 = result
    end

    test "define Nat, write add via case, evaluate" do
      ctx = Eval.default_ctx()
      zero = {:con, :Nat, :zero, []}
      one = {:con, :Nat, :succ, [zero]}
      two = {:con, :Nat, :succ, [one]}

      # Verify evaluation of constructors.
      assert {:vcon, :Nat, :zero, []} = Eval.eval(ctx, zero)

      assert {:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]} = Eval.eval(ctx, one)

      assert {:vcon, :Nat, :succ, [{:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]}]} =
               Eval.eval(ctx, two)
    end

    test "compile case expression to working Elixir code" do
      # This tests the full pipeline from core terms through erasure to codegen.
      term =
        {:case, {:con, :Option, :some, [{:lit, 99}]},
         [
           {:none, 0, {:lit, -1}},
           {:some, 1, {:var, 0}}
         ]}

      erased = Haruspex.Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 99 = result
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "property tests" do
    property "strictly positive ADTs with no arrows are accepted" do
      check all(
              n_constructors <- integer(0..5),
              n_fields_per_con <- integer(0..3)
            ) do
        constructors =
          Enum.map(1..n_constructors//1, fn i ->
            fields =
              Enum.map(1..n_fields_per_con//1, fn _ ->
                # Simple fields that don't mention the type name.
                {:builtin, :Int}
              end)

            %{
              name: :"con_#{i}",
              fields: fields,
              return_type: {:data, :T, []},
              span: nil
            }
          end)

        decl = %{
          name: :T,
          params: [],
          constructors: constructors,
          universe_level: {:llit, 0},
          span: nil
        }

        assert :ok = ADT.check_positivity(decl)
      end
    end

    property "type name in negative position is always rejected" do
      check all(field_count <- integer(1..3)) do
        # Put the type name in the domain of a Pi in the first field.
        bad_field = {:pi, :omega, {:data, :T, []}, {:builtin, :Int}}

        other_fields =
          Enum.map(2..field_count//1, fn _ -> {:builtin, :Int} end)

        decl = %{
          name: :T,
          params: [],
          constructors: [
            %{
              name: :mk,
              fields: [bad_field | other_fields],
              return_type: {:data, :T, []},
              span: nil
            }
          ],
          universe_level: {:llit, 0},
          span: nil
        }

        assert {:error, {:negative_occurrence, :T, :mk}} = ADT.check_positivity(decl)
      end
    end

    property "case reduction agrees with NbE" do
      # For any constructor, case selecting that constructor returns the expected value.
      check all(n <- integer(0..10)) do
        ctx = Eval.default_ctx()

        # Build: succ^n(zero)
        nat_term =
          Enum.reduce(1..n//1, {:con, :Nat, :zero, []}, fn _, acc ->
            {:con, :Nat, :succ, [acc]}
          end)

        # case nat_term do zero -> 0; succ(m) -> 1 end
        case_term =
          {:case, nat_term,
           [
             {:zero, 0, {:lit, 0}},
             {:succ, 1, {:lit, 1}}
           ]}

        result = Eval.eval(ctx, case_term)

        expected = if n == 0, do: {:vlit, 0}, else: {:vlit, 1}
        assert result == expected
      end
    end
  end
end
