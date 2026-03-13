defmodule Haruspex.CheckTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Check
  alias Haruspex.Context
  alias Haruspex.Unify.MetaState

  # ============================================================================
  # Synth tests
  # ============================================================================

  describe "synth/2 — variables" do
    test "var at index 0 synthesizes the bound type" do
      ctx =
        Check.new()
        |> extend(:x, {:vbuiltin, :Int}, :omega)

      assert {:ok, {:var, 0}, {:vbuiltin, :Int}, _ctx} = Check.synth(ctx, {:var, 0})
    end

    test "var at deeper index synthesizes correct type" do
      ctx =
        Check.new()
        |> extend(:x, {:vbuiltin, :Int}, :omega)
        |> extend(:y, {:vbuiltin, :Float}, :omega)

      assert {:ok, {:var, 1}, {:vbuiltin, :Int}, _ctx} = Check.synth(ctx, {:var, 1})
      assert {:ok, {:var, 0}, {:vbuiltin, :Float}, _ctx} = Check.synth(ctx, {:var, 0})
    end
  end

  describe "synth/2 — literals" do
    test "integer literal synthesizes Int" do
      assert {:ok, {:lit, 42}, {:vbuiltin, :Int}, _} = Check.synth(Check.new(), {:lit, 42})
    end

    test "float literal synthesizes Float" do
      assert {:ok, {:lit, 3.14}, {:vbuiltin, :Float}, _} = Check.synth(Check.new(), {:lit, 3.14})
    end

    test "string literal synthesizes String" do
      assert {:ok, {:lit, "hello"}, {:vbuiltin, :String}, _} =
               Check.synth(Check.new(), {:lit, "hello"})
    end

    test "boolean literal synthesizes Bool" do
      assert {:ok, {:lit, true}, {:vbuiltin, :Bool}, _} = Check.synth(Check.new(), {:lit, true})
      assert {:ok, {:lit, false}, {:vbuiltin, :Bool}, _} = Check.synth(Check.new(), {:lit, false})
    end

    test "atom literal synthesizes Atom" do
      assert {:ok, {:lit, :foo}, {:vbuiltin, :Atom}, _} = Check.synth(Check.new(), {:lit, :foo})
    end
  end

  describe "synth/2 — types and universes" do
    test "builtin Int synthesizes Type 0" do
      assert {:ok, {:builtin, :Int}, {:vtype, {:llit, 0}}, _} =
               Check.synth(Check.new(), {:builtin, :Int})
    end

    test "builtin Float synthesizes Type 0" do
      assert {:ok, {:builtin, :Float}, {:vtype, {:llit, 0}}, _} =
               Check.synth(Check.new(), {:builtin, :Float})
    end

    test "Type 0 synthesizes Type 1" do
      assert {:ok, {:type, {:llit, 0}}, {:vtype, {:lsucc, {:llit, 0}}}, _} =
               Check.synth(Check.new(), {:type, {:llit, 0}})
    end

    test "Type 1 synthesizes Type 2" do
      assert {:ok, {:type, {:llit, 1}}, {:vtype, {:lsucc, {:llit, 1}}}, _} =
               Check.synth(Check.new(), {:type, {:llit, 1}})
    end
  end

  describe "synth/2 — Pi types" do
    test "Pi(omega, Int, Int) synthesizes a Type" do
      {:ok, _term, type, _ctx} =
        Check.synth(Check.new(), {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}})

      assert {:vtype, _level} = type
    end
  end

  describe "synth/2 — Sigma types" do
    test "Sigma(Int, Int) synthesizes a Type" do
      {:ok, _term, type, _ctx} =
        Check.synth(Check.new(), {:sigma, {:builtin, :Int}, {:builtin, :Int}})

      assert {:vtype, _level} = type
    end
  end

  describe "synth/2 — application" do
    test "applying a function binding to a literal" do
      # Put f : Pi(:omega, Int, Int) in context, then synth (f 42).
      pi_type = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      ctx =
        Check.new()
        |> extend(:f, pi_type, :omega)

      assert {:ok, {:app, {:var, 0}, {:lit, 42}}, result_type, _ctx} =
               Check.synth(ctx, {:app, {:var, 0}, {:lit, 42}})

      assert result_type == {:vbuiltin, :Int}
    end
  end

  describe "synth/2 — pairs and projections" do
    test "pair of literals can be synthed" do
      {:ok, {:pair, {:lit, 1}, {:lit, 2}}, sig_type, _ctx} =
        Check.synth(Check.new(), {:pair, {:lit, 1}, {:lit, 2}})

      assert {:vsigma, {:vbuiltin, :Int}, _, _} = sig_type
    end

    test "fst of a synthed pair returns first component type" do
      {:ok, _term, fst_type, _ctx} =
        Check.synth(Check.new(), {:fst, {:pair, {:lit, 1}, {:lit, 2}}})

      assert fst_type == {:vbuiltin, :Int}
    end

    test "snd of a synthed pair returns second component type" do
      {:ok, _term, snd_type, _ctx} =
        Check.synth(Check.new(), {:snd, {:pair, {:lit, 1}, {:lit, 2}}})

      assert snd_type == {:vbuiltin, :Int}
    end
  end

  describe "synth/2 — let" do
    test "let x = 1 in x synthesizes Int" do
      {:ok, {:let, {:lit, 1}, {:var, 0}}, type, _ctx} =
        Check.synth(Check.new(), {:let, {:lit, 1}, {:var, 0}})

      assert type == {:vbuiltin, :Int}
    end
  end

  describe "synth/2 — builtins" do
    test "builtin :add synthesizes Int -> Int -> Int" do
      {:ok, {:builtin, :add}, type, _ctx} = Check.synth(Check.new(), {:builtin, :add})
      assert {:vpi, :omega, {:vbuiltin, :Int}, [], _cod} = type
    end

    test "builtin :fadd synthesizes Float -> Float -> Float" do
      {:ok, {:builtin, :fadd}, type, _ctx} = Check.synth(Check.new(), {:builtin, :fadd})
      assert {:vpi, :omega, {:vbuiltin, :Float}, [], _cod} = type
    end

    test "builtin :neg synthesizes Int -> Int" do
      {:ok, {:builtin, :neg}, type, _ctx} = Check.synth(Check.new(), {:builtin, :neg})
      assert {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}} = type
    end

    test "builtin :eq synthesizes Int -> Int -> Atom" do
      {:ok, {:builtin, :eq}, type, _ctx} = Check.synth(Check.new(), {:builtin, :eq})
      assert {:vpi, :omega, {:vbuiltin, :Int}, [], _cod} = type
    end
  end

  describe "synth/2 — meta" do
    test "unsolved meta synthesizes its type" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      ctx = Check.from_meta_state(ms)

      assert {:ok, {:meta, ^id}, {:vbuiltin, :Int}, _} = Check.synth(ctx, {:meta, id})
    end

    test "solved meta synthesizes through the solution" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})
      ctx = Check.from_meta_state(ms)

      {:ok, term, type, _ctx} = Check.synth(ctx, {:meta, id})
      assert type == {:vbuiltin, :Int}
      assert term == {:lit, 42}
    end
  end

  describe "synth/2 — spanned" do
    test "spanned unwraps to inner term" do
      span = Pentiment.Span.Byte.new(0, 5)

      assert {:ok, {:lit, 42}, {:vbuiltin, :Int}, _} =
               Check.synth(Check.new(), {:spanned, span, {:lit, 42}})
    end
  end

  # ============================================================================
  # Check tests
  # ============================================================================

  describe "check/3 — lambda against Pi" do
    test "identity lambda checks against Pi(omega, Int, Int)" do
      pi_type = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:ok, {:lam, :omega, {:var, 0}}, _ctx} =
               Check.check(Check.new(), {:lam, :omega, {:var, 0}}, pi_type)
    end

    test "constant lambda checks against Pi" do
      pi_type = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:ok, {:lam, :omega, {:lit, 7}}, _ctx} =
               Check.check(Check.new(), {:lam, :omega, {:lit, 7}}, pi_type)
    end
  end

  describe "check/3 — pair against Sigma" do
    test "pair of literals checks against non-dependent Sigma" do
      sig_type = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:ok, {:pair, {:lit, 1}, {:lit, 2}}, _ctx} =
               Check.check(Check.new(), {:pair, {:lit, 1}, {:lit, 2}}, sig_type)
    end
  end

  describe "check/3 — let" do
    test "let x = 1 in x checks against Int" do
      assert {:ok, {:let, {:lit, 1}, {:var, 0}}, _ctx} =
               Check.check(Check.new(), {:let, {:lit, 1}, {:var, 0}}, {:vbuiltin, :Int})
    end
  end

  describe "check/3 — fallback (synth + unify)" do
    test "literal checks against its own type" do
      assert {:ok, {:lit, 42}, _ctx} =
               Check.check(Check.new(), {:lit, 42}, {:vbuiltin, :Int})
    end

    test "builtin type checks against Type 0" do
      assert {:ok, {:builtin, :Int}, _ctx} =
               Check.check(Check.new(), {:builtin, :Int}, {:vtype, {:llit, 0}})
    end
  end

  # ============================================================================
  # Error tests
  # ============================================================================

  describe "errors" do
    test "applying a non-function produces not_a_function" do
      assert {:error, {:not_a_function, {:vbuiltin, :Int}}} =
               Check.synth(Check.new(), {:app, {:lit, 42}, {:lit, 1}})
    end

    test "projecting from a non-pair produces not_a_pair" do
      assert {:error, {:not_a_pair, {:vbuiltin, :Int}}} =
               Check.synth(Check.new(), {:fst, {:lit, 42}})
    end

    test "snd of a non-pair produces not_a_pair" do
      assert {:error, {:not_a_pair, {:vbuiltin, :Int}}} =
               Check.synth(Check.new(), {:snd, {:lit, 42}})
    end

    test "type mismatch: literal checked against wrong type" do
      assert {:error, {:type_mismatch, {:vbuiltin, :Float}, {:vbuiltin, :Int}}} =
               Check.check(Check.new(), {:lit, 42}, {:vbuiltin, :Float})
    end

    test "multiplicity mismatch between lambda and Pi" do
      pi_type = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:error, {:multiplicity_mismatch, :omega, :zero}} =
               Check.check(Check.new(), {:lam, :zero, {:var, 0}}, pi_type)
    end

    test "not_a_type when Pi domain is not a type" do
      # Pi where domain is a literal (not a type).
      assert {:error, {:not_a_type, {:vbuiltin, :Int}}} =
               Check.synth(Check.new(), {:pi, :omega, {:lit, 42}, {:builtin, :Int}})
    end
  end

  # ============================================================================
  # Multiplicity tests
  # ============================================================================

  describe "multiplicity tracking" do
    test "zero-mult lambda that uses the binding fails" do
      # Lambda with :zero mult that uses var 0 — should fail.
      pi_type = {:vpi, :zero, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:error, {:multiplicity_violation, _name, :zero, 1}} =
               Check.check(Check.new(), {:lam, :zero, {:var, 0}}, pi_type)
    end

    test "zero-mult lambda that does not use the binding succeeds" do
      pi_type = {:vpi, :zero, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:ok, {:lam, :zero, {:lit, 42}}, _ctx} =
               Check.check(Check.new(), {:lam, :zero, {:lit, 42}}, pi_type)
    end

    test "omega-mult lambda can use the binding multiple times" do
      # Build Pi(:omega, Int, Int) — body uses var 0 (identity).
      pi_type = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}

      assert {:ok, {:lam, :omega, {:var, 0}}, _ctx} =
               Check.check(Check.new(), {:lam, :omega, {:var, 0}}, pi_type)
    end
  end

  # ============================================================================
  # Zonking tests
  # ============================================================================

  describe "zonk/3" do
    test "solved meta is replaced by its solution" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert Check.zonk(ms, 0, {:meta, id}) == {:lit, 42}
    end

    test "unsolved meta is left as-is" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)

      assert Check.zonk(ms, 0, {:meta, id}) == {:meta, id}
    end

    test "zonk descends into app" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 1})

      assert Check.zonk(ms, 0, {:app, {:meta, id}, {:lit, 2}}) == {:app, {:lit, 1}, {:lit, 2}}
    end

    test "zonk descends into lam" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 99})

      assert Check.zonk(ms, 0, {:lam, :omega, {:meta, id}}) == {:lam, :omega, {:lit, 99}}
    end

    test "zonk descends into pi" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vbuiltin, :Int})

      assert Check.zonk(ms, 0, {:pi, :omega, {:meta, id}, {:builtin, :Int}}) ==
               {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
    end

    test "zonk descends into pair" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 5})

      assert Check.zonk(ms, 0, {:pair, {:meta, id}, {:lit, 6}}) == {:pair, {:lit, 5}, {:lit, 6}}
    end

    test "zonk leaves non-meta terms unchanged" do
      ms = MetaState.new()
      assert Check.zonk(ms, 0, {:lit, 42}) == {:lit, 42}
      assert Check.zonk(ms, 0, {:var, 0}) == {:var, 0}
      assert Check.zonk(ms, 0, {:builtin, :Int}) == {:builtin, :Int}
      assert Check.zonk(ms, 0, {:type, {:llit, 0}}) == {:type, {:llit, 0}}
    end
  end

  # ============================================================================
  # Post-processing tests
  # ============================================================================

  describe "post_process/1" do
    test "succeeds with no metas and no constraints" do
      assert {:ok, _ctx} = Check.post_process(Check.new())
    end

    test "hole meta produces a hole report" do
      ms = MetaState.new()
      {_id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :hole)
      ctx = Check.from_meta_state(ms)

      assert {:ok, ctx} = Check.post_process(ctx)
      assert [%{expected_type: "Int", bindings: []}] = ctx.hole_reports
    end

    test "unsolved implicit meta produces an error" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      ctx = Check.from_meta_state(ms)

      assert {:error, {:unsolved_meta, ^id, {:vbuiltin, :Int}}} = Check.post_process(ctx)
    end

    test "level solving succeeds for empty constraints" do
      assert {:ok, _} = Check.post_process(Check.new())
    end
  end

  # ============================================================================
  # Definition checking tests
  # ============================================================================

  describe "check_definition/4" do
    test "checks identity function definition" do
      # type: Pi(:omega, Int, Int)
      # body: lam(:omega, var(0)) — identity, but in check_definition the body is
      #       checked inside a context extended with the definition name.
      #       So var(0) refers to the lambda's argument, var(1) to the definition itself.
      type_term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body_term = {:lam, :omega, {:var, 0}}

      assert {:ok, checked_body, _ctx} =
               Check.check_definition(Check.new(), :id, type_term, body_term)

      assert {:lam, :omega, {:var, 0}} = checked_body
    end

    test "checks constant function definition" do
      type_term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body_term = {:lam, :omega, {:lit, 0}}

      assert {:ok, {:lam, :omega, {:lit, 0}}, _ctx} =
               Check.check_definition(Check.new(), :zero, type_term, body_term)
    end
  end

  # ============================================================================
  # Integration tests (from spec)
  # ============================================================================

  describe "integration — end-to-end definition checking" do
    test "addition: Pi(omega, Int, Pi(omega, Int, Int)) body = add x y" do
      # type: Int -> Int -> Int
      # body: lam(omega, lam(omega, app(app(builtin(:add), var(1)), var(0))))
      type_term =
        {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      body_term =
        {:lam, :omega, {:lam, :omega, {:app, {:app, {:builtin, :add}, {:var, 1}}, {:var, 0}}}}

      assert {:ok, checked, _ctx} =
               Check.check_definition(Check.new(), :add, type_term, body_term)

      # Body should be unchanged (no metas to zonk).
      assert {:lam, :omega, {:lam, :omega, {:app, {:app, {:builtin, :add}, _}, _}}} = checked
    end

    test "type error: body type doesn't match declared type" do
      # def bad(x : Int) : Float do x end
      type_term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Float}}
      body_term = {:lam, :omega, {:var, 0}}

      assert {:error, {:type_mismatch, {:vbuiltin, :Float}, {:vbuiltin, :Int}}} =
               Check.check_definition(Check.new(), :bad, type_term, body_term)
    end

    test "hole: body with meta produces hole report" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :hole)
      ctx = Check.from_meta_state(ms)

      type_term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body_term = {:lam, :omega, {:meta, id}}

      assert {:ok, _checked, ctx} =
               Check.check_definition(ctx, :f, type_term, body_term)

      assert [%{expected_type: "Int"}] = ctx.hole_reports
    end

    test "nested application checks correctly" do
      # def apply_twice(f : Int -> Int, x : Int) : Int do f(f(x)) end
      int_to_int = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      type_term = {:pi, :omega, int_to_int, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      # In context: apply_twice at ix 2, f at ix 1, x at ix 0
      # f(f(x)) = app(var(1), app(var(1), var(0)))
      body_term =
        {:lam, :omega, {:lam, :omega, {:app, {:var, 1}, {:app, {:var, 1}, {:var, 0}}}}}

      assert {:ok, _checked, _ctx} =
               Check.check_definition(Check.new(), :apply_twice, type_term, body_term)
    end

    test "constant function ignores second argument" do
      # def const(x : Int, y : Float) : Int do x end
      type_term =
        {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Float}, {:builtin, :Int}}}

      body_term = {:lam, :omega, {:lam, :omega, {:var, 1}}}

      assert {:ok, {:lam, :omega, {:lam, :omega, {:var, 1}}}, _ctx} =
               Check.check_definition(Check.new(), :const, type_term, body_term)
    end
  end

  # ============================================================================
  # Inserted meta synth
  # ============================================================================

  describe "synth/2 — inserted_meta" do
    test "inserted meta evaluates and re-synths" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})
      ctx = Check.from_meta_state(ms)

      # An inserted_meta with the solved meta.
      term = {:inserted_meta, id, []}

      {:ok, _term, type, _ctx} = Check.synth(ctx, term)
      assert type == {:vbuiltin, :Int}
    end
  end

  # ============================================================================
  # Zonking — additional coverage
  # ============================================================================

  describe "zonk/3 — additional" do
    test "zonk descends into sigma" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vbuiltin, :Int})

      assert Check.zonk(ms, 0, {:sigma, {:meta, id}, {:builtin, :Int}}) ==
               {:sigma, {:builtin, :Int}, {:builtin, :Int}}
    end

    test "zonk descends into fst" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 1})

      assert Check.zonk(ms, 0, {:fst, {:meta, id}}) == {:fst, {:lit, 1}}
    end

    test "zonk descends into snd" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 1})

      assert Check.zonk(ms, 0, {:snd, {:meta, id}}) == {:snd, {:lit, 1}}
    end

    test "zonk descends into let" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 1})

      assert Check.zonk(ms, 0, {:let, {:meta, id}, {:var, 0}}) == {:let, {:lit, 1}, {:var, 0}}
    end

    test "zonk descends into spanned" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 1})

      span = Pentiment.Span.Byte.new(0, 5)
      assert Check.zonk(ms, 0, {:spanned, span, {:meta, id}}) == {:spanned, span, {:lit, 1}}
    end

    test "zonk on inserted_meta: solved" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert Check.zonk(ms, 0, {:inserted_meta, id, []}) == {:lit, 42}
    end

    test "zonk on inserted_meta: unsolved" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)

      assert Check.zonk(ms, 0, {:inserted_meta, id, []}) == {:inserted_meta, id, []}
    end
  end

  # ============================================================================
  # Builtin op types — additional coverage
  # ============================================================================

  describe "builtin op types — additional" do
    test "builtin :not synthesizes Bool -> Bool" do
      {:ok, {:builtin, :not}, type, _ctx} = Check.synth(Check.new(), {:builtin, :not})
      assert {:vpi, :omega, {:vbuiltin, :Bool}, [], {:builtin, :Bool}} = type
    end

    test "builtin :and synthesizes Bool -> Bool -> Bool" do
      {:ok, {:builtin, :and}, type, _ctx} = Check.synth(Check.new(), {:builtin, :and})
      assert {:vpi, :omega, {:vbuiltin, :Bool}, [], _cod} = type
    end

    test "builtin :or synthesizes Bool -> Bool -> Bool" do
      {:ok, {:builtin, :or}, type, _ctx} = Check.synth(Check.new(), {:builtin, :or})
      assert {:vpi, :omega, {:vbuiltin, :Bool}, [], _cod} = type
    end

    test "unknown builtin synthesizes Type 0" do
      {:ok, {:builtin, :unknown_op}, type, _ctx} =
        Check.synth(Check.new(), {:builtin, :unknown_op})

      assert type == {:vtype, {:llit, 0}}
    end
  end

  # ============================================================================
  # Post-processing — universe error
  # ============================================================================

  describe "post_process — universe error" do
    test "unsatisfiable level constraints produce universe error" do
      ms = MetaState.new()
      # Create a cycle: ?l0 = succ(?l0).
      ms = MetaState.add_constraint(ms, {:eq, {:lvar, 0}, {:lsucc, {:lvar, 0}}})
      ctx = Check.from_meta_state(ms)

      assert {:error, {:universe_error, _}} = Check.post_process(ctx)
    end
  end

  # ============================================================================
  # Post-process — solved metas are skipped
  # ============================================================================

  describe "post_process — solved metas" do
    test "solved metas are skipped in post_process reduce" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})
      ctx = Check.from_meta_state(ms)

      # The solved meta hits the `_, acc` catch-all branch.
      assert {:ok, _ctx} = Check.post_process(ctx)
    end

    test "mix of solved and hole metas" do
      ms = MetaState.new()
      {id_solved, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id_solved, {:vlit, 42})
      {_id_hole, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Float}, 0, :hole)
      ctx = Check.from_meta_state(ms)

      assert {:ok, ctx} = Check.post_process(ctx)
      assert [%{expected_type: "Float"}] = ctx.hole_reports
    end
  end

  # ============================================================================
  # Collect bindings
  # ============================================================================

  describe "collect_bindings — coverage" do
    test "hole report includes bindings from context" do
      ms = MetaState.new()
      {_id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :hole)
      ctx = %{Check.from_meta_state(ms) | names: [:x]}
      ctx = extend(ctx, :x, {:vbuiltin, :Int}, :omega)

      assert {:ok, ctx} = Check.post_process(ctx)
      assert [%{bindings: bindings}] = ctx.hole_reports
      assert length(bindings) > 0
      assert {_, "Int"} = List.last(bindings)
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "synth is deterministic for literals" do
      check all(
              lit <-
                one_of([
                  map(integer(), &{:lit, &1}),
                  map(float(min: -1.0e10, max: 1.0e10), &{:lit, &1}),
                  map(string(:alphanumeric, min_length: 0, max_length: 10), &{:lit, &1})
                ])
            ) do
        {:ok, term1, type1, _} = Check.synth(Check.new(), lit)
        {:ok, term2, type2, _} = Check.synth(Check.new(), lit)

        assert term1 == term2
        assert type1 == type2
      end
    end

    property "type preservation: synthed literals check against their own type" do
      check all(
              lit <-
                one_of([
                  map(integer(), &{:lit, &1}),
                  map(float(min: -1.0e10, max: 1.0e10), &{:lit, &1}),
                  map(string(:alphanumeric, min_length: 0, max_length: 10), &{:lit, &1})
                ])
            ) do
        {:ok, _term, type, _ctx} = Check.synth(Check.new(), lit)
        assert {:ok, _, _} = Check.check(Check.new(), lit, type)
      end
    end

    property "zonk is idempotent for terms without metas" do
      check all(
              lit <-
                one_of([
                  map(integer(), &{:lit, &1}),
                  map(float(min: -1.0e10, max: 1.0e10), &{:lit, &1})
                ])
            ) do
        ms = MetaState.new()
        assert Check.zonk(ms, 0, lit) == lit
      end
    end
  end

  # ============================================================================
  # Synth — ADT data type with known and unknown ADTs
  # ============================================================================

  describe "synth/2 — data type constructor" do
    test "data type with known ADT synthesizes with correct universe level" do
      # Register a parameterized Option ADT.
      option_decl = %{
        name: :Option,
        params: [{:a, {:type, {:llit, 0}}}],
        constructors: [
          %{name: :none, fields: [], return_type: nil, span: nil},
          %{name: :some, fields: [{:var, 0}], return_type: nil, span: nil}
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Option: option_decl}}

      # Synth {:data, :Option, [{:builtin, :Int}]} — Option applied to Int.
      {:ok, {:data, :Option, [{:builtin, :Int}]}, type, _ctx} =
        Check.synth(ctx, {:data, :Option, [{:builtin, :Int}]})

      assert {:vtype, {:llit, 0}} = type
    end

    test "data type with unknown ADT synthesizes as Type 0" do
      ctx = Check.new()

      {:ok, {:data, :Unknown, []}, type, _ctx} =
        Check.synth(ctx, {:data, :Unknown, []})

      assert {:vtype, {:llit, 0}} = type
    end
  end

  # ============================================================================
  # Synth — constructor with known and unknown ADT
  # ============================================================================

  describe "synth/2 — con with ADT context" do
    test "constructor with known ADT synthesizes through constructor type" do
      nat_decl = %{
        name: :Nat,
        params: [],
        constructors: [
          %{name: :zero, fields: [], return_type: nil, span: nil},
          %{name: :succ, fields: [{:data, :Nat, []}], return_type: nil, span: nil}
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Nat: nat_decl}}

      # Synth {:con, :Nat, :zero, []} — nullary constructor.
      {:ok, {:con, :Nat, :zero, []}, type, _ctx} =
        Check.synth(ctx, {:con, :Nat, :zero, []})

      assert {:vdata, :Nat, []} = type
    end

    test "constructor with unknown ADT synthesizes structurally" do
      ctx = Check.new()

      {:ok, {:con, :Unknown, :mk, [{:lit, 1}]}, type, _ctx} =
        Check.synth(ctx, {:con, :Unknown, :mk, [{:lit, 1}]})

      assert {:vdata, :Unknown, []} = type
    end
  end

  # ============================================================================
  # Zonk — data, con, record_proj
  # ============================================================================

  describe "zonk/3 — data, con, record_proj" do
    test "zonk descends into data args" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert Check.zonk(ms, 0, {:data, :Option, [{:meta, id}]}) ==
               {:data, :Option, [{:lit, 42}]}
    end

    test "zonk descends into con args" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert Check.zonk(ms, 0, {:con, :Option, :some, [{:meta, id}]}) ==
               {:con, :Option, :some, [{:lit, 42}]}
    end

    test "zonk descends into record_proj" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 42})

      assert Check.zonk(ms, 0, {:record_proj, :x, {:meta, id}}) ==
               {:record_proj, :x, {:lit, 42}}
    end

    test "zonk descends into case branches" do
      ms = MetaState.new()
      {id, ms} = MetaState.fresh_meta(ms, {:vbuiltin, :Int}, 0, :implicit)
      {:ok, ms} = MetaState.solve(ms, id, {:vlit, 99})

      term =
        {:case, {:var, 0},
         [
           {:__lit, true, {:meta, id}},
           {:some, 1, {:meta, id}}
         ]}

      result = Check.zonk(ms, 0, term)

      assert {:case, {:var, 0},
              [
                {:__lit, true, {:lit, 99}},
                {:some, 1, {:lit, 99}}
              ]} = result
    end
  end

  # ============================================================================
  # Record projection desugaring error paths
  # ============================================================================

  describe "synth/2 — record_proj error paths" do
    test "record_proj on non-record type returns not_a_record" do
      ctx = Check.new()

      # Synth record_proj(:x, 42) — 42 is Int, not a record type.
      assert {:error, {:not_a_record, {:vbuiltin, :Int}, :x}} =
               Check.synth(ctx, {:record_proj, :x, {:lit, 42}})
    end

    test "record_proj on unknown record type returns not_a_record" do
      # The scrutinee has type {:vdata, :UnknownRec, []} but no record is registered.
      nat_decl = %{
        name: :Foo,
        params: [],
        constructors: [%{name: :mk_Foo, fields: [{:builtin, :Int}], return_type: nil, span: nil}],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Foo: nat_decl}}
      ctx = extend(ctx, :r, {:vdata, :Foo, []}, :omega)

      # Project field :x from r : Foo — but Foo is not in records map.
      assert {:error, {:not_a_record, {:vdata, :Foo, []}, :x}} =
               Check.synth(ctx, {:record_proj, :x, {:var, 0}})
    end

    test "record_proj on known record but unknown field returns not_a_record" do
      record_decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Int}}, {:y, {:builtin, :Int}}],
        constructor_name: :mk_Point,
        span: nil
      }

      point_adt = %{
        name: :Point,
        params: [],
        constructors: [
          %{
            name: :mk_Point,
            fields: [{:builtin, :Int}, {:builtin, :Int}],
            return_type: nil,
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | records: %{Point: record_decl}, adts: %{Point: point_adt}}
      ctx = extend(ctx, :p, {:vdata, :Point, []}, :omega)

      # Project field :z which doesn't exist on Point.
      assert {:error, {:not_a_record, {:vdata, :Point, []}, :z}} =
               Check.synth(ctx, {:record_proj, :z, {:var, 0}})
    end
  end

  # ============================================================================
  # Case branch context extension — wildcard and fallback
  # ============================================================================

  describe "synth/2 — case with wildcard and fallback patterns" do
    test "case with wildcard 0-binder branch" do
      ctx = Check.new()

      # case 42 do _ -> 1 end (wildcard binds nothing).
      term = {:case, {:lit, 42}, [{:_, 0, {:lit, 1}}]}

      {:ok, {:case, {:lit, 42}, [{:_, 0, {:lit, 1}}]}, type, _ctx} =
        Check.synth(ctx, term)

      assert {:vbuiltin, :Int} = type
    end

    test "case with wildcard 1-binder branch" do
      ctx = Check.new()

      # case 42 do x -> x end (wildcard binds scrutinee).
      term = {:case, {:lit, 42}, [{:_, 1, {:var, 0}}]}
      {:ok, _case_term, type, _ctx} = Check.synth(ctx, term)

      assert {:vbuiltin, :Int} = type
    end

    test "case with constructor branch and fallback field types" do
      ctx = Check.new()

      # case 42 do succ(n) -> n end — Int is not an ADT, so constructor_field_types
      # falls back to placeholder types.
      term = {:case, {:lit, 42}, [{:succ, 1, {:var, 0}}]}
      {:ok, _case_term, type, _ctx} = Check.synth(ctx, term)

      # The branch body type is the fallback {:vtype, {:llit, 0}} since
      # the var is bound with that type.
      assert type != nil
    end

    test "case with literal branch" do
      ctx = Check.new()

      # case 42 do 42 -> true; _ -> false end
      term =
        {:case, {:lit, 42},
         [
           {:__lit, 42, {:lit, true}},
           {:_, 0, {:lit, false}}
         ]}

      {:ok, _case_term, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Bool} = type
    end
  end

  # ============================================================================
  # Case with known ADT constructor field types
  # ============================================================================

  describe "synth/2 — case with ADT constructor branches" do
    test "constructor branch gets proper field types from ADT" do
      nat_decl = %{
        name: :Nat,
        params: [],
        constructors: [
          %{name: :zero, fields: [], return_type: nil, span: nil},
          %{name: :succ, fields: [{:data, :Nat, []}], return_type: nil, span: nil}
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ctx = %{Check.new() | adts: %{Nat: nat_decl}}
      ctx = extend(ctx, :n, {:vdata, :Nat, []}, :omega)

      # case n do zero -> 0; succ(m) -> 1 end
      term =
        {:case, {:var, 0},
         [
           {:zero, 0, {:lit, 0}},
           {:succ, 1, {:lit, 1}}
         ]}

      {:ok, _case_term, type, _ctx} = Check.synth(ctx, term)
      assert {:vbuiltin, :Int} = type
    end
  end

  # ============================================================================
  # Check definition — extern
  # ============================================================================

  describe "check_definition/4 — extern" do
    test "extern with matching arity succeeds" do
      type_term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body_term = {:extern, :math, :sqrt, 1}

      assert {:ok, {:extern, :math, :sqrt, 1}, _ctx} =
               Check.check_definition(Check.new(), :my_sqrt, type_term, body_term)
    end

    test "extern with mismatched arity fails" do
      type_term =
        {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      body_term = {:extern, :math, :sqrt, 1}

      assert {:error, {:extern_arity_mismatch, :my_sqrt, :math, :sqrt, 1, 2}} =
               Check.check_definition(Check.new(), :my_sqrt, type_term, body_term)
    end
  end

  # ============================================================================
  # Check definition — global
  # ============================================================================

  describe "check_definition/4 — global" do
    test "global with matching arity succeeds" do
      type_term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body_term = {:global, Kernel, :abs, 1}

      assert {:ok, {:global, Kernel, :abs, 1}, _ctx} =
               Check.check_definition(Check.new(), :my_abs, type_term, body_term)
    end

    test "global with mismatched arity fails" do
      type_term =
        {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      body_term = {:global, Kernel, :abs, 1}

      assert {:error, {:global_arity_mismatch, :my_abs, 1, 2}} =
               Check.check_definition(Check.new(), :my_abs, type_term, body_term)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Extend a check context by directly manipulating the inner context.
  defp extend(ctx, name, type, mult) do
    %{ctx | context: Context.extend(ctx.context, name, type, mult), names: ctx.names ++ [name]}
  end
end
