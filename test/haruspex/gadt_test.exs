defmodule Haruspex.GADTTest do
  use ExUnit.Case, async: true

  import Haruspex.Test.GADTHelpers

  alias Haruspex.Check
  alias Haruspex.Context
  alias Haruspex.Pattern
  alias Haruspex.Unify.MetaState

  # ============================================================================
  # GADT branch context — field type refinement
  # ============================================================================

  describe "GADT branch context — vcons against Vec(Int, succ(n))" do
    test "vcons fields get refined types" do
      ctx = check_ctx()
      # Scrutinee: Vec(Int, succ(zero))
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, rest) -> x end
      # In the vcons branch, x should have type Int and rest should have type Vec(Int, zero).
      term =
        {:case, {:var, 0},
         [
           {:vcons, 2, {:var, 1}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      # x is at de Bruijn index 1 (second field bound), and its type should be Int.
      assert {:vbuiltin, :Int} = type
    end

    test "vcons rest field has refined Vec type" do
      ctx = check_ctx()
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, rest) -> rest end
      # rest should have type Vec(Int, zero).
      term =
        {:case, {:var, 0},
         [
           {:vcons, 2, {:var, 0}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vdata, :Vec, [{:vbuiltin, :Int}, {:vcon, :Nat, :zero, []}]} = type
    end
  end

  describe "GADT branch context — vnil against Vec(a, succ(n)) is impossible" do
    test "vnil branch falls back to placeholder types" do
      ctx = check_ctx()
      # Scrutinee: Vec(Int, succ(zero)) — vnil is impossible here.
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vnil -> 0; vcons(x, rest) -> 1 end
      # Both branches should type-check (vnil is unreachable but still checked).
      term =
        {:case, {:var, 0},
         [
           {:vnil, 0, {:lit, 0}},
           {:vcons, 2, {:lit, 1}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end
  end

  describe "GADT branch context — check mode with expected type" do
    test "vcons body checked against expected type" do
      ctx = check_ctx()
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, rest) -> x end : Int
      term =
        {:case, {:var, 0},
         [
           {:vcons, 2, {:var, 1}}
         ]}

      {:ok, _checked, _ctx} = Check.check(ctx, term, {:vbuiltin, :Int})
    end

    test "vcons rest checked against Vec(Int, zero)" do
      ctx = check_ctx()
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, rest) -> rest end : Vec(Int, zero)
      term =
        {:case, {:var, 0},
         [
           {:vcons, 2, {:var, 0}}
         ]}

      expected = vec_type({:vbuiltin, :Int}, vzero())
      {:ok, _checked, _ctx} = Check.check(ctx, term, expected)
    end
  end

  # ============================================================================
  # GADT-aware exhaustiveness
  # ============================================================================

  describe "GADT exhaustiveness — Vec(a, succ(n))" do
    test "only vcons is required when scrutinee is Vec(a, succ(n))" do
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      branches = [{:vcons, 2, nil}]

      assert :ok =
               Pattern.check_exhaustiveness(
                 adts(),
                 scrut_type,
                 branches,
                 MetaState.new(),
                 0
               )
    end

    test "missing vcons when scrutinee is Vec(a, succ(n))" do
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      branches = [{:vnil, 0, nil}]

      assert {:warning, {:missing_patterns, [:vcons]}} =
               Pattern.check_exhaustiveness(
                 adts(),
                 scrut_type,
                 branches,
                 MetaState.new(),
                 0
               )
    end
  end

  describe "GADT exhaustiveness — Vec(a, zero)" do
    test "only vnil is required when scrutinee is Vec(a, zero)" do
      scrut_type = vec_type({:vbuiltin, :Int}, vzero())
      branches = [{:vnil, 0, nil}]

      assert :ok =
               Pattern.check_exhaustiveness(
                 adts(),
                 scrut_type,
                 branches,
                 MetaState.new(),
                 0
               )
    end

    test "missing vnil when scrutinee is Vec(a, zero)" do
      scrut_type = vec_type({:vbuiltin, :Int}, vzero())
      branches = [{:vcons, 2, nil}]

      assert {:warning, {:missing_patterns, [:vnil]}} =
               Pattern.check_exhaustiveness(
                 adts(),
                 scrut_type,
                 branches,
                 MetaState.new(),
                 0
               )
    end
  end

  describe "GADT exhaustiveness — general Vec(a, n)" do
    test "both constructors required for unrefined Vec" do
      # When the index is a neutral (unsolved meta or variable), both constructors
      # are possible and must be covered.
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vdata, :Nat, []}, 0, :implicit)
      n_neutral = {:vneutral, {:vdata, :Nat, []}, {:nmeta, id}}
      scrut_type = vec_type({:vbuiltin, :Int}, n_neutral)

      branches = [{:vnil, 0, nil}]

      assert {:warning, {:missing_patterns, [:vcons]}} =
               Pattern.check_exhaustiveness(adts(), scrut_type, branches, ms, 0)
    end

    test "wildcard covers all constructors" do
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vzero()))
      branches = [{:_, 1, nil}]

      assert :ok =
               Pattern.check_exhaustiveness(
                 adts(),
                 scrut_type,
                 branches,
                 MetaState.new(),
                 0
               )
    end
  end

  # ============================================================================
  # Non-GADT regression
  # ============================================================================

  describe "non-GADT types unchanged" do
    test "Nat exhaustiveness still works with /5" do
      nat_adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}, {:succ, 1, nil}]

      assert :ok =
               Pattern.check_exhaustiveness(
                 nat_adts,
                 {:vdata, :Nat, []},
                 branches,
                 MetaState.new(),
                 0
               )
    end

    test "Nat missing constructor still detected with /5" do
      nat_adts = %{Nat: nat_decl()}
      branches = [{:zero, 0, nil}]

      assert {:warning, {:missing_patterns, [:succ]}} =
               Pattern.check_exhaustiveness(
                 nat_adts,
                 {:vdata, :Nat, []},
                 branches,
                 MetaState.new(),
                 0
               )
    end

    test "Nat case branch field types still refined" do
      ctx = %{Check.new() | adts: %{Nat: nat_decl()}}
      ctx = extend(ctx, :n, {:vdata, :Nat, []}, :omega)

      # case n do zero -> 0; succ(m) -> 1 end
      term =
        {:case, {:var, 0},
         [
           {:zero, 0, {:lit, 0}},
           {:succ, 1, {:lit, 1}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end

    test "parameterized Option still refines field types" do
      option_decl = %{
        name: :Option,
        params: [{:a, {:type, {:llit, 0}}}],
        constructors: [
          %{name: :none, fields: [], return_type: nil, span: nil},
          %{name: :some, fields: [{:var, 0}], return_type: nil, span: nil}
        ],
        universe_level: {:lsucc, {:llit, 0}},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Option: option_decl}}
      ctx = extend(ctx, :o, {:vdata, :Option, [{:vbuiltin, :Int}]}, :omega)

      # case o do none -> 0; some(x) -> x end
      # x should have type Int.
      term =
        {:case, {:var, 0},
         [
           {:none, 0, {:lit, 0}},
           {:some, 1, {:var, 0}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end
  end

  # ============================================================================
  # Deeper GADT index refinement
  # ============================================================================

  describe "deeper index refinement" do
    test "vcons against Vec(Int, succ(succ(zero))) refines rest to Vec(Int, succ(zero))" do
      ctx = check_ctx()
      scrut_type = vec_type({:vbuiltin, :Int}, vsucc(vsucc(vzero())))
      ctx = extend(ctx, :v, scrut_type, :omega)

      # case v do vcons(x, rest) -> rest end
      term =
        {:case, {:var, 0},
         [
           {:vcons, 2, {:var, 0}}
         ]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)

      assert {:vdata, :Vec, [{:vbuiltin, :Int}, {:vcon, :Nat, :succ, [{:vcon, :Nat, :zero, []}]}]} =
               type
    end
  end

  # ============================================================================
  # :gadt meta kind — post_process ignores unsolved GADT metas
  # ============================================================================

  describe ":gadt meta kind" do
    test "unsolved :gadt metas do not cause post_process errors" do
      ms = MetaState.new()
      {_id, ms} = MetaState.fresh_meta(ms, {:vdata, :Nat, []}, 0, :gadt)
      ctx = Check.from_meta_state(ms)

      # post_process should succeed despite the unsolved :gadt meta.
      assert {:ok, _ctx} = Check.post_process(ctx)
    end

    test "unsolved :implicit metas still cause post_process errors" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vdata, :Nat, []}, 0, :implicit)
      ctx = Check.from_meta_state(ms)

      assert {:error, {:unsolved_meta, ^id, _}} = Check.post_process(ctx)
    end
  end

  # ============================================================================
  # apply_index_equations — type-level reduction in expected types
  # ============================================================================

  describe "apply_index_equations via check mode" do
    test "vnil branch: expected Vec(Int, add(n, m)) reduces to Vec(Int, m)" do
      # When scrutinee is Vec(Int, n) and we match vnil, GADT says n = zero.
      # The expected type Vec(Int, add(n, m)) should reduce to Vec(Int, m).
      add_body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1,
              {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      ctx = %{check_ctx() | total_defs: %{add: {add_body, true}}}
      ctx = extend(ctx, :n, {:vdata, :Nat, []}, :zero)
      ctx = extend(ctx, :m, {:vdata, :Nat, []}, :zero)

      n_val = {:vneutral, {:vdata, :Nat, []}, {:nvar, Context.level(ctx.context) - 2}}
      m_val = {:vneutral, {:vdata, :Nat, []}, {:nvar, Context.level(ctx.context) - 1}}

      scrut_type = vec_type({:vbuiltin, :Int}, n_val)
      ctx = extend(ctx, :xs, scrut_type, :omega)
      ctx = extend(ctx, :ys, vec_type({:vbuiltin, :Int}, m_val), :omega)

      # Expected return type: Vec(Int, add(n, m))
      add_applied = {:app, {:app, {:def_ref, :add}, {:var, 3}}, {:var, 2}}
      expected_type_core = {:data, :Vec, [{:builtin, :Int}, add_applied]}

      expected =
        Haruspex.Eval.eval(
          %{
            env: Context.env(ctx.context),
            metas: %{},
            defs: ctx.total_defs,
            fuel: 1000
          },
          expected_type_core
        )

      # case xs do vnil -> ys end
      # In vnil branch, n = zero, so expected becomes Vec(Int, add(zero, m)) = Vec(Int, m).
      # ys : Vec(Int, m) should check against this.
      term = {:case, {:var, 1}, [{:vnil, 0, {:var, 0}}]}

      {:ok, _checked, _ctx} = Check.check(ctx, term, expected)
    end

    test "vcons branch: rest has refined type Vec(Int, k) under expected Vec(Int, add(n, m))" do
      add_body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1,
              {:con, :Nat, :succ, [{:app, {:app, {:def_ref, :add}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      ctx = %{check_ctx() | total_defs: %{add: {add_body, true}}}
      ctx = extend(ctx, :n, {:vdata, :Nat, []}, :zero)
      ctx = extend(ctx, :m, {:vdata, :Nat, []}, :zero)

      n_val = {:vneutral, {:vdata, :Nat, []}, {:nvar, Context.level(ctx.context) - 2}}

      scrut_type = vec_type({:vbuiltin, :Int}, n_val)
      ctx = extend(ctx, :v, scrut_type, :omega)

      # Synth: case v do vcons(x, rest) -> rest end
      # In the vcons branch, rest : Vec(Int, k) where k is a GADT existential.
      term = {:case, {:var, 0}, [{:vcons, 2, {:var, 0}}]}

      {:ok, _checked, type, _ctx} = Check.synth(ctx, term)
      # The result type should be Vec(Int, some_nat) — not a placeholder type.
      assert {:vdata, :Vec, [{:vbuiltin, :Int}, _k]} = type
    end
  end
end
