defmodule Haruspex.Quote do
  @moduledoc """
  Type-directed readback: values to core terms in normal form.

  Converts values back to core terms using the current context depth (level)
  to translate de Bruijn levels back to indices. Performs eta-expansion at
  Pi and Sigma types so that `f` and `fn x -> f(x)` are convertible.
  """

  alias Haruspex.Core
  alias Haruspex.Eval
  alias Haruspex.Value

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Type-directed readback with eta-expansion.

  `quote(level, type, value)` produces a core term in normal form.
  At Pi types, neutrals are eta-expanded to lambdas.
  At Sigma types, neutrals are eta-expanded to pairs.
  """
  @spec quote(Value.lvl(), Value.value(), Value.value(), keyword()) :: Core.expr()

  def quote(lvl, type, val, opts \\ [])

  # At Pi type: eta-expand.
  def quote(lvl, {:vpi, mult, dom, env, cod}, val, opts) do
    arg = Value.fresh_var(lvl, dom)
    body_val = Eval.vapp(Eval.default_ctx(), val, arg)
    cod_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, cod)
    {:lam, mult, quote(lvl + 1, cod_val, body_val, opts)}
  end

  # At Sigma type: eta-expand.
  def quote(lvl, {:vsigma, a, env, b}, val, opts) do
    fst_val = Eval.vfst(val)
    snd_val = Eval.vsnd(val)
    b_val = Eval.eval(%{Eval.default_ctx() | env: [fst_val | env]}, b)
    {:pair, quote(lvl, a, fst_val, opts), quote(lvl, b_val, snd_val, opts)}
  end

  # At record type (vdata that is a known record): eta-expand neutral to constructor.
  def quote(lvl, {:vdata, type_name, _type_args}, {:vneutral, _, _} = val, opts) do
    records = Keyword.get(opts, :records, %{})

    case Map.fetch(records, type_name) do
      {:ok, record_decl} ->
        # Eta-expand: project each field from the neutral and reconstruct.
        arity = length(record_decl.fields)

        field_terms =
          record_decl.fields
          |> Enum.with_index()
          |> Enum.map(fn {_field, idx} ->
            # Build: case val of mk_R(f0,..,fn) -> f_idx
            proj_body = {:var, arity - 1 - idx}

            {:case, quote_untyped(lvl, val), [{record_decl.constructor_name, arity, proj_body}]}
          end)

        {:con, type_name, record_decl.constructor_name, field_terms}

      :error ->
        # Not a record — fall through to structural neutral readback.
        quote_neutral(lvl, elem(val, 2))
    end
  end

  # At Type: quote the value structurally (types of types).
  def quote(lvl, {:vtype, _}, {:vpi, mult, dom, env, cod}, opts) do
    arg = Value.fresh_var(lvl, dom)
    cod_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, cod)

    {:pi, mult, quote(lvl, {:vtype, {:llit, 0}}, dom, opts),
     quote(lvl + 1, {:vtype, {:llit, 0}}, cod_val, opts)}
  end

  def quote(lvl, {:vtype, _}, {:vsigma, a, env, b}, opts) do
    arg = Value.fresh_var(lvl, a)
    b_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, b)

    {:sigma, quote(lvl, {:vtype, {:llit, 0}}, a, opts),
     quote(lvl + 1, {:vtype, {:llit, 0}}, b_val, opts)}
  end

  # Neutral at any type: structural readback.
  def quote(lvl, _type, {:vneutral, _ne_type, ne}, _opts) do
    quote_neutral(lvl, ne)
  end

  # Literals.
  def quote(_lvl, _type, {:vlit, v}, _opts) do
    {:lit, v}
  end

  # Universe.
  def quote(_lvl, _type, {:vtype, level}, _opts) do
    {:type, level}
  end

  # Builtin (as a value, e.g., a type like Int).
  def quote(_lvl, _type, {:vbuiltin, name}, _opts) when is_atom(name) do
    {:builtin, name}
  end

  # Partially applied builtin (shouldn't appear in normal forms, but handle gracefully).
  def quote(lvl, _type, {:vbuiltin, {name, args}}, _opts) do
    Enum.reduce(args, {:builtin, name}, fn arg, acc ->
      {:app, acc, quote_untyped(lvl, arg)}
    end)
  end

  # Pair (when not at Sigma type — structural).
  def quote(lvl, _type, {:vpair, a, b}, _opts) do
    {:pair, quote_untyped(lvl, a), quote_untyped(lvl, b)}
  end

  # Lambda (when not at Pi type — shouldn't happen in well-typed terms, but handle it).
  def quote(lvl, _type, {:vlam, mult, env, body}, _opts) do
    arg = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
    body_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, body)
    {:lam, mult, quote_untyped(lvl + 1, body_val)}
  end

  # ADT type constructor.
  def quote(lvl, _type, {:vdata, name, args}, _opts) do
    {:data, name, Enum.map(args, &quote_untyped(lvl, &1))}
  end

  # Data constructor.
  def quote(lvl, _type, {:vcon, type_name, con_name, args}, _opts) do
    {:con, type_name, con_name, Enum.map(args, &quote_untyped(lvl, &1))}
  end

  # Extern (opaque).
  def quote(_lvl, _type, {:vextern, mod, fun, arity}, _opts) do
    {:extern, mod, fun, arity}
  end

  # Global cross-module reference (opaque).
  def quote(_lvl, _type, {:vglobal, mod, name, arity}, _opts) do
    {:global, mod, name, arity}
  end

  # ============================================================================
  # Untyped readback
  # ============================================================================

  @doc """
  Structural readback without eta-expansion. Used for debugging and
  for quoting arguments in neutral application chains.
  """
  @spec quote_untyped(Value.lvl(), Value.value()) :: Core.expr()

  def quote_untyped(lvl, {:vneutral, _type, ne}) do
    quote_neutral(lvl, ne)
  end

  def quote_untyped(_lvl, {:vlit, v}), do: {:lit, v}
  def quote_untyped(_lvl, {:vtype, level}), do: {:type, level}
  def quote_untyped(_lvl, {:vbuiltin, name}) when is_atom(name), do: {:builtin, name}
  def quote_untyped(_lvl, {:vextern, mod, fun, arity}), do: {:extern, mod, fun, arity}
  def quote_untyped(_lvl, {:vglobal, mod, name, arity}), do: {:global, mod, name, arity}

  def quote_untyped(lvl, {:vdata, name, args}) do
    {:data, name, Enum.map(args, &quote_untyped(lvl, &1))}
  end

  def quote_untyped(lvl, {:vcon, type_name, con_name, args}) do
    {:con, type_name, con_name, Enum.map(args, &quote_untyped(lvl, &1))}
  end

  def quote_untyped(lvl, {:vbuiltin, {name, args}}) do
    Enum.reduce(args, {:builtin, name}, fn arg, acc ->
      {:app, acc, quote_untyped(lvl, arg)}
    end)
  end

  def quote_untyped(lvl, {:vpair, a, b}) do
    {:pair, quote_untyped(lvl, a), quote_untyped(lvl, b)}
  end

  def quote_untyped(lvl, {:vlam, mult, env, body}) do
    arg = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
    body_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, body)
    {:lam, mult, quote_untyped(lvl + 1, body_val)}
  end

  def quote_untyped(lvl, {:vpi, mult, dom, env, cod}) do
    arg = Value.fresh_var(lvl, dom)
    cod_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, cod)
    {:pi, mult, quote_untyped(lvl, dom), quote_untyped(lvl + 1, cod_val)}
  end

  def quote_untyped(lvl, {:vsigma, a, env, b}) do
    arg = Value.fresh_var(lvl, a)
    b_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, b)
    {:sigma, quote_untyped(lvl, a), quote_untyped(lvl + 1, b_val)}
  end

  # ============================================================================
  # Neutral readback
  # ============================================================================

  @spec quote_neutral(Value.lvl(), Value.neutral()) :: Core.expr()

  defp quote_neutral(lvl, {:nvar, level}) do
    {:var, lvl - level - 1}
  end

  defp quote_neutral(lvl, {:napp, ne, arg}) do
    {:app, quote_neutral(lvl, ne), quote_untyped(lvl, arg)}
  end

  defp quote_neutral(lvl, {:nfst, ne}) do
    {:fst, quote_neutral(lvl, ne)}
  end

  defp quote_neutral(lvl, {:nsnd, ne}) do
    {:snd, quote_neutral(lvl, ne)}
  end

  defp quote_neutral(_lvl, {:nmeta, id}) do
    {:meta, id}
  end

  defp quote_neutral(lvl, {:ndef, name, args}) do
    Enum.reduce(args, {:builtin, name}, fn arg, acc ->
      {:app, acc, quote_untyped(lvl, arg)}
    end)
  end

  defp quote_neutral(_lvl, {:nbuiltin, name}) do
    {:builtin, name}
  end

  defp quote_neutral(_lvl, {:ndef_ref, name}) do
    {:def_ref, name}
  end

  defp quote_neutral(lvl, {:ncase, ne, closures}) do
    {:case, quote_neutral(lvl, ne),
     Enum.map(closures, fn
       {:__lit, value, {env, body}} ->
         body_val = Eval.eval(%{Eval.default_ctx() | env: env}, body)
         {:__lit, value, quote_untyped(lvl, body_val)}

       {con_name, arity, {env, body}} ->
         # Open the closure with fresh vars for the constructor field bindings,
         # reversed to match the vcase env layout (last field at index 0).
         fresh_vars =
           for i <- 0..(arity - 1)//1, do: Value.fresh_var(lvl + i, {:vtype, {:llit, 0}})

         branch_env = Enum.reverse(fresh_vars) ++ env
         body_val = Eval.eval(%{Eval.default_ctx() | env: branch_env}, body)
         {con_name, arity, quote_untyped(lvl + arity, body_val)}
     end)}
  end
end
