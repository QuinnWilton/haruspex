defmodule Haruspex.RecordTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Check
  alias Haruspex.Codegen
  alias Haruspex.Elaborate
  alias Haruspex.Erase
  alias Haruspex.Eval
  alias Haruspex.Parser
  alias Haruspex.Quote
  alias Haruspex.Record
  alias Haruspex.Tokenizer

  # ============================================================================
  # Helpers
  # ============================================================================

  # Parse source and elaborate type/record declarations, returning the elab context.
  defp elaborate_source(source) do
    {:ok, forms} = Parser.parse(source)
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

  defp eval_ctx, do: Eval.default_ctx()

  defp push_test_binding(ctx, name) do
    %{
      ctx
      | names: [{name, ctx.level} | ctx.names],
        name_list: ctx.name_list ++ [name],
        level: ctx.level + 1
    }
  end

  # ============================================================================
  # Record module
  # ============================================================================

  describe "record_to_adt" do
    test "simple record produces single-constructor ADT" do
      decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      adt = Record.record_to_adt(decl)

      assert adt.name == :Point
      assert length(adt.constructors) == 1

      [con] = adt.constructors
      assert con.name == :mk_Point
      assert con.fields == [{:builtin, :Float}, {:builtin, :Float}]
      assert con.return_type == {:data, :Point, []}
    end

    test "parameterized record produces correct return type" do
      decl = %{
        name: :Pair,
        params: [{:a, {:type, {:llit, 0}}}, {:b, {:type, {:llit, 0}}}],
        fields: [{:fst, {:var, 1}}, {:snd, {:var, 0}}],
        constructor_name: :mk_Pair,
        span: nil
      }

      adt = Record.record_to_adt(decl)

      [con] = adt.constructors
      # Under 2 fields + 2 params, param vars are at indices 3 and 2.
      assert {:data, :Pair, [{:var, 3}, {:var, 2}]} = con.return_type
    end

    test "constructor_name generates mk_ prefix" do
      assert :mk_Point = Record.constructor_name(:Point)
      assert :mk_Sigma = Record.constructor_name(:Sigma)
    end

    test "field_info returns index and type" do
      decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      assert {:ok, 0, {:builtin, :Float}} = Record.field_info(decl, :x)
      assert {:ok, 1, {:builtin, :Float}} = Record.field_info(decl, :y)
      assert :error = Record.field_info(decl, :z)
    end
  end

  # ============================================================================
  # Elaboration
  # ============================================================================

  describe "elaboration" do
    test "record declaration registers in context" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      assert Map.has_key?(ctx.records, :Point)
      assert Map.has_key?(ctx.adts, :Point)

      record = ctx.records[:Point]
      assert record.constructor_name == :mk_Point
      assert length(record.fields) == 2
      assert [{:x, _}, {:y, _}] = record.fields
    end

    test "record constructor name resolves during elaboration" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, {:var, nil, :mk_Point})
      assert {:con, :Point, :mk_Point, []} = core
    end

    test "record construction elaborates to con term" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # %Point{x: 1.0, y: 2.0}
      {:ok, core, _ctx} =
        Elaborate.elaborate(
          ctx,
          {:record_construct, nil, :Point, [{:x, {:lit, nil, 1.0}}, {:y, {:lit, nil, 2.0}}]}
        )

      assert {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]} = core
    end

    test "record construction reorders fields" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # Provide fields in reverse order.
      {:ok, core, _ctx} =
        Elaborate.elaborate(
          ctx,
          {:record_construct, nil, :Point, [{:y, {:lit, nil, 2.0}}, {:x, {:lit, nil, 1.0}}]}
        )

      # Fields should be in declaration order.
      assert {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]} = core
    end

    test "record construction errors on missing fields" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      result =
        Elaborate.elaborate(
          ctx,
          {:record_construct, nil, :Point, [{:x, {:lit, nil, 1.0}}]}
        )

      assert {:error, {:missing_record_fields, :Point, [:y], _}} = result
    end

    test "dot on bound variable elaborates to record_proj" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # Simulate: let p = ...; p.x
      # Push a binding for `p`.
      inner_ctx = %{
        ctx
        | names: [{:p, ctx.level} | ctx.names],
          name_list: ctx.name_list ++ [:p],
          level: ctx.level + 1
      }

      {:ok, core, _ctx} =
        Elaborate.elaborate(inner_ctx, {:dot, nil, {:var, nil, :p}, :x})

      assert {:record_proj, :x, {:var, 0}} = core
    end

    test "record pattern desugars to constructor pattern" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # case expr do %Point{x: x, y: y} -> x end
      case_ast =
        {:case, nil, {:var, nil, :mk_Point},
         [
           {:branch, nil,
            {:pat_record, nil, :Point, [{:x, {:pat_var, nil, :x}}, {:y, {:pat_var, nil, :y}}]},
            {:var, nil, :x}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, case_ast)

      # Should desugar to constructor pattern on mk_Point.
      assert {:case, _, [{:mk_Point, 2, _body}]} = core
    end

    test "partial record pattern fills wildcards" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # case expr do %Point{x: x} -> x end (y is wildcard)
      case_ast =
        {:case, nil, {:var, nil, :mk_Point},
         [
           {:branch, nil, {:pat_record, nil, :Point, [{:x, {:pat_var, nil, :x}}]},
            {:var, nil, :x}}
         ]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, case_ast)

      # Should still match mk_Point with arity 2 (wildcard for y).
      assert {:case, _, [{:mk_Point, 2, _body}]} = core
    end
  end

  # ============================================================================
  # Type checking
  # ============================================================================

  describe "type checking" do
    test "record type synths as Type" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      check_ctx = %{Check.new() | adts: ctx.adts, records: ctx.records}

      {:ok, _term, type, _ctx} = Check.synth(check_ctx, {:data, :Point, []})
      assert {:vtype, _} = type
    end

    test "record construction type checks" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      check_ctx = %{Check.new() | adts: ctx.adts, records: ctx.records}

      # mk_Point(1.0, 2.0)
      {:ok, _term, type, _ctx} =
        Check.synth(check_ctx, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]})

      assert {:vdata, :Point, []} = type
    end

    test "record projection desugars to case and gets correct type" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      check_ctx = %{Check.new() | adts: ctx.adts, records: ctx.records}

      # Let p = mk_Point(1.0, 2.0); p.x
      term =
        {:let, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]},
         {:record_proj, :x, {:var, 0}}}

      {:ok, checked, type, _ctx} = Check.synth(check_ctx, term)

      assert {:vbuiltin, :Float} = type

      # The record_proj should have been desugared into a case.
      assert {:let, _, {:case, {:var, 0}, [{:mk_Point, 2, {:var, 1}}]}} = checked
    end

    test "record projection on y field" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      check_ctx = %{Check.new() | adts: ctx.adts, records: ctx.records}

      # Let p = mk_Point(1.0, 2.0); p.y
      term =
        {:let, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]},
         {:record_proj, :y, {:var, 0}}}

      {:ok, checked, type, _ctx} = Check.synth(check_ctx, term)

      assert {:vbuiltin, :Float} = type

      # y is field index 1, so de Bruijn index = arity - 1 - 1 = 0.
      assert {:let, _, {:case, {:var, 0}, [{:mk_Point, 2, {:var, 0}}]}} = checked
    end
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  describe "evaluation" do
    test "record construction evaluates to vcon" do
      term = {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]}

      assert {:vcon, :Point, :mk_Point, [{:vlit, 1.0}, {:vlit, 2.0}]} =
               Eval.eval(eval_ctx(), term)
    end

    test "record projection via case extracts field" do
      # case mk_Point(1.0, 2.0) do mk_Point(x, y) -> x end
      term =
        {:case, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]},
         [{:mk_Point, 2, {:var, 1}}]}

      assert {:vlit, 1.0} = Eval.eval(eval_ctx(), term)
    end

    test "record projection via case for second field" do
      # case mk_Point(1.0, 2.0) do mk_Point(x, y) -> y end
      term =
        {:case, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]},
         [{:mk_Point, 2, {:var, 0}}]}

      assert {:vlit, 2.0} = Eval.eval(eval_ctx(), term)
    end
  end

  # ============================================================================
  # End-to-end
  # ============================================================================

  describe "end-to-end" do
    test "construct and project: eval → erase → codegen" do
      # let p = mk_Point(1.0, 2.0) in case p do mk_Point(x, y) -> x end
      term =
        {:let, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]},
         {:case, {:var, 0}, [{:mk_Point, 2, {:var, 1}}]}}

      # Eval.
      assert {:vlit, 1.0} = Eval.eval(eval_ctx(), term)

      # Erase and codegen.
      erased = Erase.erase(term, {:builtin, :Float})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 1.0 = result
    end

    test "pattern match on record: eval → erase → codegen" do
      # case mk_Point(3.0, 4.0) do mk_Point(x, y) -> x + y end
      term =
        {:case, {:con, :Point, :mk_Point, [{:lit, 3.0}, {:lit, 4.0}]},
         [{:mk_Point, 2, {:app, {:app, {:builtin, :fadd}, {:var, 1}}, {:var, 0}}}]}

      assert {:vlit, 7.0} = Eval.eval(eval_ctx(), term)

      erased = Erase.erase(term, {:builtin, :Float})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 7.0 = result
    end

    test "type check + codegen pipeline for record projection" do
      ctx = elaborate_source("record Point: x : Float, y : Float")
      check_ctx = %{Check.new() | adts: ctx.adts, records: ctx.records}

      # let p = mk_Point(1.0, 2.0); p.x
      term =
        {:let, {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]},
         {:record_proj, :x, {:var, 0}}}

      {:ok, checked, type, _ctx} = Check.synth(check_ctx, term)
      assert {:vbuiltin, :Float} = type

      # The checked term has record_proj desugared to case.
      erased = Erase.erase(checked, {:builtin, :Float})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 1.0 = result
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "property tests" do
    property "projection after construction retrieves original value" do
      check all(
              x <- float(min: -1000.0, max: 1000.0),
              y <- float(min: -1000.0, max: 1000.0)
            ) do
        # case mk_Point(x, y) do mk_Point(a, b) -> a end == x
        term_x =
          {:case, {:con, :Point, :mk_Point, [{:lit, x}, {:lit, y}]}, [{:mk_Point, 2, {:var, 1}}]}

        assert {:vlit, ^x} = Eval.eval(eval_ctx(), term_x)

        # case mk_Point(x, y) do mk_Point(a, b) -> b end == y
        term_y =
          {:case, {:con, :Point, :mk_Point, [{:lit, x}, {:lit, y}]}, [{:mk_Point, 2, {:var, 0}}]}

        assert {:vlit, ^y} = Eval.eval(eval_ctx(), term_y)
      end
    end

    property "record construction is a single-constructor ADT" do
      check all(n_fields <- integer(1..5)) do
        fields =
          Enum.map(1..n_fields, fn i ->
            {:"field_#{i}", {:builtin, :Int}}
          end)

        decl = %{
          name: :TestRecord,
          params: [],
          fields: fields,
          constructor_name: :mk_TestRecord,
          span: nil
        }

        adt = Record.record_to_adt(decl)
        assert length(adt.constructors) == 1
        [con] = adt.constructors
        assert con.name == :mk_TestRecord
        assert length(con.fields) == n_fields
      end
    end
  end

  # ============================================================================
  # Parser syntax
  # ============================================================================

  describe "parser" do
    test "tokenizer produces percent token" do
      {:ok, tokens} = Tokenizer.tokenize("%Point{x: 1}")
      assert Enum.any?(tokens, fn {tag, _, _} -> tag == :percent end)
    end

    test "parse record construction" do
      {:ok, forms} = Parser.parse("def f : Point do %Point{x: 1.0, y: 2.0} end")

      assert [
               {:def, _, _,
                {:record_construct, _, :Point, [{:x, {:lit, _, 1.0}}, {:y, {:lit, _, 2.0}}]}}
             ] = forms
    end

    test "parse empty record construction" do
      {:ok, forms} = Parser.parse("def f : Unit do %Unit{} end")
      assert [{:def, _, _, {:record_construct, _, :Unit, []}}] = forms
    end

    test "parse typed record update" do
      {:ok, forms} = Parser.parse("def f(p : Point) : Point do %Point{p | x: 3.0} end")

      [{:def, _, _, body}] = forms
      assert {:record_update, _, :Point, {:var, _, :p}, [{:x, {:lit, _, 3.0}}]} = body
    end

    test "parse untyped record update" do
      {:ok, forms} = Parser.parse("def f(p : Point) : Point do %{p | x: 3.0} end")

      [{:def, _, _, body}] = forms
      assert {:record_update, _, nil, {:var, _, :p}, [{:x, {:lit, _, 3.0}}]} = body
    end

    test "parse record pattern" do
      source = "def f(p : Point) : Float do case p do %Point{x: x, y: y} -> x end end"
      {:ok, forms} = Parser.parse(source)

      [{:def, _, _, {:case, _, {:var, _, :p}, [branch]}}] = forms

      assert {:branch, _,
              {:pat_record, _, :Point, [{:x, {:pat_var, _, :x}}, {:y, {:pat_var, _, :y}}]},
              {:var, _, :x}} = branch
    end

    test "parse partial record pattern" do
      source = "def f(p : Point) : Float do case p do %Point{x: x} -> x end end"
      {:ok, forms} = Parser.parse(source)

      [{:def, _, _, {:case, _, {:var, _, :p}, [branch]}}] = forms

      assert {:branch, _, {:pat_record, _, :Point, [{:x, {:pat_var, _, :x}}]}, {:var, _, :x}} =
               branch
    end
  end

  # ============================================================================
  # Record update
  # ============================================================================

  describe "record update" do
    test "typed update elaborates to case + reconstruction" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      {:ok, core, _ctx} =
        Elaborate.elaborate(
          ctx,
          {:record_update, nil, :Point, {:var, nil, :mk_Point}, [{:x, {:lit, nil, 3.0}}]}
        )

      # Should be: case mk_Point of mk_Point(f0, f1) -> mk_Point(3.0, f1)
      assert {:case, {:con, :Point, :mk_Point, []},
              [{:mk_Point, 2, {:con, :Point, :mk_Point, _args}}]} = core
    end

    test "untyped update resolves record from field names" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      {:ok, core, _ctx} =
        Elaborate.elaborate(
          ctx,
          {:record_update, nil, nil, {:var, nil, :mk_Point}, [{:x, {:lit, nil, 3.0}}]}
        )

      assert {:case, _, [{:mk_Point, 2, {:con, :Point, :mk_Point, _}}]} = core
    end

    test "update preserves untouched fields" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # mk_Point(1.0, 2.0) updated with x: 3.0
      update_ast =
        {:record_update, nil, :Point,
         {:record_construct, nil, :Point, [{:x, {:lit, nil, 1.0}}, {:y, {:lit, nil, 2.0}}]},
         [{:x, {:lit, nil, 3.0}}]}

      {:ok, core, _ctx} = Elaborate.elaborate(ctx, update_ast)

      # Eval the result.
      result = Eval.eval(eval_ctx(), core)
      assert {:vcon, :Point, :mk_Point, [{:vlit, 3.0}, {:vlit, 2.0}]} = result
    end

    test "update through full pipeline" do
      ctx = elaborate_source("record Point: x : Float, y : Float")

      # let p = mk_Point(1.0, 2.0); %Point{p | x: 5.0}.x
      construct =
        {:record_construct, nil, :Point, [{:x, {:lit, nil, 1.0}}, {:y, {:lit, nil, 2.0}}]}

      update = {:record_update, nil, :Point, {:var, nil, :p}, [{:x, {:lit, nil, 5.0}}]}

      let_ast = {:let, nil, :p, construct, {:dot, nil, update, :x}}

      {:ok, core, ctx2} = Elaborate.elaborate(ctx, let_ast)

      check_ctx = %{Check.new() | adts: ctx2.adts, records: ctx2.records}
      {:ok, checked, type, _ctx} = Check.synth(check_ctx, core)

      assert {:vbuiltin, :Float} = type

      erased = Erase.erase(checked, {:builtin, :Float})
      ast = Codegen.compile_expr(erased)
      {result, _} = Code.eval_quoted(ast)
      assert 5.0 = result
    end
  end

  # ============================================================================
  # Eta rule
  # ============================================================================

  describe "eta rule" do
    test "neutral at record type eta-expands to constructor" do
      record_decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      records = %{Point: record_decl}

      # A neutral at record type should eta-expand.
      ne = {:vneutral, {:vdata, :Point, []}, {:nvar, 0}}

      result = Quote.quote(1, {:vdata, :Point, []}, ne, records: records)

      # Should produce: mk_Point(case var0 of mk_Point(a, b) -> a, case var0 of mk_Point(a, b) -> b)
      assert {:con, :Point, :mk_Point, [proj_x, proj_y]} = result
      assert {:case, {:var, 0}, [{:mk_Point, 2, {:var, 1}}]} = proj_x
      assert {:case, {:var, 0}, [{:mk_Point, 2, {:var, 0}}]} = proj_y
    end

    test "non-neutral at record type is not eta-expanded" do
      record_decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      records = %{Point: record_decl}

      # A constructor value should NOT be eta-expanded — just quoted structurally.
      val = {:vcon, :Point, :mk_Point, [{:vlit, 1.0}, {:vlit, 2.0}]}
      result = Quote.quote(0, {:vdata, :Point, []}, val, records: records)

      assert {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]} = result
    end

    test "non-record ADT neutral is not eta-expanded" do
      records = %{}
      ne = {:vneutral, {:vdata, :Option, []}, {:nvar, 0}}
      result = Quote.quote(1, {:vdata, :Option, []}, ne, records: records)

      # Should fall through to structural neutral readback.
      assert {:var, 0} = result
    end
  end

  # ============================================================================
  # Struct codegen
  # ============================================================================

  describe "struct codegen" do
    test "constructor compiles to struct when records context is set" do
      record_decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      records = %{Point: record_decl}

      Process.put(:haruspex_codegen_records, records)

      term = {:con, :Point, :mk_Point, [{:lit, 1.0}, {:lit, 2.0}]}
      ast = Codegen.compile_expr(term)

      Process.delete(:haruspex_codegen_records)

      # Should be a struct construction: %Point{x: 1.0, y: 2.0}
      assert {:%, [], [:Point, {:%{}, [], [x: 1.0, y: 2.0]}]} = ast
    end

    test "case pattern compiles to struct pattern when records context is set" do
      record_decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      records = %{Point: record_decl}

      Process.put(:haruspex_codegen_records, records)

      # case p of mk_Point(x, y) -> x
      term = {:case, {:var, 0}, [{:mk_Point, 2, {:var, 1}}]}
      ast = Codegen.compile_expr(term)

      Process.delete(:haruspex_codegen_records)

      # The pattern should be a struct pattern.
      {:case, [], [_scrut, [do: [{:->, [], [[pattern], _body]}]]]} = ast
      assert {:%, [], [:Point, {:%{}, [], [{:x, _}, {:y, _}]}]} = pattern
    end

    test "compile_module generates struct module for records" do
      record_decl = %{
        name: :Point,
        params: [],
        fields: [{:x, {:builtin, :Float}}, {:y, {:builtin, :Float}}],
        constructor_name: :mk_Point,
        span: nil
      }

      records = %{Point: record_decl}

      ast =
        Codegen.compile_module(
          Test.RecordCodegen,
          :all,
          [{:origin, {:builtin, :Float}, {:con, :Point, :mk_Point, [{:lit, 0.0}, {:lit, 0.0}]}}],
          %{records: records}
        )

      # Should contain a defmodule for the struct.
      assert {:__block__, [], [struct_mod | _]} = ast
      assert {:defmodule, _, [Test.RecordCodegen.Point, _]} = struct_mod
    end
  end

  # ============================================================================
  # Dependent field update validation
  # ============================================================================

  describe "dependent field update validation" do
    test "updating independent field succeeds" do
      ctx = elaborate_source("record Pair: fst : Int, snd : Int")

      # %{p | fst: 99} where p is bound
      inner_ctx = push_test_binding(ctx, :p)

      update_ast =
        {:record_update, nil, :Pair, {:var, nil, :p}, [{:fst, {:lit, nil, 99}}]}

      assert {:ok, _, _} = Elaborate.elaborate(inner_ctx, update_ast)
    end

    test "updating field with dependent not updated produces error" do
      # record DepRec do fst : Int; snd : Int end
      # To test dependent fields, we need a record where snd's type references fst.
      # Since the parser doesn't support dependent record types with variable references
      # in field types yet, we test the internal validation function directly.
      decl = %{
        name: :DepRec,
        params: [],
        # snd's type is {:var, 0} meaning it depends on fst.
        fields: [{:fst, {:builtin, :Int}}, {:snd, {:var, 0}}],
        constructor_name: :mk_DepRec,
        span: nil
      }

      updated_fields = MapSet.new([:fst])

      # This should fail because snd depends on fst but snd is not updated.
      assert {:error, {:dependent_field_not_updated, :DepRec, :snd, [:fst], nil}} =
               Haruspex.Elaborate.check_dependent_field_updates(decl, updated_fields, nil)
    end

    test "updating field with dependent also updated succeeds" do
      decl = %{
        name: :DepRec,
        params: [],
        fields: [{:fst, {:builtin, :Int}}, {:snd, {:var, 0}}],
        constructor_name: :mk_DepRec,
        span: nil
      }

      # Both fst and snd are updated — should be fine.
      updated_fields = MapSet.new([:fst, :snd])

      assert :ok =
               Haruspex.Elaborate.check_dependent_field_updates(decl, updated_fields, nil)
    end

    test "updating non-dependent field succeeds even with dependent fields" do
      decl = %{
        name: :DepRec,
        params: [],
        fields: [{:fst, {:builtin, :Int}}, {:snd, {:var, 0}}],
        constructor_name: :mk_DepRec,
        span: nil
      }

      # Only updating snd (which depends on fst, but fst is not changed) — fine.
      updated_fields = MapSet.new([:snd])

      assert :ok =
               Haruspex.Elaborate.check_dependent_field_updates(decl, updated_fields, nil)
    end
  end

  # ============================================================================
  # Dependent record declarations
  # ============================================================================

  describe "dependent record fields" do
    test "record with independent fields elaborates" do
      ctx = elaborate_source("record Point: x : Int, y : Int")
      assert Map.has_key?(ctx.records, :Point)
      assert Map.has_key?(ctx.adts, :Point)
    end

    test "record fields stored in correct order" do
      ctx = elaborate_source("record Point: x : Int, y : Float")
      decl = ctx.records[:Point]
      assert [{:x, _}, {:y, _}] = decl.fields
    end
  end
end
