defmodule Haruspex.Prelude.TypeClasses do
  @moduledoc """
  Prelude type class definitions: Num, Eq, Ord.

  These classes provide polymorphic signatures for arithmetic, equality,
  and ordering operations. Builtin instances for `Int` and `Float` delegate
  to the same delta rules as the hard-coded builtins, so monomorphic call
  sites (known `Int` or `Float`) compile to the same code as before.
  """

  alias Haruspex.TypeClass

  # ============================================================================
  # Class declarations
  # ============================================================================

  @doc """
  Return prelude class declarations as a map of `{name => class_decl}`.
  """
  @spec class_decls() :: %{atom() => TypeClass.class_decl()}
  def class_decls do
    %{
      Num: num_class(),
      Eq: eq_class(),
      Ord: ord_class()
    }
  end

  defp num_class do
    # class Num(a : Type) do
    #   add : a -> a -> a
    #   sub : a -> a -> a
    #   mul : a -> a -> a
    # end
    # De Bruijn indices shift under Pi binders:
    # Under 0 binders: var(0) = a
    # Under 1 binder:  var(1) = a
    # Under 2 binders: var(2) = a
    %{
      name: :Num,
      params: [{:a, {:type, {:llit, 0}}}],
      superclasses: [],
      methods: [
        {:add, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:var, 2}}}},
        {:sub, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:var, 2}}}},
        {:mul, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:var, 2}}}}
      ],
      defaults: [],
      dict_name: :NumDict,
      dict_constructor_name: :mk_NumDict,
      span: nil
    }
  end

  defp eq_class do
    # class Eq(a : Type) do
    #   eq : a -> a -> Bool
    # end
    %{
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
  end

  defp ord_class do
    # class Ord(a : Type) [Eq(a)] do
    #   compare : a -> a -> Int
    # end
    %{
      name: :Ord,
      params: [{:a, {:type, {:llit, 0}}}],
      superclasses: [{:Eq, [{:var, 0}]}],
      methods: [
        {:compare, {:pi, :omega, {:var, 0}, {:pi, :omega, {:var, 1}, {:builtin, :Int}}}}
      ],
      defaults: [],
      dict_name: :OrdDict,
      dict_constructor_name: :mk_OrdDict,
      span: nil
    }
  end

  # ============================================================================
  # Instance declarations
  # ============================================================================

  @doc """
  Return prelude instance entries as an instance database.
  """
  @spec instance_db() :: TypeClass.Search.instance_db()
  def instance_db do
    entries = [
      num_int(),
      num_float(),
      eq_int(),
      eq_float(),
      ord_int(),
      ord_float()
    ]

    Enum.reduce(entries, TypeClass.Search.empty_db(), &TypeClass.Search.register(&2, &1))
  end

  # Num(Int): add → :add, sub → :sub, mul → :mul
  defp num_int do
    %{
      class_name: :Num,
      n_params: 0,
      head: [{:builtin, :Int}],
      constraints: [],
      methods: [
        {:add, {:builtin, :add}},
        {:sub, {:builtin, :sub}},
        {:mul, {:builtin, :mul}}
      ],
      span: nil,
      module: :prelude
    }
  end

  # Num(Float): fadd → :fadd, fsub → :fsub, fmul → :fmul
  defp num_float do
    %{
      class_name: :Num,
      n_params: 0,
      head: [{:builtin, :Float}],
      constraints: [],
      methods: [
        {:add, {:builtin, :fadd}},
        {:sub, {:builtin, :fsub}},
        {:mul, {:builtin, :fmul}}
      ],
      span: nil,
      module: :prelude
    }
  end

  # Eq(Int): eq → :eq
  defp eq_int do
    %{
      class_name: :Eq,
      n_params: 0,
      head: [{:builtin, :Int}],
      constraints: [],
      methods: [{:eq, {:builtin, :eq}}],
      span: nil,
      module: :prelude
    }
  end

  # Eq(Float): eq → :eq (same builtin, works for both)
  defp eq_float do
    %{
      class_name: :Eq,
      n_params: 0,
      head: [{:builtin, :Float}],
      constraints: [],
      methods: [{:eq, {:builtin, :eq}}],
      span: nil,
      module: :prelude
    }
  end

  # Ord(Int): compare → :lt (placeholder, Ordering type not yet defined)
  defp ord_int do
    %{
      class_name: :Ord,
      n_params: 0,
      head: [{:builtin, :Int}],
      constraints: [],
      methods: [{:compare, {:builtin, :lt}}],
      span: nil,
      module: :prelude
    }
  end

  # Ord(Float): compare → :lt
  defp ord_float do
    %{
      class_name: :Ord,
      n_params: 0,
      head: [{:builtin, :Float}],
      constraints: [],
      methods: [{:compare, {:builtin, :lt}}],
      span: nil,
      module: :prelude
    }
  end

  # ============================================================================
  # Record declarations (dictionary structs)
  # ============================================================================

  @doc """
  Return dictionary record declarations for prelude classes.
  """
  @spec record_decls() :: %{atom() => map()}
  def record_decls do
    class_decls()
    |> Enum.map(fn {_name, decl} ->
      record = TypeClass.class_to_record(decl)
      {record.name, record}
    end)
    |> Map.new()
  end

  @doc """
  Return dictionary ADT declarations for prelude classes.
  """
  @spec adt_decls() :: %{atom() => map()}
  def adt_decls do
    record_decls()
    |> Enum.map(fn {name, record} ->
      adt = Haruspex.Record.record_to_adt(record)
      level = Haruspex.ADT.compute_level(adt)
      {name, %{adt | universe_level: level}}
    end)
    |> Map.new()
  end
end
