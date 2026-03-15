defmodule Haruspex.TypeClass do
  @moduledoc """
  Type class declarations and dictionary record type generation.

  A type class declaration generates a dictionary record type where each method
  becomes a field and superclass constraints become nested sub-dictionary fields.
  The dictionary record desugars to a single-constructor ADT following the same
  pattern as `Haruspex.Record`.
  """

  alias Haruspex.Core
  alias Haruspex.Record

  # ============================================================================
  # Types
  # ============================================================================

  @type class_constraint :: {atom(), [Core.expr()]}

  @type instance_decl :: %{
          class_name: atom(),
          args: [Core.expr()],
          n_params: non_neg_integer(),
          constraints: [class_constraint()],
          methods: [{atom(), Core.expr()}],
          span: Pentiment.Span.Byte.t() | nil,
          module: atom() | nil,
          orphan_warning: nil | {:orphan_instance, atom(), Pentiment.Span.Byte.t() | nil}
        }

  @type class_decl :: %{
          name: atom(),
          params: [{atom(), Core.expr()}],
          superclasses: [class_constraint()],
          methods: [{atom(), Core.expr()}],
          defaults: [{atom(), Core.expr()}],
          dict_name: atom(),
          dict_constructor_name: atom(),
          span: Pentiment.Span.Byte.t() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate the dictionary name for a class.
  """
  @spec dict_name(atom()) :: atom()
  def dict_name(class_name) do
    :"#{class_name}Dict"
  end

  @doc """
  Generate the dictionary constructor name for a class.
  """
  @spec dict_constructor_name(atom()) :: atom()
  def dict_constructor_name(class_name) do
    Record.constructor_name(dict_name(class_name))
  end

  @doc """
  Generate a superclass field name.
  """
  @spec superclass_field_name(atom()) :: atom()
  def superclass_field_name(class_name) do
    lower =
      class_name
      |> Atom.to_string()
      |> Macro.underscore()

    :"#{lower}_super"
  end

  @doc """
  Convert a class declaration to a dictionary record declaration.

  The dictionary record has:
  - One field per superclass constraint (nested sub-dictionary).
  - One field per class method.
  - Same type parameters as the class.
  """
  @spec class_to_record(class_decl()) :: Record.record_decl()
  def class_to_record(decl) do
    # Superclass fields: each constraint {ClassName, args} becomes a field
    # named `classname_super` with type `ClassNameDict(args...)`.
    super_fields =
      Enum.map(decl.superclasses, fn {super_name, args} ->
        field_name = superclass_field_name(super_name)

        # Build the dictionary type application: SuperDict(args...).
        dict_type_name = dict_name(super_name)

        dict_type =
          case args do
            [] -> {:data, dict_type_name, []}
            _ -> {:data, dict_type_name, args}
          end

        {field_name, dict_type}
      end)

    # Method fields: each {name, type} pair becomes a record field.
    method_fields =
      Enum.map(decl.methods, fn {method_name, method_type} ->
        {method_name, method_type}
      end)

    fields = super_fields ++ method_fields
    dict = dict_name(decl.name)
    con = dict_constructor_name(decl.name)

    # Shift field types to account for the superclass fields preceding methods.
    # Superclass fields are in the record telescope, so method types may need
    # adjustment. However, since class methods reference only class params
    # (not other fields), no shifting is needed here — the fields don't form
    # a dependent telescope within the dictionary.
    %{
      name: dict,
      params: decl.params,
      fields: fields,
      constructor_name: con,
      span: decl.span
    }
  end

  @doc """
  Look up a method's type in a class declaration.

  Returns `{:ok, type_core}` or `:error`.
  """
  @spec method_type(class_decl(), atom()) :: {:ok, Core.expr()} | :error
  def method_type(decl, method_name) do
    case List.keyfind(decl.methods, method_name, 0) do
      {^method_name, type} -> {:ok, type}
      nil -> :error
    end
  end

  @doc """
  Look up a default method implementation in a class declaration.

  Returns `{:ok, body_core}` or `:error`.
  """
  @spec default_method(class_decl(), atom()) :: {:ok, Core.expr()} | :error
  def default_method(decl, method_name) do
    case List.keyfind(decl.defaults, method_name, 0) do
      {^method_name, body} -> {:ok, body}
      nil -> :error
    end
  end

  @doc """
  List all method names defined by a class.
  """
  @spec method_names(class_decl()) :: [atom()]
  def method_names(decl) do
    Enum.map(decl.methods, fn {name, _type} -> name end)
  end
end
