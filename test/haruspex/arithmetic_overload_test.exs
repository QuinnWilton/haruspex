defmodule Haruspex.ArithmeticOverloadTest do
  use ExUnit.Case, async: true

  alias Haruspex.Elaborate
  alias Haruspex.TypeClass.Search
  alias Haruspex.Unify.MetaState

  defp new_db do
    db = Roux.Database.new()
    Roux.Lang.register(db, Haruspex)
    db
  end

  defp set_source(db, uri, source) do
    Roux.Input.set(db, :source_text, uri, source)
  end

  # ============================================================================
  # Prelude class registration
  # ============================================================================

  describe "prelude class registration" do
    test "Num class is registered in default context" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.classes, :Num)
      decl = ctx.classes[:Num]
      assert decl.name == :Num
      assert length(decl.methods) == 3
      method_names = Enum.map(decl.methods, fn {name, _} -> name end)
      assert :add in method_names
      assert :sub in method_names
      assert :mul in method_names
    end

    test "Eq class is registered in default context" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.classes, :Eq)
      decl = ctx.classes[:Eq]
      assert decl.name == :Eq
      assert length(decl.methods) == 1
      [{:eq, _type}] = decl.methods
    end

    test "Ord class is registered in default context" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.classes, :Ord)
      decl = ctx.classes[:Ord]
      assert decl.name == :Ord
      assert length(decl.superclasses) == 1
      [{:Eq, _}] = decl.superclasses
    end

    test "no_prelude? omits classes" do
      ctx = Elaborate.new(no_prelude?: true)
      assert ctx.classes == %{}
      assert ctx.instances == %{}
    end
  end

  # ============================================================================
  # Prelude instance registration
  # ============================================================================

  describe "prelude instance registration" do
    test "Num(Int) instance is registered" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.instances, :Num)
      int_instance = Enum.find(ctx.instances[:Num], fn e -> e.head == [{:builtin, :Int}] end)
      assert int_instance != nil
      assert int_instance.n_params == 0
      method_names = Enum.map(int_instance.methods, fn {name, _} -> name end)
      assert :add in method_names
      assert :sub in method_names
      assert :mul in method_names
    end

    test "Num(Float) instance is registered" do
      ctx = Elaborate.new()
      float_instance = Enum.find(ctx.instances[:Num], fn e -> e.head == [{:builtin, :Float}] end)
      assert float_instance != nil
      # Float methods delegate to float builtins.
      assert {:add, {:builtin, :fadd}} in float_instance.methods
    end

    test "Eq(Int) instance is registered" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.instances, :Eq)
      int_instance = Enum.find(ctx.instances[:Eq], fn e -> e.head == [{:builtin, :Int}] end)
      assert int_instance != nil
      assert {:eq, {:builtin, :eq}} in int_instance.methods
    end

    test "Eq(Float) instance is registered" do
      ctx = Elaborate.new()
      float_instance = Enum.find(ctx.instances[:Eq], fn e -> e.head == [{:builtin, :Float}] end)
      assert float_instance != nil
    end

    test "Ord(Int) and Ord(Float) instances are registered" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.instances, :Ord)
      assert length(ctx.instances[:Ord]) == 2
    end
  end

  # ============================================================================
  # Instance search with prelude
  # ============================================================================

  describe "instance search with prelude" do
    test "Num(Int) is found via search" do
      ctx = Elaborate.new()
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Num, [{:vbuiltin, :Int}]})
      assert {:found, dict, _ms} = result
      # The dictionary should contain add, sub, mul methods.
      assert {:con, :NumDict, :mk_NumDict, methods} = dict
      assert length(methods) == 3
    end

    test "Num(Float) is found via search" do
      ctx = Elaborate.new()
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Num, [{:vbuiltin, :Float}]})
      assert {:found, _dict, _ms} = result
    end

    test "Eq(Int) is found via search" do
      ctx = Elaborate.new()
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Eq, [{:vbuiltin, :Int}]})
      assert {:found, _dict, _ms} = result
    end

    test "Num(String) is not found" do
      ctx = Elaborate.new()
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Num, [{:vbuiltin, :String}]})
      assert {:not_found, _} = result
    end

    test "Ord(Int) found via search with superclass" do
      ctx = Elaborate.new()
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Ord, [{:vbuiltin, :Int}]})
      assert {:found, _dict, _ms} = result
    end
  end

  # ============================================================================
  # Dictionary record generation
  # ============================================================================

  describe "dictionary records in prelude" do
    test "NumDict record is registered" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.records, :NumDict)
      record = ctx.records[:NumDict]
      field_names = Enum.map(record.fields, fn {name, _} -> name end)
      assert :add in field_names
      assert :sub in field_names
      assert :mul in field_names
    end

    test "EqDict record is registered" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.records, :EqDict)
      record = ctx.records[:EqDict]
      assert [{:eq, _type}] = record.fields
    end

    test "OrdDict record has superclass field" do
      ctx = Elaborate.new()
      assert Map.has_key?(ctx.records, :OrdDict)
      record = ctx.records[:OrdDict]
      field_names = Enum.map(record.fields, fn {name, _} -> name end)
      assert :eq_super in field_names
      assert :compare in field_names
    end
  end

  # ============================================================================
  # Codegen: monomorphic inlining
  # ============================================================================

  describe "codegen: monomorphic dictionary inlining" do
    test "Num(Int).add inlines to builtin :add" do
      ctx = Elaborate.new()
      ms = MetaState.new()

      # Search for Num(Int) and get the dictionary.
      {:found, dict, _ms} =
        Search.search(ctx.instances, ctx.classes, ms, 0, {:Num, [{:vbuiltin, :Int}]})

      # The dictionary has add as the first method (after 0 superclass fields).
      # Extracting add from the dict: {:record_proj, :add, dict}
      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, ctx.records)

      method = {:record_proj, :add, dict}
      # Apply to 1 and 2: App(App(method, 1), 2)
      applied = {:app, {:app, method, {:lit, 1}}, {:lit, 2}}

      ast = Haruspex.Codegen.compile_expr(applied)
      {result, _} = Code.eval_quoted(ast)
      assert result == 3

      Process.put(:haruspex_codegen_records, prev)
    end

    test "Eq(Int).eq inlines to builtin :eq" do
      ctx = Elaborate.new()
      ms = MetaState.new()

      {:found, dict, _ms} =
        Search.search(ctx.instances, ctx.classes, ms, 0, {:Eq, [{:vbuiltin, :Int}]})

      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, ctx.records)

      method = {:record_proj, :eq, dict}
      applied = {:app, {:app, method, {:lit, 42}}, {:lit, 42}}

      ast = Haruspex.Codegen.compile_expr(applied)
      {result, _} = Code.eval_quoted(ast)
      assert result == true

      Process.put(:haruspex_codegen_records, prev)
    end

    test "Num(Float).add inlines to builtin :fadd" do
      ctx = Elaborate.new()
      ms = MetaState.new()

      {:found, dict, _ms} =
        Search.search(ctx.instances, ctx.classes, ms, 0, {:Num, [{:vbuiltin, :Float}]})

      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, ctx.records)

      method = {:record_proj, :add, dict}
      applied = {:app, {:app, method, {:lit, 1.0}}, {:lit, 2.0}}

      ast = Haruspex.Codegen.compile_expr(applied)
      {result, _} = Code.eval_quoted(ast)
      assert result == 3.0

      Process.put(:haruspex_codegen_records, prev)
    end
  end

  # ============================================================================
  # Elaboration-time instance resolution
  # ============================================================================

  describe "elaboration-time instance resolution" do
    test "add on int literals resolves to :add builtin via Num(Int)" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      ast = {:binop, s, :add, {:lit, s, 1}, {:lit, s, 2}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      # Instance search finds Num(Int), extracts {:builtin, :add}.
      assert {:app, {:app, {:builtin, :add}, {:lit, 1}}, {:lit, 2}} = core
    end

    test "add on float literals resolves to :fadd builtin via Num(Float)" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      ast = {:binop, s, :add, {:lit, s, 1.0}, {:lit, s, 2.0}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      # Instance search finds Num(Float), extracts {:builtin, :fadd}.
      assert {:app, {:app, {:builtin, :fadd}, {:lit, 1.0}}, {:lit, 2.0}} = core
    end

    test "sub on float literals resolves to :fsub builtin via Num(Float)" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      ast = {:binop, s, :sub, {:lit, s, 5.0}, {:lit, s, 3.0}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:app, {:app, {:builtin, :fsub}, {:lit, 5.0}}, {:lit, 3.0}} = core
    end

    test "mul on float literals resolves to :fmul builtin via Num(Float)" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      ast = {:binop, s, :mul, {:lit, s, 2.0}, {:lit, s, 3.0}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:app, {:app, {:builtin, :fmul}, {:lit, 2.0}}, {:lit, 3.0}} = core
    end

    test "eq on int literals resolves to :eq builtin via Eq(Int)" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      ast = {:binop, s, :eq, {:lit, s, 42}, {:lit, s, 43}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:app, {:app, {:builtin, :eq}, {:lit, 42}}, {:lit, 43}} = core
    end

    test "non-class operator falls back to builtin" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      # :and is not a class method, so it falls back to {:builtin, :and}.
      ast = {:binop, s, :and, {:lit, s, true}, {:lit, s, false}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      assert {:app, {:app, {:builtin, :and}, {:lit, true}}, {:lit, false}} = core
    end

    test "add on variable operand falls back to builtin" do
      ctx = Elaborate.new()
      s = %Pentiment.Span.Byte{start: 0, length: 0}
      # When the left operand is a variable, we can't infer its type at elaboration time.
      # Push a binding so :x resolves.
      ctx = %{ctx | names: [{:x, 0} | ctx.names], level: ctx.level + 1}
      ast = {:binop, s, :add, {:var, s, :x}, {:lit, s, 1}}
      {:ok, core, _ctx} = Elaborate.elaborate(ctx, ast)
      # Falls back to {:builtin, :add} since variable type is unknown.
      assert {:app, {:app, {:builtin, :add}, {:var, _}}, {:lit, 1}} = core
    end
  end

  # ============================================================================
  # Checker polymorphic resolution
  # ============================================================================

  describe "checker polymorphic resolution" do
    test "builtin :add gets polymorphic type when classes are in scope" do
      ctx = %{Haruspex.Check.new() | classes: Haruspex.Prelude.TypeClasses.class_decls()}
      {:ok, _term, type, _ctx} = Haruspex.Check.synth(ctx, {:builtin, :add})
      # Should be a Pi type with a meta as domain (not hard-coded Int).
      assert {:vpi, :omega, domain, _env, _cod} = type
      # Domain should be a meta (implicit type variable), not {:vbuiltin, :Int}.
      assert {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, _id}} = domain
    end

    test "builtin :add with no classes gets hard-coded Int type" do
      ctx = Haruspex.Check.new()
      {:ok, _term, type, _ctx} = Haruspex.Check.synth(ctx, {:builtin, :add})
      # Without classes, falls back to hard-coded Int -> Int -> Int.
      assert {:vpi, :omega, {:vbuiltin, :Int}, _env, _cod} = type
    end

    test "x + y type-checks as Int through full pipeline" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      def my_add(x : Int, y : Int) : Int do
        x + y
      end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :my_add})
    end

    test "x + y type-checks as Float via Num(Float)" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      def my_fadd(x : Float, y : Float) : Float do
        x + y
      end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :my_fadd})
    end
  end
end
