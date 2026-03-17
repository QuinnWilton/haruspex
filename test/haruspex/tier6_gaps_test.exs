defmodule Haruspex.Tier6GapsTest do
  use ExUnit.Case, async: true

  alias Haruspex.Elaborate
  alias Haruspex.TypeClass.Bridge

  defp new_db do
    db = Roux.Database.new()
    Roux.Lang.register(db, Haruspex)
    db
  end

  defp set_source(db, uri, source) do
    Roux.Input.set(db, :source_text, uri, source)
  end

  defp span, do: %Pentiment.Span.Byte{start: 0, length: 0}

  # ============================================================================
  # Gap 1: Orphan instance detection
  # ============================================================================

  describe "orphan instance detection" do
    test "prelude instance of prelude class on builtin type is not orphan" do
      ctx = Elaborate.new()

      # Elaborate an instance of Eq(Int) — both class and type are prelude.
      eq_class =
        {:class_decl, span(), :Eq, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :eq,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a},
             {:pi, span(), {:y, :omega, false}, {:var, span(), :a}, {:var, span(), :Bool}}}}
         ]}

      {:ok, _, ctx} = Elaborate.elaborate_class_decl(ctx, eq_class)

      instance_ast =
        {:instance_decl, span(), :Eq, [{:var, span(), :Int}], [],
         [
           {:method_impl, span(), :eq,
            {:fn, span(),
             [
               {:param, span(), {:x, :omega, false}, {:var, span(), :Int}},
               {:param, span(), {:y, :omega, false}, {:var, span(), :Int}}
             ], {:binop, span(), :eq, {:var, span(), :x}, {:var, span(), :y}}}}
         ]}

      {:ok, inst_decl, _ctx} = Elaborate.elaborate_instance_decl(ctx, instance_ast)

      # Instance of a prelude class on a builtin type — not orphan.
      assert inst_decl.orphan_warning == nil
    end

    test "instance of locally-defined class is not orphan" do
      ctx = Elaborate.new(no_prelude?: true)

      class_ast =
        {:class_decl, span(), :MyClass, [{:a, {:type_universe, span(), 0}}], [],
         [{:method_sig, span(), :method, {:var, span(), :a}}]}

      {:ok, _, ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      instance_ast =
        {:instance_decl, span(), :MyClass, [{:var, span(), :a}], [],
         [{:method_impl, span(), :method, {:var, span(), :a}}]}

      {:ok, inst_decl, _ctx} = Elaborate.elaborate_instance_decl(ctx, instance_ast)

      # Class is locally defined — not orphan.
      assert inst_decl.orphan_warning == nil
    end

    test "instance of locally-defined type for prelude class is not orphan" do
      ctx = Elaborate.new()

      # Define a local ADT.
      type_ast =
        {:type_decl, span(), :Color, [],
         [
           {:constructor, span(), :red, [], nil},
           {:constructor, span(), :green, [], nil},
           {:constructor, span(), :blue, [], nil}
         ]}

      {:ok, _, ctx} = Elaborate.elaborate_type_decl(ctx, type_ast)

      # Instance of prelude Eq for locally-defined Color.
      instance_ast =
        {:instance_decl, span(), :Eq, [{:var, span(), :Color}], [],
         [
           {:method_impl, span(), :eq,
            {:fn, span(),
             [
               {:param, span(), {:x, :omega, false}, {:var, span(), :Color}},
               {:param, span(), {:y, :omega, false}, {:var, span(), :Color}}
             ], {:lit, span(), true}}}
         ]}

      {:ok, inst_decl, _ctx} = Elaborate.elaborate_instance_decl(ctx, instance_ast)
      # The type Color is locally defined — not orphan.
      assert inst_decl.orphan_warning == nil
    end
  end

  # ============================================================================
  # Gap 2: Default method test coverage
  # ============================================================================

  describe "default methods" do
    test "class with default method fills missing instance methods" do
      ctx = Elaborate.new()

      # Define class with two methods, one having a default.
      class_ast =
        {:class_decl, span(), :Show, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :show,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a}, {:var, span(), :String}}},
           {:method_sig, span(), :show_detail,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a}, {:var, span(), :String}}}
         ]}

      {:ok, class_decl, ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      # Add a default for show_detail.
      class_decl = %{class_decl | defaults: [{:show_detail, {:lit, "default"}}]}
      ctx = %{ctx | classes: Map.put(ctx.classes, :Show, class_decl)}

      # Instance that only implements :show (missing :show_detail).
      instance_ast =
        {:instance_decl, span(), :Show, [{:var, span(), :Int}], [],
         [
           {:method_impl, span(), :show,
            {:fn, span(), [{:param, span(), {:x, :omega, false}, {:var, span(), :Int}}],
             {:lit, span(), "int"}}}
         ]}

      {:ok, inst_decl, _ctx} = Elaborate.elaborate_instance_decl(ctx, instance_ast)

      # Should have both methods — show_detail filled from default.
      method_names = Enum.map(inst_decl.methods, fn {name, _} -> name end)
      assert :show in method_names
      assert :show_detail in method_names
      assert length(inst_decl.methods) == 2

      # The default body should be the literal.
      {_, default_body} = List.keyfind(inst_decl.methods, :show_detail, 0)
      assert {:lit, "default"} = default_body
    end

    test "instance with all methods does not use defaults" do
      ctx = Elaborate.new()

      class_ast =
        {:class_decl, span(), :Show, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :show,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a}, {:var, span(), :String}}}
         ]}

      {:ok, class_decl, ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      class_decl = %{class_decl | defaults: [{:show, {:lit, "default"}}]}
      ctx = %{ctx | classes: Map.put(ctx.classes, :Show, class_decl)}

      # Instance provides its own :show.
      instance_ast =
        {:instance_decl, span(), :Show, [{:var, span(), :Int}], [],
         [
           {:method_impl, span(), :show,
            {:fn, span(), [{:param, span(), {:x, :omega, false}, {:var, span(), :Int}}],
             {:lit, span(), "custom"}}}
         ]}

      {:ok, inst_decl, _ctx} = Elaborate.elaborate_instance_decl(ctx, instance_ast)

      # Should use the custom implementation, not the default.
      {_, body} = List.keyfind(inst_decl.methods, :show, 0)
      refute body == {:lit, "default"}
    end
  end

  # ============================================================================
  # Gap 3: @protocol annotation parsing
  # ============================================================================

  describe "@protocol annotation" do
    test "parses @protocol class declaration" do
      source = """
      @protocol
      class Show(a : Type) do
        show : a -> String
      end
      """

      {:ok, [form]} = Haruspex.Parser.parse(source)
      # Should be a 7-element tuple with :protocol flag.
      assert {:class_decl, _span, :Show, _params, _constraints, _methods, :protocol} = form
    end

    test "non-protocol class declaration has 6 elements" do
      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      {:ok, [form]} = Haruspex.Parser.parse(source)
      assert {:class_decl, _span, :Eq, _params, _constraints, _methods} = form
    end

    test "@protocol class elaborates with protocol? flag" do
      ctx = Elaborate.new()

      source = """
      @protocol
      class Show(a : Type) do
        show : a -> String
      end
      """

      {:ok, [form]} = Haruspex.Parser.parse(source)
      {:ok, decl, _ctx} = Elaborate.elaborate_class_decl(ctx, form)
      assert decl.protocol? == true
    end

    test "non-protocol class has no protocol? flag" do
      ctx = Elaborate.new()

      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      {:ok, [form]} = Haruspex.Parser.parse(source)
      {:ok, decl, _ctx} = Elaborate.elaborate_class_decl(ctx, form)
      refute Map.get(decl, :protocol?)
    end

    test "compile_protocol generates defprotocol" do
      class_decl = %{
        name: :Show,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:show, {:pi, :omega, {:var, 0}, {:builtin, :String}}}
        ],
        defaults: [],
        dict_name: :ShowDict,
        dict_constructor_name: :mk_ShowDict,
        span: nil,
        protocol?: true
      }

      ast = Bridge.compile_protocol(class_decl, TestModule)
      code = Macro.to_string(ast)
      assert code =~ "defprotocol"
      assert code =~ "TestModule.Show"
      assert code =~ "show"
    end

    test "compile_bridges produces protocol for annotated class" do
      class_decl = %{
        name: :Show,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:show, {:pi, :omega, {:var, 0}, {:builtin, :String}}}
        ],
        defaults: [],
        dict_name: :ShowDict,
        dict_constructor_name: :mk_ShowDict,
        span: nil,
        protocol?: true
      }

      classes = %{Show: class_decl}
      result = Bridge.compile_bridges(classes, %{}, %{}, TestBridge)
      assert length(result) == 1
      code = Macro.to_string(hd(result))
      assert code =~ "defprotocol"
    end

    test "compile_bridges skips non-annotated classes" do
      class_decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [{:eq, {:pi, :omega, {:var, 0}, {:builtin, :Bool}}}],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil
      }

      classes = %{Eq: class_decl}
      assert [] = Bridge.compile_bridges(classes, %{}, %{}, TestBridge)
    end
  end

  # ============================================================================
  # Gap 4: Instance validation in checker
  # ============================================================================

  describe "checker instance validation" do
    test "add on Int passes instance validation" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      def f(x : Int, y : Int) : Int do x + y end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/test.hx", :f})
    end

    test "add on Float passes instance validation" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      def f(x : Float, y : Float) : Float do x + y end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/test.hx", :f})
    end

    test "add on String produces no_instance error" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      def f(x : String, y : String) : String do x + y end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      result = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/test.hx", :f})
      assert {:error, {:no_instance, :Num, {:vbuiltin, :String}}} = result
    end

    test "eq on Int passes instance validation" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      def f(x : Int, y : Int) : Bool do x == y end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/test.hx", :f})
    end
  end
end
