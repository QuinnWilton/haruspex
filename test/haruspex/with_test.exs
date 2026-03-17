defmodule Haruspex.WithTest do
  use ExUnit.Case, async: true

  alias Haruspex.Check
  alias Haruspex.Codegen
  alias Haruspex.Elaborate
  alias Haruspex.Erase
  alias Haruspex.Eval
  alias Haruspex.Parser
  alias Haruspex.Pattern
  alias Haruspex.Tokenizer

  # ============================================================================
  # Helpers
  # ============================================================================

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

  defp eval_ctx, do: Eval.default_ctx()

  # ============================================================================
  # Parser
  # ============================================================================

  describe "parser" do
    test "tokenizer has with keyword" do
      {:ok, tokens} = Tokenizer.tokenize("with x do\n_ -> x\nend")
      assert Enum.any?(tokens, fn {tag, _, _} -> tag == :with end)
    end

    test "parse single-scrutinee with" do
      source = "def f(x : Bool) : Int do\nwith x do\ntrue -> 1\nfalse -> 0\nend\nend"
      {:ok, forms} = Parser.parse(source)

      [{:def, _, _, body}] = forms
      assert {:with, _, [_scrutinee], [_branch1, _branch2]} = body
    end

    test "parse with expression has correct scrutinee" do
      source = "def f(x : Bool) : Int do\nwith x do\ntrue -> 1\nfalse -> 0\nend\nend"
      {:ok, [{:def, _, _, {:with, _, [scrutinee], _}}]} = Parser.parse(source)

      assert {:var, _, :x} = scrutinee
    end

    test "parse with branches have correct patterns" do
      source = "def f(x : Bool) : Int do\nwith x do\ntrue -> 1\nfalse -> 0\nend\nend"
      {:ok, [{:def, _, _, {:with, _, _, branches}}]} = Parser.parse(source)

      assert [
               {:branch, _, {:pat_lit, _, true}, {:lit, _, 1}},
               {:branch, _, {:pat_lit, _, false}, {:lit, _, 0}}
             ] = branches
    end

    test "parse multiple scrutinees" do
      source = "def f(x : Bool, y : Bool) : Int do\nwith x, y do\n_ -> 0\nend\nend"
      {:ok, [{:def, _, _, {:with, _, scrutinees, _}}]} = Parser.parse(source)

      assert [{:var, _, :x}, {:var, _, :y}] = scrutinees
    end

    test "parse with and constructor pattern" do
      source = "def f(x : Option) : Int do\nwith x do\nsome(v) -> v\nNone -> 0\nend\nend"
      {:ok, [{:def, _, _, {:with, _, _, branches}}]} = Parser.parse(source)

      assert [
               {:branch, _, {:pat_constructor, _, :some, [{:pat_var, _, :v}]}, {:var, _, :v}},
               {:branch, _, {:pat_constructor, _, :None, []}, {:lit, _, 0}}
             ] = branches
    end
  end

  # ============================================================================
  # Elaboration
  # ============================================================================

  describe "elaboration" do
    test "single-scrutinee with elaborates to case" do
      ctx = elaborate_source("type Bool = tt | ff")

      # with True do True -> 1; False -> 0 end
      with_ast =
        {:with, nil, [{:var, nil, :tt}],
         [
           {:branch, nil, {:pat_constructor, nil, :tt, []}, {:lit, nil, 1}},
           {:branch, nil, {:pat_constructor, nil, :ff, []}, {:lit, nil, 0}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, with_ast)

      # Should produce a case expression.
      assert {:case, {:con, :Bool, :tt, []}, [{:tt, 0, {:lit, 1}}, {:ff, 0, {:lit, 0}}]} =
               core
    end

    test "with wildcard branch elaborates correctly" do
      ctx = elaborate_source("type Bool = tt | ff")

      with_ast =
        {:with, nil, [{:var, nil, :tt}], [{:branch, nil, {:pat_wildcard, nil}, {:lit, nil, 42}}]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, with_ast)
      assert {:case, {:con, :Bool, :tt, []}, [{:_, 1, {:lit, 42}}]} = core
    end

    test "multiple scrutinees desugar to nested case" do
      ctx = elaborate_source("type Bool = tt | ff")

      with_ast =
        {:with, nil, [{:var, nil, :tt}, {:var, nil, :ff}],
         [{:branch, nil, {:pat_wildcard, nil}, {:lit, nil, 0}}]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, with_ast)

      # Outer case on first scrutinee with wildcard, inner case on second.
      assert {:case, {:con, :Bool, :tt, []}, [{:_, 1, {:case, {:con, :Bool, :ff, []}, _}}]} =
               core
    end
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  describe "evaluation" do
    test "with on Bool evaluates correctly" do
      # Desugars to: case True do True -> 1; False -> 0 end
      term =
        {:case, {:con, :Bool, :tt, []}, [{:tt, 0, {:lit, 1}}, {:ff, 0, {:lit, 0}}]}

      assert {:vlit, 1} = Eval.eval(eval_ctx(), term)
    end

    test "with on False branch evaluates correctly" do
      term =
        {:case, {:con, :Bool, :ff, []}, [{:tt, 0, {:lit, 1}}, {:ff, 0, {:lit, 0}}]}

      assert {:vlit, 0} = Eval.eval(eval_ctx(), term)
    end

    test "with on constructor with field evaluates correctly" do
      # case some(42) do some(x) -> x; none -> 0 end
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [{:some, 1, {:var, 0}}, {:none, 0, {:lit, 0}}]}

      assert {:vlit, 42} = Eval.eval(eval_ctx(), term)
    end

    test "with wildcard evaluates correctly" do
      term = {:case, {:con, :Bool, :tt, []}, [{:_, 0, {:lit, 99}}]}
      assert {:vlit, 99} = Eval.eval(eval_ctx(), term)
    end
  end

  # ============================================================================
  # Type checking
  # ============================================================================

  describe "type checking" do
    test "with on Bool type checks" do
      ctx = elaborate_source("type Bool = tt | ff")
      check_ctx = %{Check.new() | adts: ctx.adts}

      # case True do True -> 1; False -> 0 end
      term =
        {:case, {:con, :Bool, :tt, []}, [{:tt, 0, {:lit, 1}}, {:ff, 0, {:lit, 0}}]}

      {:ok, _checked, type, _ctx} = Check.synth(check_ctx, term)
      assert {:vbuiltin, :Int} = type
    end
  end

  # ============================================================================
  # Goal type abstraction
  # ============================================================================

  describe "abstract_over" do
    test "trivial abstraction when scrutinee not in goal" do
      scrut = {:vlit, 42}
      goal = {:vbuiltin, :Int}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)

      # Scrutinee doesn't appear in goal, so abstraction is identity.
      assert {:builtin, :Int} = abstracted
    end

    test "replaces scrutinee when it equals goal type" do
      scrut = {:vbuiltin, :Int}
      goal = {:vbuiltin, :Int}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)

      # The whole goal is the scrutinee, so it should become {:var, 0}.
      assert {:var, 0} = abstracted
    end

    test "replaces scrutinee in nested data type args" do
      scrut = {:vbuiltin, :Int}
      goal = {:vdata, :Vec, [{:vbuiltin, :Int}]}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)

      # Int in the args should be replaced with {:var, 0}.
      assert {:data, :Vec, [{:var, 0}]} = abstracted
    end

    test "abstraction in pi domain" do
      scrut = {:vbuiltin, :Int}
      goal = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)

      # Domain should be replaced.
      assert {:pi, :omega, {:var, 0}, _cod} = abstracted
    end

    test "non-matching value is left unchanged" do
      scrut = {:vlit, 42}
      goal = {:vbuiltin, :Float}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:builtin, :Float} = abstracted
    end

    test "replaces multiple occurrences" do
      scrut = {:vbuiltin, :Int}
      goal = {:vdata, :Pair, [{:vbuiltin, :Int}, {:vbuiltin, :Int}]}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:data, :Pair, [{:var, 0}, {:var, 0}]} = abstracted
    end

    test "leaves non-matching parts intact" do
      scrut = {:vbuiltin, :Int}
      goal = {:vdata, :Pair, [{:vbuiltin, :Int}, {:vbuiltin, :Float}]}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:data, :Pair, [{:var, 0}, {:builtin, :Float}]} = abstracted
    end

    test "replaces scrutinee in app" do
      scrut = {:vbuiltin, :Int}
      # Goal is App(f, Int) — should replace Int with var 0.
      goal = {:vneutral, {:vtype, {:llit, 0}}, {:napp, {:nvar, 0}, {:vbuiltin, :Int}}}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 1)
      assert {:app, {:var, 0}, {:var, 0}} = abstracted
    end

    test "replaces scrutinee in pair" do
      scrut = {:vbuiltin, :Int}
      goal = {:vpair, {:vbuiltin, :Int}, {:vbuiltin, :Float}}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:pair, {:var, 0}, {:builtin, :Float}} = abstracted
    end

    test "replaces scrutinee in fst" do
      scrut = {:vbuiltin, :Int}
      goal = {:vneutral, {:vtype, {:llit, 0}}, {:nfst, {:nvar, 0}}}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 1)
      assert {:fst, {:var, 0}} = abstracted
    end

    test "replaces scrutinee in snd" do
      scrut = {:vbuiltin, :Int}
      goal = {:vneutral, {:vtype, {:llit, 0}}, {:nsnd, {:nvar, 0}}}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 1)
      assert {:snd, {:var, 0}} = abstracted
    end

    test "replaces scrutinee in sigma" do
      scrut = {:vbuiltin, :Int}
      goal = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Float}}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:sigma, {:var, 0}, {:builtin, :Float}} = abstracted
    end

    test "replaces scrutinee in con" do
      scrut = {:vbuiltin, :Int}
      goal = {:vcon, :Option, :some, [{:vbuiltin, :Int}]}
      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:con, :Option, :some, [{:var, 0}]} = abstracted
    end

    test "replaces scrutinee in case scrutinee position" do
      scrut = {:vbuiltin, :Int}
      # Goal contains a case with Int as the scrutinee.
      goal =
        {:vneutral, {:vtype, {:llit, 0}},
         {:ncase, {:nbuiltin, :Int}, [{:_, 0, {[], {:lit, 42}}}]}}

      ms = Haruspex.Unify.MetaState.new()

      {:ok, abstracted} = Pattern.abstract_over(scrut, goal, ms, 0)
      assert {:case, {:var, 0}, [{:_, 0, {:lit, 42}}]} = abstracted
    end
  end

  # ============================================================================
  # End-to-end
  # ============================================================================

  describe "end-to-end" do
    test "with on Bool through eval + erase + codegen" do
      term =
        {:case, {:con, :Bool, :tt, []}, [{:tt, 0, {:lit, 1}}, {:ff, 0, {:lit, 0}}]}

      assert {:vlit, 1} = Eval.eval(eval_ctx(), term)

      erased = Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 1 = result
    end

    test "with on constructor through eval + erase + codegen" do
      term =
        {:case, {:con, :Option, :some, [{:lit, 42}]},
         [{:some, 1, {:var, 0}}, {:none, 0, {:lit, 0}}]}

      assert {:vlit, 42} = Eval.eval(eval_ctx(), term)

      erased = Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 42 = result
    end

    test "parse → elaborate → eval for with expression" do
      ctx = elaborate_source("type Bool = tt | ff")

      with_ast =
        {:with, nil, [{:var, nil, :tt}],
         [
           {:branch, nil, {:pat_constructor, nil, :tt, []}, {:lit, nil, 1}},
           {:branch, nil, {:pat_constructor, nil, :ff, []}, {:lit, nil, 0}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, with_ast)
      assert {:vlit, 1} = Eval.eval(eval_ctx(), core)
    end

    test "parse → elaborate → eval for with wildcard" do
      ctx = elaborate_source("type Bool = tt | ff")

      with_ast =
        {:with, nil, [{:var, nil, :ff}],
         [
           {:branch, nil, {:pat_constructor, nil, :tt, []}, {:lit, nil, 1}},
           {:branch, nil, {:pat_wildcard, nil}, {:lit, nil, 99}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, with_ast)
      assert {:vlit, 99} = Eval.eval(eval_ctx(), core)
    end

    test "multiple scrutinees evaluate correctly" do
      ctx = elaborate_source("type Bool = tt | ff")

      with_ast =
        {:with, nil, [{:var, nil, :tt}, {:var, nil, :ff}],
         [{:branch, nil, {:pat_wildcard, nil}, {:lit, nil, 42}}]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, with_ast)
      assert {:vlit, 42} = Eval.eval(eval_ctx(), core)
    end
  end

  # ============================================================================
  # If desugaring
  # ============================================================================

  describe "if desugaring" do
    test "if true evaluates to then branch" do
      ctx = Elaborate.new()
      s = nil
      ast = {:if, s, {:lit, s, true}, {:lit, s, 1}, {:lit, s, 2}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:vlit, 1} = Eval.eval(eval_ctx(), core)
    end

    test "if false evaluates to else branch" do
      ctx = Elaborate.new()
      s = nil
      ast = {:if, s, {:lit, s, false}, {:lit, s, 1}, {:lit, s, 2}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:vlit, 2} = Eval.eval(eval_ctx(), core)
    end

    test "if desugars to case with literal branches" do
      ctx = Elaborate.new()
      s = nil
      ast = {:if, s, {:lit, s, true}, {:lit, s, 1}, {:lit, s, 2}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)

      assert {:case, {:lit, true}, [{:__lit, true, {:lit, 1}}, {:__lit, false, {:lit, 2}}]} = core
    end

    test "if type checks with Bool condition" do
      check_ctx = Check.new()
      # case true do true -> 1; false -> 2 end
      term = {:case, {:lit, true}, [{:__lit, true, {:lit, 1}}, {:__lit, false, {:lit, 2}}]}
      {:ok, _checked, type, _ctx} = Check.synth(check_ctx, term)
      assert {:vbuiltin, :Int} = type
    end

    test "if through codegen" do
      term = {:case, {:lit, true}, [{:__lit, true, {:lit, 1}}, {:__lit, false, {:lit, 2}}]}
      erased = Erase.erase(term, {:builtin, :Int})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 1 = result
    end
  end

  # ============================================================================
  # Core-level abstraction (abstract_core_term)
  # ============================================================================

  describe "abstract_core_term" do
    setup do
      %{ms: Haruspex.Unify.MetaState.new()}
    end

    # --- Leaves ---

    test "var matching target is replaced", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:var, 3}, {:var, 3}, ms, 0)
      assert {:var, 0} = result
    end

    test "var not matching target is left alone", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:var, 3}, {:var, 5}, ms, 0)
      assert {:var, 3} = result
    end

    test "lit leaf unchanged when not target", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:lit, 42}, {:builtin, :Int}, ms, 0)
      assert {:lit, 42} = result
    end

    test "builtin leaf unchanged when not target", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:builtin, :Float}, {:builtin, :Int}, ms, 0)
      assert {:builtin, :Float} = result
    end

    test "type leaf unchanged when not target", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:type, {:llit, 0}}, {:builtin, :Int}, ms, 0)
      assert {:type, {:llit, 0}} = result
    end

    test "meta leaf unchanged when not target", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:meta, 7}, {:builtin, :Int}, ms, 0)
      assert {:meta, 7} = result
    end

    test "erased leaf unchanged when not target", %{ms: ms} do
      {:ok, result} = Pattern.abstract_core_term({:erased}, {:builtin, :Int}, ms, 0)
      assert {:erased} = result
    end

    # --- Pi ---

    test "pi: target in domain is replaced", %{ms: ms} do
      goal = {:pi, :omega, {:builtin, :Int}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:pi, :omega, {:var, 0}, {:builtin, :Float}} = result
    end

    test "pi: target in codomain is replaced with shift", %{ms: ms} do
      # Under the pi binder, target {:builtin, :Int} shifts to {:builtin, :Int}
      # (builtins don't shift), so it still matches in the codomain.
      goal = {:pi, :omega, {:builtin, :Float}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:pi, :omega, {:builtin, :Float}, {:var, 0}} = result
    end

    test "pi: target in both domain and codomain", %{ms: ms} do
      goal = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:pi, :omega, {:var, 0}, {:var, 0}} = result
    end

    test "pi: var target shifts under binder", %{ms: ms} do
      # Target is {:var, 2}. Under the pi binder, it shifts to {:var, 3}.
      # So {:var, 2} in the domain should match, but {:var, 2} in the codomain
      # should NOT match (because the shifted target is {:var, 3}).
      goal = {:pi, :omega, {:var, 2}, {:var, 2}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 2}, ms, 0)
      # Domain: var 2 == target var 2 → replaced with var 0
      # Codomain: var 2 != shifted target var 3 → stays as var 2
      assert {:pi, :omega, {:var, 0}, {:var, 2}} = result
    end

    # --- Sigma ---

    test "sigma: target in first component", %{ms: ms} do
      goal = {:sigma, {:builtin, :Int}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:sigma, {:var, 0}, {:builtin, :Float}} = result
    end

    test "sigma: target in second component (shifted)", %{ms: ms} do
      goal = {:sigma, {:builtin, :Float}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:sigma, {:builtin, :Float}, {:var, 0}} = result
    end

    test "sigma: var target shifts under binder", %{ms: ms} do
      goal = {:sigma, {:var, 1}, {:var, 1}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 1}, ms, 0)
      assert {:sigma, {:var, 0}, {:var, 1}} = result
    end

    # --- App ---

    test "app: target in function position", %{ms: ms} do
      goal = {:app, {:builtin, :Int}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:app, {:var, 0}, {:builtin, :Float}} = result
    end

    test "app: target in argument position", %{ms: ms} do
      goal = {:app, {:builtin, :Float}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:app, {:builtin, :Float}, {:var, 0}} = result
    end

    test "app: target in both positions", %{ms: ms} do
      goal = {:app, {:builtin, :Int}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:app, {:var, 0}, {:var, 0}} = result
    end

    # --- Lam ---

    test "lam: target in body (shifted)", %{ms: ms} do
      goal = {:lam, :omega, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:lam, :omega, {:var, 0}} = result
    end

    test "lam: var target shifts under binder", %{ms: ms} do
      # Target {:var, 0} shifts to {:var, 1} under the lam binder.
      # Body has {:var, 0} which is the lam-bound var, not the target.
      goal = {:lam, :omega, {:var, 0}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 0}, ms, 0)
      # {:var, 0} in body != shifted target {:var, 1}, so unchanged.
      assert {:lam, :omega, {:var, 0}} = result
    end

    test "lam: var target matches in body after shift", %{ms: ms} do
      # Target {:var, 0} shifts to {:var, 1}. Body has {:var, 1} → match.
      goal = {:lam, :omega, {:var, 1}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 0}, ms, 0)
      assert {:lam, :omega, {:var, 0}} = result
    end

    test "lam: preserves multiplicity", %{ms: ms} do
      goal = {:lam, :zero, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:lam, :zero, {:var, 0}} = result
    end

    # --- Let ---

    test "let: target in definition", %{ms: ms} do
      goal = {:let, {:builtin, :Int}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:let, {:var, 0}, {:builtin, :Float}} = result
    end

    test "let: target in body (shifted)", %{ms: ms} do
      goal = {:let, {:builtin, :Float}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      # NbE: let x = Float in Int evaluates to Int (let-reduction), matching target.
      # The whole expression is replaced at the top level.
      assert {:var, 0} = result
    end

    test "let: target in both", %{ms: ms} do
      goal = {:let, {:builtin, :Int}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      # NbE: let x = Int in Int evaluates to Int, matching target.
      assert {:var, 0} = result
    end

    test "let: var target shifts under binder", %{ms: ms} do
      goal = {:let, {:var, 1}, {:var, 1}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 1}, ms, 0)
      # Def: var 1 matches target → replaced with var 0.
      # Body: var 1 != shifted target var 2 → stays.
      assert {:let, {:var, 0}, {:var, 1}} = result
    end

    # --- Pair ---

    test "pair: target in first", %{ms: ms} do
      goal = {:pair, {:builtin, :Int}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:pair, {:var, 0}, {:builtin, :Float}} = result
    end

    test "pair: target in second", %{ms: ms} do
      goal = {:pair, {:builtin, :Float}, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:pair, {:builtin, :Float}, {:var, 0}} = result
    end

    # --- Fst / Snd ---

    test "fst: target in inner expr", %{ms: ms} do
      goal = {:fst, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:fst, {:var, 0}} = result
    end

    test "snd: target in inner expr", %{ms: ms} do
      goal = {:snd, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:snd, {:var, 0}} = result
    end

    test "fst: no match leaves unchanged", %{ms: ms} do
      goal = {:fst, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:fst, {:builtin, :Float}} = result
    end

    test "snd: no match leaves unchanged", %{ms: ms} do
      goal = {:snd, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:snd, {:builtin, :Float}} = result
    end

    # --- Data ---

    test "data: target in args", %{ms: ms} do
      goal = {:data, :Vec, [{:builtin, :Int}, {:builtin, :Float}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:data, :Vec, [{:var, 0}, {:builtin, :Float}]} = result
    end

    test "data: multiple matching args", %{ms: ms} do
      goal = {:data, :Pair, [{:builtin, :Int}, {:builtin, :Int}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:data, :Pair, [{:var, 0}, {:var, 0}]} = result
    end

    test "data: no matching args", %{ms: ms} do
      goal = {:data, :Vec, [{:builtin, :Float}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:data, :Vec, [{:builtin, :Float}]} = result
    end

    test "data: empty args", %{ms: ms} do
      goal = {:data, :Unit, []}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:data, :Unit, []} = result
    end

    # --- Con ---

    test "con: target in args", %{ms: ms} do
      goal = {:con, :Option, :some, [{:builtin, :Int}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:con, :Option, :some, [{:var, 0}]} = result
    end

    test "con: empty args left unchanged", %{ms: ms} do
      goal = {:con, :Option, :none, []}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:con, :Option, :none, []} = result
    end

    # --- Record proj ---

    test "record_proj: target in inner expr", %{ms: ms} do
      goal = {:record_proj, :x, {:builtin, :Int}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:record_proj, :x, {:var, 0}} = result
    end

    test "record_proj: no match leaves unchanged", %{ms: ms} do
      goal = {:record_proj, :x, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:record_proj, :x, {:builtin, :Float}} = result
    end

    # --- Case ---

    test "case: target in scrutinee", %{ms: ms} do
      goal = {:case, {:builtin, :Int}, [{:_, 0, {:lit, 42}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:case, {:var, 0}, [{:_, 0, {:lit, 42}}]} = result
    end

    test "case: target in constructor branch body", %{ms: ms} do
      goal = {:case, {:builtin, :Float}, [{:some, 1, {:builtin, :Int}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      # Under constructor branch with arity 1, target shifts to {:builtin, :Int}
      # (builtins don't shift), so it still matches.
      assert {:case, {:builtin, :Float}, [{:some, 1, {:var, 0}}]} = result
    end

    test "case: target in wildcard branch body (arity 0)", %{ms: ms} do
      goal = {:case, {:builtin, :Float}, [{:_, 0, {:builtin, :Int}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:case, {:builtin, :Float}, [{:_, 0, {:var, 0}}]} = result
    end

    test "case: target in wildcard branch body (arity 1)", %{ms: ms} do
      goal = {:case, {:builtin, :Float}, [{:_, 1, {:builtin, :Int}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:case, {:builtin, :Float}, [{:_, 1, {:var, 0}}]} = result
    end

    test "case: target in literal branch body", %{ms: ms} do
      goal = {:case, {:builtin, :Float}, [{:__lit, 42, {:builtin, :Int}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:case, {:builtin, :Float}, [{:__lit, 42, {:var, 0}}]} = result
    end

    test "case: literal branch body no match", %{ms: ms} do
      goal = {:case, {:builtin, :Float}, [{:__lit, 42, {:builtin, :Float}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:case, {:builtin, :Float}, [{:__lit, 42, {:builtin, :Float}}]} = result
    end

    test "case: var target shifts under constructor branch", %{ms: ms} do
      # Target is {:var, 0}. In a branch with arity 2, it shifts to {:var, 2}.
      # Body has {:var, 2} → should match the shifted target.
      goal = {:case, {:builtin, :Float}, [{:pair, 2, {:var, 2}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 0}, ms, 0)
      assert {:case, {:builtin, :Float}, [{:pair, 2, {:var, 0}}]} = result
    end

    test "case: multiple branches", %{ms: ms} do
      goal =
        {:case, {:builtin, :Float},
         [
           {:some, 1, {:builtin, :Int}},
           {:none, 0, {:builtin, :Int}},
           {:__lit, 0, {:builtin, :Int}}
         ]}

      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)

      assert {:case, {:builtin, :Float},
              [{:some, 1, {:var, 0}}, {:none, 0, {:var, 0}}, {:__lit, 0, {:var, 0}}]} = result
    end

    # --- Deeply nested ---

    test "deeply nested: target inside data inside pi domain", %{ms: ms} do
      goal = {:pi, :omega, {:data, :Vec, [{:builtin, :Int}]}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:pi, :omega, {:data, :Vec, [{:var, 0}]}, {:builtin, :Float}} = result
    end

    test "deeply nested: target inside con inside let", %{ms: ms} do
      goal = {:let, {:con, :Option, :some, [{:builtin, :Int}]}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:let, {:con, :Option, :some, [{:var, 0}]}, {:builtin, :Float}} = result
    end

    test "deeply nested: target inside pair inside fst", %{ms: ms} do
      goal = {:fst, {:pair, {:builtin, :Int}, {:builtin, :Float}}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      # NbE: fst(pair(Int, Float)) evaluates to Int, matching target.
      assert {:var, 0} = result
    end

    test "deeply nested: target inside app inside snd", %{ms: ms} do
      goal = {:snd, {:app, {:builtin, :Int}, {:builtin, :Float}}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:snd, {:app, {:var, 0}, {:builtin, :Float}}} = result
    end

    test "deeply nested: target in lam body inside sigma", %{ms: ms} do
      goal = {:sigma, {:builtin, :Float}, {:lam, :omega, {:builtin, :Int}}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      # Sigma shifts target for second component. Lam shifts again.
      # But {:builtin, :Int} is immune to shifting, so matches at every level.
      assert {:sigma, {:builtin, :Float}, {:lam, :omega, {:var, 0}}} = result
    end

    test "deeply nested: record_proj inside case branch", %{ms: ms} do
      goal = {:case, {:builtin, :Float}, [{:_, 0, {:record_proj, :x, {:builtin, :Int}}}]}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:case, {:builtin, :Float}, [{:_, 0, {:record_proj, :x, {:var, 0}}}]} = result
    end

    # --- Whole term matches target ---

    test "whole pi matches target", %{ms: ms} do
      target = {:pi, :omega, {:builtin, :Int}, {:builtin, :Float}}
      {:ok, result} = Pattern.abstract_core_term(target, target, ms, 0)
      assert {:var, 0} = result
    end

    test "whole case matches target", %{ms: ms} do
      target = {:case, {:builtin, :Int}, [{:_, 0, {:lit, 1}}]}
      {:ok, result} = Pattern.abstract_core_term(target, target, ms, 0)
      assert {:var, 0} = result
    end

    test "whole lam matches target", %{ms: ms} do
      target = {:lam, :omega, {:lit, 42}}
      {:ok, result} = Pattern.abstract_core_term(target, target, ms, 0)
      assert {:var, 0} = result
    end

    # --- Variable shifting across multiple binders ---

    test "var target shifts correctly through nested binders", %{ms: ms} do
      # Target: {:var, 0}
      # Goal: pi(_, sigma(_, {:var, 0})) — two binders deep.
      # Under pi, target shifts to {:var, 1}.
      # Under sigma (inside pi), target shifts to {:var, 2}.
      # So {:var, 0} at depth 2 is the sigma-bound var, not the target.
      goal = {:pi, :omega, {:builtin, :Float}, {:sigma, {:builtin, :Float}, {:var, 0}}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 0}, ms, 0)
      assert {:pi, :omega, {:builtin, :Float}, {:sigma, {:builtin, :Float}, {:var, 0}}} = result
    end

    test "var target matches at correct depth", %{ms: ms} do
      # Target: {:var, 0}
      # Under pi: shifted to {:var, 1}.
      # Under sigma (inside pi): shifted to {:var, 2}.
      # Body has {:var, 2} → matches shifted target.
      goal = {:pi, :omega, {:builtin, :Float}, {:sigma, {:builtin, :Float}, {:var, 2}}}
      {:ok, result} = Pattern.abstract_core_term(goal, {:var, 0}, ms, 0)
      assert {:pi, :omega, {:builtin, :Float}, {:sigma, {:builtin, :Float}, {:var, 0}}} = result
    end

    # --- Unknown/exotic leaf forms ---

    test "unknown tuple form is treated as leaf", %{ms: ms} do
      goal = {:some_exotic_form, :whatever, 123}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:some_exotic_form, :whatever, 123} = result
    end

    test "global is treated as leaf", %{ms: ms} do
      goal = {:global, :MyMod, :myfun, 2}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:global, :MyMod, :myfun, 2} = result
    end

    test "extern is treated as leaf", %{ms: ms} do
      goal = {:extern, Kernel, :+, 2}
      {:ok, result} = Pattern.abstract_core_term(goal, {:builtin, :Int}, ms, 0)
      assert {:extern, Kernel, :+, 2} = result
    end
  end

  # ============================================================================
  # Check mode for case (motive-based)
  # ============================================================================

  describe "check mode for case" do
    test "case checked against expected type" do
      check_ctx = Check.new()
      term = {:case, {:lit, true}, [{:__lit, true, {:lit, 1}}, {:__lit, false, {:lit, 2}}]}
      {:ok, _checked, ctx} = Check.check(check_ctx, term, {:vbuiltin, :Int})
      assert ctx != nil
    end
  end
end
