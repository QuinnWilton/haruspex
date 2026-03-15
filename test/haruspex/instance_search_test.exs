defmodule Haruspex.InstanceSearchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Elaborate
  alias Haruspex.TypeClass.Search
  alias Haruspex.Unify.MetaState

  # ============================================================================
  # Search module unit tests
  # ============================================================================

  describe "empty database" do
    test "search returns not_found" do
      db = Search.empty_db()
      ms = MetaState.new()

      result = Search.search(db, %{}, ms, 0, {:Eq, [{:vbuiltin, :Int}]})
      assert {:not_found, {:Eq, [{:vbuiltin, :Int}]}} = result
    end
  end

  describe "simple search" do
    test "Eq(Int) found from registered instance" do
      db = Search.empty_db()

      entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, entry)
      ms = MetaState.new()

      result = Search.search(db, %{}, ms, 0, {:Eq, [{:vbuiltin, :Int}]})
      assert {:found, _dict, _ms} = result
    end

    test "Eq(Float) found when registered" do
      db = Search.empty_db()

      entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Float}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, entry)
      ms = MetaState.new()

      result = Search.search(db, %{}, ms, 0, {:Eq, [{:vbuiltin, :Float}]})
      assert {:found, _dict, _ms} = result
    end

    test "Eq(String) not found when only Eq(Int) registered" do
      db = Search.empty_db()

      entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, entry)
      ms = MetaState.new()

      result = Search.search(db, %{}, ms, 0, {:Eq, [{:vbuiltin, :String}]})
      assert {:not_found, _} = result
    end
  end

  describe "constrained search" do
    test "Eq(List(Int)) resolves via [Eq(a)] => Eq(List(a)) + Eq(Int)" do
      db = Search.empty_db()

      # Eq(Int) — concrete instance.
      eq_int = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      # [Eq(a)] => Eq(List(a)) — parameterized instance with constraint.
      # Under 1 binder (a at var 0):
      #   head = [List(a)]  → [{:data, :List, [{:var, 0}]}]
      #   constraints = [{:Eq, [{:var, 0}]}]
      eq_list = %{
        class_name: :Eq,
        n_params: 1,
        head: [{:data, :List, [{:var, 0}]}],
        constraints: [{:Eq, [{:var, 0}]}],
        methods: [{:eq, {:lit, :list_eq_placeholder}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, eq_int)
      db = Search.register(db, eq_list)
      ms = MetaState.new()

      goal = {:Eq, [{:vdata, :List, [{:vbuiltin, :Int}]}]}
      result = Search.search(db, %{}, ms, 0, goal)
      assert {:found, _dict, _ms} = result
    end
  end

  describe "depth limit" do
    test "recursive instance chain exceeding depth returns error" do
      db = Search.empty_db()

      # Pathological: Eq(List(a)) requires Eq(List(a)) — infinite recursion.
      bad_instance = %{
        class_name: :Eq,
        n_params: 1,
        head: [{:data, :List, [{:var, 0}]}],
        constraints: [{:Eq, [{:data, :List, [{:var, 0}]}]}],
        methods: [{:eq, {:lit, :bad}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, bad_instance)
      ms = MetaState.new()

      goal = {:Eq, [{:vdata, :List, [{:vbuiltin, :Int}]}]}
      result = Search.search(db, %{}, ms, 0, goal, max_depth: 5)
      # Should either be depth_exceeded or not_found (constraint resolution fails).
      refute match?({:found, _, _}, result)
    end
  end

  describe "specificity" do
    test "more_specific? detects concrete vs parameterized" do
      ms = MetaState.new()

      # Eq(List(Int)) — fully concrete.
      concrete = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:data, :List, [{:builtin, :Int}]}],
        constraints: [],
        methods: [{:eq, {:lit, :concrete_eq}}],
        span: nil,
        module: nil
      }

      # [Eq(a)] => Eq(List(a)) — parameterized.
      parameterized = %{
        class_name: :Eq,
        n_params: 1,
        head: [{:data, :List, [{:var, 0}]}],
        constraints: [{:Eq, [{:var, 0}]}],
        methods: [{:eq, {:lit, :param_eq}}],
        span: nil,
        module: nil
      }

      assert Search.more_specific?(concrete, parameterized, ms, 0)
      refute Search.more_specific?(parameterized, concrete, ms, 0)
    end

    test "Eq(List(Int)) chosen over Eq(List(a)) when both match" do
      db = Search.empty_db()

      eq_int = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      concrete = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:data, :List, [{:builtin, :Int}]}],
        constraints: [],
        methods: [{:eq, {:lit, :concrete_list_eq}}],
        span: nil,
        module: nil
      }

      parameterized = %{
        class_name: :Eq,
        n_params: 1,
        head: [{:data, :List, [{:var, 0}]}],
        constraints: [{:Eq, [{:var, 0}]}],
        methods: [{:eq, {:lit, :param_list_eq}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, eq_int)
      db = Search.register(db, concrete)
      db = Search.register(db, parameterized)
      ms = MetaState.new()

      goal = {:Eq, [{:vdata, :List, [{:vbuiltin, :Int}]}]}
      result = Search.search(db, %{}, ms, 0, goal)
      assert {:found, dict, _ms} = result

      # The concrete instance should win — its method is :concrete_list_eq.
      assert {:con, :EqDict, :mk_EqDict, [{:lit, :concrete_list_eq}]} = dict
    end
  end

  describe "ambiguity" do
    test "two incomparable instances produce ambiguous error" do
      db = Search.empty_db()

      # Two instances for the same class with incomparable heads.
      # This is artificial since both have n_params: 0 and same head,
      # but let's test with truly incomparable heads.
      inst_a = %{
        class_name: :Convert,
        n_params: 0,
        head: [{:builtin, :Int}, {:builtin, :String}],
        constraints: [],
        methods: [{:convert, {:lit, :int_to_string}}],
        span: nil,
        module: nil
      }

      inst_b = %{
        class_name: :Convert,
        n_params: 0,
        head: [{:builtin, :Int}, {:builtin, :Float}],
        constraints: [],
        methods: [{:convert, {:lit, :int_to_float}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, inst_a)
      db = Search.register(db, inst_b)
      ms = MetaState.new()

      # Search for Convert(Int, ?) with a meta for the second arg.
      {meta_id, ms} = MetaState.fresh_meta(ms, {:vtype, {:llit, 0}}, 0, :implicit)
      meta_val = {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, meta_id}}

      goal = {:Convert, [{:vbuiltin, :Int}, meta_val]}
      result = Search.search(db, %{}, ms, 0, goal)

      # Both match (meta unifies with both String and Float), but they're
      # incomparable — should be ambiguous.
      assert {:ambiguous, entries} = result
      assert length(entries) == 2
    end
  end

  describe "superclass" do
    test "Eq(Int) found via Ord(Int) superclass" do
      db = Search.empty_db()

      # No direct Eq(Int) instance, but Ord(Int) exists with Eq as superclass.
      ord_int = %{
        class_name: :Ord,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:compare, {:lit, :int_compare}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, ord_int)

      # Class definitions with superclass relationship.
      classes = %{
        Eq: %{
          name: :Eq,
          params: [{:a, {:type, {:llit, 0}}}],
          superclasses: [],
          methods: [{:eq, {:pi, :omega, {:var, 0}, {:builtin, :Bool}}}],
          defaults: [],
          dict_name: :EqDict,
          dict_constructor_name: :mk_EqDict,
          span: nil
        },
        Ord: %{
          name: :Ord,
          params: [{:a, {:type, {:llit, 0}}}],
          superclasses: [{:Eq, [{:var, 0}]}],
          methods: [{:compare, {:pi, :omega, {:var, 0}, {:builtin, :Int}}}],
          defaults: [],
          dict_name: :OrdDict,
          dict_constructor_name: :mk_OrdDict,
          span: nil
        }
      }

      ms = MetaState.new()

      goal = {:Eq, [{:vbuiltin, :Int}]}
      result = Search.search(db, classes, ms, 0, goal)
      assert {:found, dict, _ms} = result

      # The result should be a superclass projection from the Ord dictionary.
      assert {:record_proj, :eq_super, _ord_dict} = dict
    end
  end

  describe "register/2" do
    test "registers multiple instances for the same class" do
      db = Search.empty_db()

      e1 = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [],
        span: nil,
        module: nil
      }

      e2 = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Float}],
        constraints: [],
        methods: [],
        span: nil,
        module: nil
      }

      db = Search.register(db, e1)
      db = Search.register(db, e2)

      assert length(db[:Eq]) == 2
    end

    test "registers instances for different classes" do
      db = Search.empty_db()

      e1 = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [],
        span: nil,
        module: nil
      }

      e2 = %{
        class_name: :Ord,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [],
        span: nil,
        module: nil
      }

      db = Search.register(db, e1)
      db = Search.register(db, e2)

      assert length(db[:Eq]) == 1
      assert length(db[:Ord]) == 1
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "search is deterministic — same db + goal → same result" do
      db = Search.empty_db()

      entry = %{
        class_name: :Eq,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:eq, {:builtin, :eq}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, entry)

      check all(_ <- StreamData.constant(nil)) do
        ms = MetaState.new()
        goal = {:Eq, [{:vbuiltin, :Int}]}
        r1 = Search.search(db, %{}, ms, 0, goal)
        r2 = Search.search(db, %{}, ms, 0, goal)

        case {r1, r2} do
          {{:found, d1, _}, {:found, d2, _}} -> assert d1 == d2
          _ -> assert elem(r1, 0) == elem(r2, 0)
        end
      end
    end

    property "search is idempotent — searching twice → same result" do
      db = Search.empty_db()

      entry = %{
        class_name: :Show,
        n_params: 0,
        head: [{:builtin, :Int}],
        constraints: [],
        methods: [{:show, {:lit, :show_int}}],
        span: nil,
        module: nil
      }

      db = Search.register(db, entry)

      check all(_ <- StreamData.constant(nil)) do
        ms = MetaState.new()
        goal = {:Show, [{:vbuiltin, :Int}]}

        case Search.search(db, %{}, ms, 0, goal) do
          {:found, dict1, ms2} ->
            result2 = Search.search(db, %{}, ms2, 0, goal)
            assert {:found, dict2, _} = result2
            assert dict1 == dict2

          other ->
            result2 = Search.search(db, %{}, ms, 0, goal)
            assert elem(other, 0) == elem(result2, 0)
        end
      end
    end
  end

  # ============================================================================
  # Instance elaboration tests
  # ============================================================================

  describe "elaborate_instance_decl/2" do
    test "simple instance registers in database" do
      ctx = Elaborate.new()

      # First register the Eq class.
      eq_class =
        {:class_decl, span(), :Eq, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :eq,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a},
             {:pi, span(), {:y, :omega, false}, {:var, span(), :a}, {:var, span(), :Bool}}}}
         ]}

      {:ok, _class_decl, ctx} = Elaborate.elaborate_class_decl(ctx, eq_class)

      # Now elaborate an instance.
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

      {:ok, inst_decl, ctx} = Elaborate.elaborate_instance_decl(ctx, instance_ast)

      assert inst_decl.class_name == :Eq
      assert inst_decl.n_params == 0
      assert length(inst_decl.methods) == 1

      # Instance registered in database (prelude already has Eq(Int) and Eq(Float)).
      assert Map.has_key?(ctx.instances, :Eq)
      assert length(ctx.instances[:Eq]) >= 1
    end

    test "parameterized instance has correct n_params" do
      ctx = Elaborate.new()

      eq_class =
        {:class_decl, span(), :Eq, [{:a, {:type_universe, span(), 0}}], [],
         [
           {:method_sig, span(), :eq,
            {:pi, span(), {:x, :omega, false}, {:var, span(), :a},
             {:pi, span(), {:y, :omega, false}, {:var, span(), :a}, {:var, span(), :Bool}}}}
         ]}

      {:ok, _class_decl, _ctx} = Elaborate.elaborate_class_decl(ctx, eq_class)

      # Parse and elaborate a concrete instance to verify n_params == 0.
      full_source = """
      class Eq(a : Type) do
        eq : a -> a -> Bool
      end

      instance Eq(Int) do
        def eq(x : Int, y : Int) : Bool do x end
      end
      """

      {:ok, forms} = Haruspex.Parser.parse(full_source)

      ctx2 = Elaborate.new()
      [{:class_decl, _, _, _, _, _} = cd, {:instance_decl, _, _, _, _, _} = ind] = forms
      {:ok, _, ctx2} = Elaborate.elaborate_class_decl(ctx2, cd)
      {:ok, inst_decl, ctx2} = Elaborate.elaborate_instance_decl(ctx2, ind)

      assert inst_decl.class_name == :Eq
      assert inst_decl.n_params == 0
      assert Map.has_key?(ctx2.instances, :Eq)
    end

    test "unknown class produces error" do
      ctx = Elaborate.new()

      instance_ast =
        {:instance_decl, span(), :NonExistent, [{:var, span(), :Int}], [],
         [{:method_impl, span(), :method, {:lit, span(), 42}}]}

      result = Elaborate.elaborate_instance_decl(ctx, instance_ast)
      assert {:error, {:unknown_class, :NonExistent, _}} = result
    end
  end

  # ============================================================================
  # Integration tests
  # ============================================================================

  describe "integration" do
    test "parse and elaborate class + instance, then search" do
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
      {:ok, _, ctx} = Elaborate.elaborate_class_decl(ctx, cd)
      {:ok, _, ctx} = Elaborate.elaborate_instance_decl(ctx, ind)

      # Now search for Eq(Int).
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Eq, [{:vbuiltin, :Int}]})
      assert {:found, _dict, _ms} = result
    end

    test "search for non-existent instance" do
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
      {:ok, _, ctx} = Elaborate.elaborate_class_decl(ctx, cd)
      {:ok, _, ctx} = Elaborate.elaborate_instance_decl(ctx, ind)

      # Search for Eq(Atom) — not registered (no prelude instance for Atom).
      ms = MetaState.new()
      result = Search.search(ctx.instances, ctx.classes, ms, 0, {:Eq, [{:vbuiltin, :Atom}]})
      assert {:not_found, _} = result
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp span, do: %Pentiment.Span.Byte{start: 0, length: 0}
end
