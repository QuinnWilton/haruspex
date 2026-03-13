defmodule Haruspex.Record do
  @moduledoc """
  Record declarations as single-constructor ADTs with named field projections.

  Records desugar to single-constructor ADTs in the core language but retain
  their record identity for field access, construction, and pattern matching.
  The constructor is named `mk_<RecordName>`.
  """

  alias Haruspex.Core

  # ============================================================================
  # Types
  # ============================================================================

  @type record_decl :: %{
          name: atom(),
          params: [{atom(), Core.expr()}],
          fields: [{atom(), Core.expr()}],
          constructor_name: atom(),
          span: Pentiment.Span.Byte.t() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Convert a record declaration to a single-constructor ADT declaration.

  The ADT has one constructor named `mk_<name>` with positional fields
  matching the record's named fields in declaration order.
  """
  @spec record_to_adt(record_decl()) :: Haruspex.ADT.adt_decl()
  def record_to_adt(decl) do
    n_params = length(decl.params)
    n_fields = length(decl.fields)

    # Default return type: the record type applied to its param variables.
    # Under the field + param binders, params are at indices (n_fields + n_params - 1) down to n_fields.
    return_type =
      case n_params do
        0 ->
          {:data, decl.name, []}

        _ ->
          args =
            Enum.map((n_params - 1)..0//-1, fn i ->
              {:var, n_fields + i}
            end)

          {:data, decl.name, args}
      end

    con = %{
      name: decl.constructor_name,
      fields: Enum.map(decl.fields, fn {_name, type} -> type end),
      return_type: return_type,
      span: decl.span
    }

    %{
      name: decl.name,
      params: decl.params,
      constructors: [con],
      universe_level: {:llit, 0},
      span: decl.span
    }
  end

  @doc """
  Look up a field's index and type in a record declaration.

  Returns `{:ok, index, type_core}` or `:error`.
  """
  @spec field_info(record_decl(), atom()) :: {:ok, non_neg_integer(), Core.expr()} | :error
  def field_info(decl, field_name) do
    decl.fields
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {{name, type}, idx} ->
      if name == field_name, do: {:ok, idx, type}
    end)
  end

  @doc """
  Generate the constructor name for a record.
  """
  @spec constructor_name(atom()) :: atom()
  def constructor_name(record_name) do
    :"mk_#{record_name}"
  end
end
