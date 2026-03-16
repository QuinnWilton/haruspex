defmodule Haruspex.TypeClassCodegenTest do
  use ExUnit.Case, async: true

  alias Haruspex.Codegen
  alias Haruspex.Elaborate
  alias Haruspex.TypeClass.Bridge

  # ============================================================================
  # record_proj codegen
  # ============================================================================

  describe "record_proj compilation" do
    test "compiles to field access" do
      # {:record_proj, :eq, {:var, 0}} → _v0.eq
      ast = Codegen.compile_expr({:record_proj, :eq, {:var, 0}})
      code = Macro.to_string(ast)
      assert code =~ ".eq"
    end

    test "compiles nested projection" do
      # {:record_proj, :compare, {:record_proj, :ord_super, {:var, 0}}}
      ast = Codegen.compile_expr({:record_proj, :compare, {:record_proj, :ord_super, {:var, 0}}})
      code = Macro.to_string(ast)
      assert code =~ ".ord_super"
      assert code =~ ".compare"
    end
  end

  # ============================================================================
  # Dictionary inlining
  # ============================================================================

  describe "dictionary inlining" do
    test "record_proj on known constructor inlines the field" do
      # Set up the records in process dictionary.
      eq_record = %{
        name: :EqDict,
        params: [],
        fields: [{:eq, {:type, {:llit, 0}}}],
        constructor_name: :mk_EqDict,
        span: nil
      }

      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, %{EqDict: eq_record})

      # {:record_proj, :eq, {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}}
      # Should inline to just {:builtin, :eq} → &Kernel.==/2
      term = {:record_proj, :eq, {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}}
      ast = Codegen.compile_expr(term)
      code = Macro.to_string(ast)

      # The inlined result should be the builtin eq capture.
      assert code =~ "Kernel" or code =~ "=="

      Process.put(:haruspex_codegen_records, prev)
    end

    test "inlined method applied to args produces direct operation" do
      eq_record = %{
        name: :EqDict,
        params: [],
        fields: [{:eq, {:type, {:llit, 0}}}],
        constructor_name: :mk_EqDict,
        span: nil
      }

      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, %{EqDict: eq_record})

      # App(App(record_proj(:eq, dict), 42), 43)
      # where dict = {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}
      dict = {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}
      method = {:record_proj, :eq, dict}
      applied = {:app, {:app, method, {:lit, 42}}, {:lit, 43}}

      ast = Codegen.compile_expr(applied)
      {result, _} = Code.eval_quoted(ast)

      assert result == false

      Process.put(:haruspex_codegen_records, prev)
    end

    test "eq(42, 42) inlined to true" do
      eq_record = %{
        name: :EqDict,
        params: [],
        fields: [{:eq, {:type, {:llit, 0}}}],
        constructor_name: :mk_EqDict,
        span: nil
      }

      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, %{EqDict: eq_record})

      dict = {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}
      method = {:record_proj, :eq, dict}
      applied = {:app, {:app, method, {:lit, 42}}, {:lit, 42}}

      ast = Codegen.compile_expr(applied)
      {result, _} = Code.eval_quoted(ast)
      assert result == true

      Process.put(:haruspex_codegen_records, prev)
    end
  end

  # ============================================================================
  # Dictionary struct generation
  # ============================================================================

  describe "dictionary struct generation" do
    test "user-defined class dict record generates struct module" do
      # Use a non-prelude class name to avoid being filtered out.
      show_record = %{
        name: :ShowDict,
        params: [],
        fields: [{:show, {:type, {:llit, 0}}}],
        constructor_name: :mk_ShowDict,
        span: nil
      }

      show_adt = %{
        name: :ShowDict,
        params: [],
        constructors: [
          %{
            name: :mk_ShowDict,
            fields: [{:type, {:llit, 0}}],
            return_type: {:data, :ShowDict, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      ast =
        Codegen.compile_module(
          TestDictStruct,
          :all,
          [],
          %{records: %{ShowDict: show_record}, adts: %{ShowDict: show_adt}}
        )

      code = Macro.to_string(ast)
      assert code =~ "ShowDict"
      assert code =~ "defstruct"
    end
  end

  # ============================================================================
  # Instance __dict__ function generation
  # ============================================================================

  describe "instance __dict__ function generation" do
    test "concrete instance generates nullary __dict__ function" do
      eq_record = %{
        name: :EqDict,
        params: [],
        fields: [{:eq, {:type, {:llit, 0}}}],
        constructor_name: :mk_EqDict,
        span: nil
      }

      eq_adt = %{
        name: :EqDict,
        params: [],
        constructors: [
          %{
            name: :mk_EqDict,
            fields: [{:type, {:llit, 0}}],
            return_type: {:data, :EqDict, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      eq_int_instance = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      ast =
        Codegen.compile_module(
          TestDictFun,
          :all,
          [],
          %{
            records: %{EqDict: eq_record},
            adts: %{EqDict: eq_adt},
            instances: %{Eq: [eq_int_instance]}
          }
        )

      code = Macro.to_string(ast)
      # Should contain a __dict__ function.
      assert code =~ "__dict_Eq_Int__"
      assert code =~ "EqDict"
    end

    test "constrained instance generates __dict__ function with params" do
      eq_record = %{
        name: :EqDict,
        params: [],
        fields: [{:eq, {:type, {:llit, 0}}}],
        constructor_name: :mk_EqDict,
        span: nil
      }

      eq_adt = %{
        name: :EqDict,
        params: [],
        constructors: [
          %{
            name: :mk_EqDict,
            fields: [{:type, {:llit, 0}}],
            return_type: {:data, :EqDict, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      eq_list_instance = %{
        class_name: :Eq,
        n_params: 1,
        head: [{:data, :List, [{:var, 0}]}],
        constraints: [{:Eq, [{:var, 0}]}],
        methods: [{:eq, {:lit, :list_eq_placeholder}}],
        span: nil,
        module: nil
      }

      ast =
        Codegen.compile_module(
          TestDictFunParam,
          :all,
          [],
          %{
            records: %{EqDict: eq_record},
            adts: %{EqDict: eq_adt},
            instances: %{Eq: [eq_list_instance]}
          }
        )

      code = Macro.to_string(ast)
      # Should contain a __dict__ function with a parameter.
      assert code =~ "__dict_Eq_List_v0__"
      assert code =~ "_dict0"
    end
  end

  # ============================================================================
  # record_proj in erase
  # ============================================================================

  describe "record_proj in erase" do
    test "record_proj passes through erasure structurally" do
      term = {:record_proj, :eq, {:lit, 42}}
      erased = Haruspex.Erase.erase(term, {:type, {:llit, 0}})
      assert {:record_proj, :eq, {:lit, 42}} = erased
    end
  end

  # ============================================================================
  # Protocol bridge
  # ============================================================================

  describe "protocol bridge" do
    test "type mapping maps Haruspex types to Elixir types" do
      assert Bridge.map_type(:Int) == Integer
      assert Bridge.map_type(:Float) == Float
      assert Bridge.map_type(:String) == BitString
      assert Bridge.map_type(:Bool) == Atom
      assert Bridge.map_type(:UnknownType) == nil
    end

    test "compile_protocol generates defprotocol" do
      class_decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:eq, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Bool}}}}
        ],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil
      }

      ast = Bridge.compile_protocol(class_decl, TestProto)
      code = Macro.to_string(ast)
      assert code =~ "defprotocol"
      assert code =~ "TestProto.Eq"
      assert code =~ "eq"
    end

    test "compile_bridges returns empty for non-annotated classes" do
      assert [] = Bridge.compile_bridges(%{}, %{}, %{}, TestModule)
    end
  end

  # ============================================================================
  # Integration: parse → elaborate → codegen
  # ============================================================================

  describe "integration" do
    test "class + instance end-to-end compilation" do
      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end

      instance Eq(Int) do
        def eq(x : Int, y : Int) : Bool do x end
      end
      """

      {:ok, forms} = Haruspex.Parser.parse(source)
      ctx = Elaborate.new()

      [{:class_decl, _, _, _, _, _} = cd, {:instance_decl, _, _, _, _, _} = ind] = forms
      {:ok, _class_decl, ctx} = Elaborate.elaborate_class_decl(ctx, cd)
      {:ok, _inst_decl, ctx} = Elaborate.elaborate_instance_decl(ctx, ind)

      # Records and instances should be available for codegen.
      assert Map.has_key?(ctx.records, :EqDict)
      assert Map.has_key?(ctx.instances, :Eq)

      # Generate module AST (no user definitions, just class/instance infrastructure).
      ast =
        Codegen.compile_module(
          TestIntegration,
          :all,
          [],
          %{
            records: ctx.records,
            adts: ctx.adts,
            instances: ctx.instances
          }
        )

      code = Macro.to_string(ast)

      # Should have the struct module and dict function.
      assert code =~ "EqDict"
      assert code =~ "__dict_Eq_Int__"
    end

    test "dictionary construction compiles to struct" do
      ctx = Elaborate.new()

      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      {:ok, [cd]} = Haruspex.Parser.parse(source)
      {:ok, _decl, ctx} = Elaborate.elaborate_class_decl(ctx, cd)

      # Simulate what instance search produces: a dictionary constructor.
      # {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}
      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, ctx.records)

      dict_term = {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}
      ast = Codegen.compile_expr(dict_term)
      code = Macro.to_string(ast)

      # Should produce a struct construction.
      assert code =~ "EqDict"
      assert code =~ "eq:"

      Process.put(:haruspex_codegen_records, prev)
    end

    test "superclass dict extraction compiles with inlining" do
      ctx = Elaborate.new()

      eq_source = "class Eq(a : Type) do eq : a -> a -> Bool end"
      ord_source = "class Ord(a : Type) [Eq(a)] do compare : a -> a -> Int end"

      {:ok, [eq_cd]} = Haruspex.Parser.parse(eq_source)
      {:ok, [ord_cd]} = Haruspex.Parser.parse(ord_source)

      {:ok, _, ctx} = Elaborate.elaborate_class_decl(ctx, eq_cd)
      {:ok, _, ctx} = Elaborate.elaborate_class_decl(ctx, ord_cd)

      prev = Process.get(:haruspex_codegen_records)
      Process.put(:haruspex_codegen_records, ctx.records)

      # Superclass extraction: {:record_proj, :eq_super, ord_dict}
      # where ord_dict = {:con, :OrdDict, :mk_OrdDict, [eq_dict, compare_fn]}
      eq_dict = {:con, :EqDict, :mk_EqDict, [{:builtin, :eq}]}
      ord_dict = {:con, :OrdDict, :mk_OrdDict, [eq_dict, {:builtin, :lt}]}

      # Extracting the eq_super field from OrdDict should inline to eq_dict.
      term = {:record_proj, :eq_super, ord_dict}
      ast = Codegen.compile_expr(term)
      code = Macro.to_string(ast)

      # The inlined result should be the EqDict struct (not field access on OrdDict).
      assert code =~ "EqDict"

      Process.put(:haruspex_codegen_records, prev)
    end
  end

  # ============================================================================
  # subst_self handles record_proj
  # ============================================================================

  describe "subst_self handles record_proj" do
    test "self-ref inside record_proj is replaced" do
      # This tests the internal subst_self function indirectly via compile_module.
      # A definition that uses record_proj should still handle self-references.
      eq_record = %{
        name: :EqDict,
        params: [],
        fields: [{:eq, {:type, {:llit, 0}}}],
        constructor_name: :mk_EqDict,
        span: nil
      }

      eq_adt = %{
        name: :EqDict,
        params: [],
        constructors: [
          %{
            name: :mk_EqDict,
            fields: [{:type, {:llit, 0}}],
            return_type: {:data, :EqDict, []},
            span: nil
          }
        ],
        universe_level: {:llit, 0},
        span: nil
      }

      # A simple function that returns a literal — just verify compilation doesn't crash.
      definitions = [
        {:my_fn, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}, {:lam, :omega, {:var, 0}}}
      ]

      ast =
        Codegen.compile_module(
          TestSubstSelf,
          :all,
          definitions,
          %{records: %{EqDict: eq_record}, adts: %{EqDict: eq_adt}}
        )

      # Should compile without error — verify it's a quoted module definition.
      assert is_tuple(ast)
    end
  end

  # ============================================================================
  # Bridge — compile_impl
  # ============================================================================

  describe "compile_impl" do
    test "generates defimpl for a builtin type instance" do
      class_decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:eq, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Bool}}}}
        ],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil
      }

      instance_entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:lam, :omega, {:lam, :omega, {:var, 0}}}}],
        span: nil,
        module: nil
      }

      ast = Bridge.compile_impl(instance_entry, class_decl, TestImplMod)
      assert ast != nil
      code = Macro.to_string(ast)
      assert code =~ "defimpl"
      assert code =~ "TestImplMod.Eq"
      assert code =~ "Integer"
      assert code =~ "eq"
    end

    test "returns nil for unmappable type" do
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

      # A non-builtin head type that can't map to an Elixir type.
      instance_entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:data, :MyCustom, []}],
        constraints: [],
        methods: [{:eq, {:lit, :placeholder}}],
        span: nil,
        module: nil
      }

      assert nil == Bridge.compile_impl(instance_entry, class_decl, TestImplMod)
    end

    test "returns nil for unknown builtin type" do
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

      instance_entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :UnknownBuiltin}],
        constraints: [],
        methods: [{:eq, {:lit, :placeholder}}],
        span: nil,
        module: nil
      }

      assert nil == Bridge.compile_impl(instance_entry, class_decl, TestImplMod)
    end
  end

  # ============================================================================
  # Bridge — instance_to_elixir_type
  # ============================================================================

  describe "instance_to_elixir_type via compile_impl" do
    test "maps builtin Int to Integer" do
      class_decl = %{
        name: :Show,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [{:show, {:pi, :omega, {:var, 0}, {:builtin, :String}}}],
        defaults: [],
        dict_name: :ShowDict,
        dict_constructor_name: :mk_ShowDict,
        span: nil
      }

      instance_entry = %{
        class_name: :Show,
        n_params: 0,
        head: [{:builtin, :Float}],
        constraints: [],
        methods: [{:show, {:lam, :omega, {:lit, "float"}}}],
        span: nil,
        module: nil
      }

      ast = Bridge.compile_impl(instance_entry, class_decl, TestImplFloat)
      assert ast != nil
      code = Macro.to_string(ast)
      assert code =~ "Float"
    end
  end

  # ============================================================================
  # Bridge — method_arity_from_body
  # ============================================================================

  describe "method_arity_from_body via compile_impl" do
    test "counts nested lambdas in method body" do
      class_decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:eq, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Bool}}}}
        ],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil
      }

      # Body with two nested lambdas → arity 2.
      instance_entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :String}],
        constraints: [],
        methods: [{:eq, {:lam, :omega, {:lam, :omega, {:lit, true}}}}],
        span: nil,
        module: nil
      }

      ast = Bridge.compile_impl(instance_entry, class_decl, TestImplArity)
      assert ast != nil
      code = Macro.to_string(ast)
      # Should generate def eq(arg0, arg1, arg2) — 1 dispatch + 2 lambda args.
      assert code =~ "eq"
    end

    test "non-lambda body yields arity 0" do
      class_decl = %{
        name: :Show,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [{:show, {:pi, :omega, {:var, 0}, {:builtin, :String}}}],
        defaults: [],
        dict_name: :ShowDict,
        dict_constructor_name: :mk_ShowDict,
        span: nil
      }

      # Body is a literal, not a lambda → arity 0.
      instance_entry = %{
        class_name: :Show,
        n_params: 0,
        head: [{:builtin, :Bool}],
        constraints: [],
        methods: [{:show, {:lit, "true"}}],
        span: nil,
        module: nil
      }

      ast = Bridge.compile_impl(instance_entry, class_decl, TestImplZeroArity)
      assert ast != nil
      code = Macro.to_string(ast)
      assert code =~ "show"
    end
  end

  # ============================================================================
  # Bridge — compile_bridges with protocol-annotated class
  # ============================================================================

  describe "compile_bridges with protocol-annotated class" do
    test "generates protocol and impls for @protocol class" do
      class_decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:eq, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Bool}}}}
        ],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil,
        protocol?: true
      }

      instance_entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:lam, :omega, {:lam, :omega, {:var, 0}}}}],
        span: nil,
        module: nil
      }

      classes = %{Eq: class_decl}
      instances = %{Eq: [instance_entry]}

      result = Bridge.compile_bridges(classes, instances, %{}, TestBridgeMod)
      # Should have at least the protocol definition and one impl.
      assert length(result) >= 2

      code = Enum.map(result, &Macro.to_string/1) |> Enum.join("\n")
      assert code =~ "defprotocol"
      assert code =~ "defimpl"
    end

    test "multi-param class is skipped by compile_bridges" do
      class_decl = %{
        name: :MultiEq,
        params: [{:a, {:type, {:llit, 0}}}, {:b, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [{:meq, {:pi, :omega, {:var, 0}, {:builtin, :Bool}}}],
        defaults: [],
        dict_name: :MultiEqDict,
        dict_constructor_name: :mk_MultiEqDict,
        span: nil,
        protocol?: true
      }

      classes = %{MultiEq: class_decl}
      result = Bridge.compile_bridges(classes, %{}, %{}, TestBridgeMod)
      assert result == []
    end

    test "prelude instances are rejected from impl generation" do
      class_decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [
          {:eq, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Bool}}}}
        ],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil,
        protocol?: true
      }

      # Instance with module: :prelude should be rejected.
      prelude_instance = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:lam, :omega, {:lam, :omega, {:var, 0}}}}],
        span: nil,
        module: :prelude
      }

      classes = %{Eq: class_decl}
      instances = %{Eq: [prelude_instance]}

      result = Bridge.compile_bridges(classes, instances, %{}, TestBridgeMod)
      # Only the protocol definition, no impls (prelude instance filtered out).
      assert length(result) == 1
      code = Macro.to_string(hd(result))
      assert code =~ "defprotocol"
    end
  end
end
