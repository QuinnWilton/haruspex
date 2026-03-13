defmodule Haruspex.ADT do
  @moduledoc """
  Algebraic data type declarations, constructor typing, and strict positivity checking.

  ADTs are defined via `type` declarations and have constructors whose types are
  computed as Pi types from their fields to the fully-applied data type.
  """

  alias Haruspex.Core

  # ============================================================================
  # Types
  # ============================================================================

  @type adt_decl :: %{
          name: atom(),
          params: [{atom(), Core.expr()}],
          constructors: [constructor_decl()],
          universe_level: Core.level(),
          span: Pentiment.Span.Byte.t() | nil
        }

  @type constructor_decl :: %{
          name: atom(),
          fields: [Core.expr()],
          return_type: Core.expr() | nil,
          span: Pentiment.Span.Byte.t() | nil
        }

  # ============================================================================
  # Strict positivity
  # ============================================================================

  @doc """
  Check that an ADT declaration satisfies the strict positivity condition.

  The defined type name may appear in constructor fields, but only in strictly
  positive positions (not to the left of an arrow).
  """
  @spec check_positivity(adt_decl()) :: :ok | {:error, {:negative_occurrence, atom(), atom()}}
  def check_positivity(decl) do
    check_positivity_group([decl])
  end

  @doc """
  Check strict positivity for a mutual group of type declarations.

  A negative occurrence of any type name in any constructor field rejects
  the entire group.
  """
  @spec check_positivity_group([adt_decl()]) ::
          :ok | {:error, {:negative_occurrence, atom(), atom()}}
  def check_positivity_group(decls) do
    type_names = MapSet.new(decls, & &1.name)

    Enum.reduce_while(decls, :ok, fn decl, :ok ->
      case check_decl_positivity(decl, type_names) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp check_decl_positivity(decl, type_names) do
    Enum.reduce_while(decl.constructors, :ok, fn con, :ok ->
      case check_constructor_positivity(con, type_names) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp check_constructor_positivity(con, type_names) do
    Enum.reduce_while(con.fields, :ok, fn field_type, :ok ->
      case check_strictly_positive(type_names, field_type) do
        :ok -> {:cont, :ok}
        {:error, name} -> {:halt, {:error, {:negative_occurrence, name, con.name}}}
      end
    end)
  end

  @doc """
  Check that a type expression is strictly positive with respect to a set of type names.
  """
  @spec check_strictly_positive(MapSet.t(), Core.expr()) :: :ok | {:error, atom()}
  def check_strictly_positive(type_names, type) do
    cond do
      not mentions_any?(type_names, type) ->
        :ok

      true ->
        do_check_positive(type_names, type)
    end
  end

  defp do_check_positive(type_names, {:data, name, _args}) do
    if MapSet.member?(type_names, name), do: :ok, else: :ok
  end

  defp do_check_positive(type_names, {:pi, _mult, domain, codomain}) do
    # The defined type must NOT appear in the domain (negative position).
    if mentions_any?(type_names, domain) do
      find_mentioned(type_names, domain)
    else
      do_check_positive(type_names, codomain)
    end
  end

  defp do_check_positive(_type_names, _type), do: :ok

  defp mentions_any?(type_names, {:data, name, args}) do
    MapSet.member?(type_names, name) or Enum.any?(args, &mentions_any?(type_names, &1))
  end

  defp mentions_any?(type_names, {:pi, _mult, domain, codomain}) do
    mentions_any?(type_names, domain) or mentions_any?(type_names, codomain)
  end

  defp mentions_any?(type_names, {:app, f, a}) do
    mentions_any?(type_names, f) or mentions_any?(type_names, a)
  end

  defp mentions_any?(type_names, {:con, type_name, _con_name, args}) do
    MapSet.member?(type_names, type_name) or Enum.any?(args, &mentions_any?(type_names, &1))
  end

  defp mentions_any?(_type_names, _), do: false

  defp find_mentioned(type_names, expr) do
    case expr do
      {:data, name, _} ->
        if MapSet.member?(type_names, name), do: {:error, name}, else: :ok

      {:pi, _, dom, cod} ->
        case find_mentioned(type_names, dom) do
          :ok -> find_mentioned(type_names, cod)
          err -> err
        end

      {:app, f, a} ->
        case find_mentioned(type_names, f) do
          :ok -> find_mentioned(type_names, a)
          err -> err
        end

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Constructor type computation
  # ============================================================================

  @doc """
  Compute the full type of a constructor as a Pi type.

  Given an ADT with params `[{a, Type}]` and a constructor `some(x : a) : Option(a)`,
  produces `{a : Type} -> a -> Option(a)`.
  """
  @spec constructor_type(adt_decl(), atom()) :: Core.expr()
  def constructor_type(decl, con_name) do
    con = Enum.find(decl.constructors, &(&1.name == con_name))

    # The return type is the fully-applied data type.
    n_params = length(decl.params)

    return_type =
      case con.return_type do
        nil ->
          # Default return type: the data type applied to its params as variables.
          # Under the field binders and param binders, the params are at indices
          # (n_fields + n_params - 1) down to n_fields.
          n_fields = length(con.fields)

          args =
            Enum.map((n_params - 1)..0//-1, fn i ->
              {:var, n_fields + i}
            end)

          {:data, decl.name, args}

        rt ->
          rt
      end

    # Build: fields -> return_type (innermost Pi chain).
    inner =
      con.fields
      |> Enum.reverse()
      |> Enum.reduce(return_type, fn field_type, acc ->
        {:pi, :omega, field_type, acc}
      end)

    # Wrap with implicit params: {a : Type} -> ... (outermost).
    decl.params
    |> Enum.reverse()
    |> Enum.reduce(inner, fn {_name, kind}, acc ->
      {:pi, :zero, kind, acc}
    end)
  end

  # ============================================================================
  # Universe level computation
  # ============================================================================

  @doc """
  Compute the universe level of an ADT from its parameters and constructor fields.
  """
  @spec compute_level(adt_decl()) :: Core.level()
  def compute_level(decl) do
    param_levels =
      Enum.map(decl.params, fn {_name, kind} ->
        universe_of(kind)
      end)

    field_levels =
      Enum.flat_map(decl.constructors, fn con ->
        Enum.map(con.fields, &universe_of/1)
      end)

    all_levels = param_levels ++ field_levels

    case all_levels do
      [] -> {:llit, 0}
      [l] -> l
      [l | rest] -> Enum.reduce(rest, l, fn r, acc -> {:lmax, acc, r} end)
    end
  end

  defp universe_of({:type, level}), do: {:lsucc, level}
  defp universe_of({:builtin, _}), do: {:llit, 0}
  defp universe_of({:data, _, _}), do: {:llit, 0}
  defp universe_of({:pi, _, _, _}), do: {:llit, 0}
  defp universe_of({:var, _}), do: {:llit, 0}
  defp universe_of(_), do: {:llit, 0}
end
