defmodule Haruspex.TypeClassTest do
  use ExUnit.Case, async: true

  alias Haruspex.Elaborate
  alias Haruspex.TypeClass

  # ============================================================================
  # TypeClass module unit tests
  # ============================================================================

  describe "dict_name/1" do
    test "generates dictionary name" do
      assert TypeClass.dict_name(:Eq) == :EqDict
      assert TypeClass.dict_name(:Ord) == :OrdDict
      assert TypeClass.dict_name(:Functor) == :FunctorDict
    end
  end

  describe "dict_constructor_name/1" do
    test "generates dictionary constructor name" do
      assert TypeClass.dict_constructor_name(:Eq) == :mk_EqDict
      assert TypeClass.dict_constructor_name(:Ord) == :mk_OrdDict
    end
  end

  describe "superclass_field_name/1" do
    test "generates snake_case superclass field name" do
      assert TypeClass.superclass_field_name(:Eq) == :eq_super
      assert TypeClass.superclass_field_name(:Ord) == :ord_super
    end
  end

  describe "class_to_record/1" do
    test "simple class generates dictionary record" do
      decl = %{
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

      record = TypeClass.class_to_record(decl)

      assert record.name == :EqDict
      assert record.constructor_name == :mk_EqDict
      assert record.params == [{:a, {:type, {:llit, 0}}}]
      assert length(record.fields) == 1
      [{:eq, type}] = record.fields
      assert type == {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Bool}}}
    end

    test "class with superclass generates nested dictionary field" do
      decl = %{
        name: :Ord,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [{:Eq, [{:var, 0}]}],
        methods: [
          {:compare, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:data, :Ordering, []}}}}
        ],
        defaults: [],
        dict_name: :OrdDict,
        dict_constructor_name: :mk_OrdDict,
        span: nil
      }

      record = TypeClass.class_to_record(decl)

      assert record.name == :OrdDict
      assert length(record.fields) == 2

      [{:eq_super, super_type}, {:compare, _compare_type}] = record.fields
      assert super_type == {:data, :EqDict, [{:var, 0}]}
    end

    test "class with multiple superclasses" do
      decl = %{
        name: :Monad,
        params: [{:f, {:type, {:llit, 0}}}],
        superclasses: [{:Functor, [{:var, 0}]}, {:Applicative, [{:var, 0}]}],
        methods: [
          {:bind,
           {:pi, :omega, {:var, 0}, {:pi, :omega, {:pi, :omega, {:var, 1}, {:var, 2}}, {:var, 2}}}}
        ],
        defaults: [],
        dict_name: :MonadDict,
        dict_constructor_name: :mk_MonadDict,
        span: nil
      }

      record = TypeClass.class_to_record(decl)
      assert length(record.fields) == 3

      [
        {:functor_super, functor_type},
        {:applicative_super, applicative_type},
        {:bind, _bind_type}
      ] = record.fields

      assert functor_type == {:data, :FunctorDict, [{:var, 0}]}
      assert applicative_type == {:data, :ApplicativeDict, [{:var, 0}]}
    end
  end

  describe "method_type/2" do
    test "finds method type" do
      decl = %{
        name: :Eq,
        params: [{:a, {:type, {:llit, 0}}}],
        superclasses: [],
        methods: [{:eq, {:pi, :omega, {:var, 0}, {:builtin, :Bool}}}],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil
      }

      assert {:ok, {:pi, :omega, {:var, 0}, {:builtin, :Bool}}} =
               TypeClass.method_type(decl, :eq)

      assert :error = TypeClass.method_type(decl, :neq)
    end
  end

  describe "method_names/1" do
    test "lists method names" do
      decl = %{
        name: :Eq,
        params: [],
        superclasses: [],
        methods: [{:eq, :some_type}, {:neq, :some_type}],
        defaults: [],
        dict_name: :EqDict,
        dict_constructor_name: :mk_EqDict,
        span: nil
      }

      assert TypeClass.method_names(decl) == [:eq, :neq]
    end
  end

  # ============================================================================
  # Parser tests
  # ============================================================================

  describe "parsing" do
    test "parses simple class declaration" do
      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      {:ok, [{:class_decl, _span, :Eq, params, constraints, methods}]} =
        Haruspex.Parser.parse(source)

      assert length(params) == 1
      assert constraints == []
      assert length(methods) == 1

      {:method_sig, _span, :eq, _type} = hd(methods)
    end

    test "parses class with superclass constraints" do
      source = """
      class Ord(a : Type) [Eq(a)] do
        compare : a -> a -> Int
      end
      """

      {:ok, [{:class_decl, _span, :Ord, params, constraints, methods}]} =
        Haruspex.Parser.parse(source)

      assert length(params) == 1
      assert length(constraints) == 1
      [{:constraint, _span, :Eq, args}] = constraints
      assert length(args) == 1
      assert length(methods) == 1
    end

    test "parses class with multiple constraints" do
      source = """
      class MyClass(a : Type) [Eq(a), Ord(a)] do
        method1 : a -> Bool
      end
      """

      {:ok, [{:class_decl, _span, :MyClass, _params, constraints, _methods}]} =
        Haruspex.Parser.parse(source)

      assert length(constraints) == 2
      [{:constraint, _, :Eq, _}, {:constraint, _, :Ord, _}] = constraints
    end

    test "parses class with multiple methods" do
      source = """
      class Num(a : Type) do
        add : a -> a -> a
        sub : a -> a -> a
        mul : a -> a -> a
      end
      """

      {:ok, [{:class_decl, _span, :Num, _params, _constraints, methods}]} =
        Haruspex.Parser.parse(source)

      assert length(methods) == 3
      names = Enum.map(methods, fn {:method_sig, _, name, _} -> name end)
      assert names == [:add, :sub, :mul]
    end

    test "parses class with no-arg constraint" do
      source = """
      class Sub(a : Type) [Eq] do
        method1 : a -> Bool
      end
      """

      {:ok, [{:class_decl, _span, :Sub, _params, constraints, _methods}]} =
        Haruspex.Parser.parse(source)

      assert [{:constraint, _, :Eq, []}] = constraints
    end

    test "instance argument in function param" do
      source = """
      def member([eq : Eq(a)], x : a, xs : a) : Bool do
        x
      end
      """

      {:ok, [{:def, _span, {:sig, _, :member, _, params, _, _}, _body}]} =
        Haruspex.Parser.parse(source)

      # First param should be an instance argument (bracket syntax).
      [{:param, _, {name, mult, implicit?}, _type} | _rest] = params
      assert name == :eq
      assert implicit? == true
      # Instance params use omega multiplicity (they're runtime values).
      assert mult == :omega
    end
  end

  # ============================================================================
  # Elaboration tests
  # ============================================================================

  describe "elaborate_class_decl/2" do
    test "simple class registers in context" do
      ctx = Elaborate.new()

      class_ast =
        {:class_decl, span(), :Eq, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :eq,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a},
             {:pi, span(), {:y, :omega, false}, {:var, span(), :a}, {:var, span(), :Bool}}}}
         ]}

      {:ok, decl, ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      # Class registered.
      assert Map.has_key?(ctx.classes, :Eq)
      assert decl.name == :Eq
      assert length(decl.methods) == 1
      assert decl.superclasses == []

      # Dictionary record registered.
      assert Map.has_key?(ctx.records, :EqDict)
      record = ctx.records[:EqDict]
      assert record.constructor_name == :mk_EqDict
      assert length(record.fields) == 1

      # ADT registered for the dictionary.
      assert Map.has_key?(ctx.adts, :EqDict)
    end

    test "class with superclass generates nested dictionary" do
      ctx = Elaborate.new()

      # First register Eq class so EqDict is known.
      eq_ast =
        {:class_decl, span(), :Eq, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :eq,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a},
             {:pi, span(), {:y, :omega, false}, {:var, span(), :a}, {:var, span(), :Bool}}}}
         ]}

      {:ok, _eq_decl, ctx} = Elaborate.elaborate_class_decl(ctx, eq_ast)

      # Now register Ord with Eq superclass.
      ord_ast =
        {:class_decl, span(), :Ord, [{:a, {:type_universe, span(), 0}}],
         [{:constraint, span(), :Eq, [{:var, span(), :a}]}],
         [
           {:method_sig, span(), :compare,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a},
             {:pi, span(), {:y, :omega, false}, {:var, span(), :a}, {:var, span(), :Int}}}}
         ]}

      {:ok, ord_decl, ctx} = Elaborate.elaborate_class_decl(ctx, ord_ast)

      assert ord_decl.name == :Ord
      assert length(ord_decl.superclasses) == 1
      [{:Eq, _args}] = ord_decl.superclasses

      # OrdDict should have 2 fields: eq_super + compare.
      record = ctx.records[:OrdDict]
      assert length(record.fields) == 2
      [{:eq_super, _super_type}, {:compare, _compare_type}] = record.fields
    end

    test "method signatures accessible from class database" do
      ctx = Elaborate.new()

      class_ast =
        {:class_decl, span(), :Show, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :show,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a}, {:var, span(), :String}}}
         ]}

      {:ok, _decl, ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      decl = ctx.classes[:Show]
      assert {:ok, _type} = TypeClass.method_type(decl, :show)
      assert :error = TypeClass.method_type(decl, :nonexistent)
      assert TypeClass.method_names(decl) == [:show]
    end

    test "class params elaborated correctly" do
      ctx = Elaborate.new()

      class_ast =
        {:class_decl, span(), :Eq, [{:a, {:type_universe, span(), 0}}], [],
         [{:method_sig, span(), :eq, {:var, span(), :a}}]}

      {:ok, decl, _ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      assert [{:a, {:type, {:llit, 0}}}] = decl.params
    end
  end

  # ============================================================================
  # Integration tests
  # ============================================================================

  describe "integration" do
    test "define Eq class" do
      source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      {:ok, forms} = Haruspex.Parser.parse(source)
      ctx = Elaborate.new()

      [{:class_decl, _, _, _, _, _} = class_ast] = forms
      {:ok, decl, ctx} = Elaborate.elaborate_class_decl(ctx, class_ast)

      assert decl.name == :Eq
      assert Map.has_key?(ctx.classes, :Eq)
      assert Map.has_key?(ctx.records, :EqDict)
      assert Map.has_key?(ctx.adts, :EqDict)
    end

    test "define Ord class with Eq superclass" do
      eq_source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end
      """

      ord_source = """
      class Ord(a : Type) [Eq(a)] do
        compare : a -> a -> Int
      end
      """

      {:ok, [eq_ast]} = Haruspex.Parser.parse(eq_source)
      {:ok, [ord_ast]} = Haruspex.Parser.parse(ord_source)

      ctx = Elaborate.new()
      {:ok, _eq_decl, ctx} = Elaborate.elaborate_class_decl(ctx, eq_ast)
      {:ok, ord_decl, ctx} = Elaborate.elaborate_class_decl(ctx, ord_ast)

      # Ord has Eq as superclass.
      assert [{:Eq, _}] = ord_decl.superclasses

      # OrdDict record has eq_super field.
      ord_record = ctx.records[:OrdDict]
      field_names = Enum.map(ord_record.fields, fn {name, _} -> name end)
      assert :eq_super in field_names
      assert :compare in field_names
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp span, do: %Pentiment.Span.Byte{start: 0, length: 0}
end
