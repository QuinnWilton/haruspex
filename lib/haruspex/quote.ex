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
  @spec quote(Value.lvl(), Value.value(), Value.value()) :: Core.expr()

  # At Pi type: eta-expand.
  def quote(lvl, {:vpi, mult, dom, env, cod}, val) do
    arg = Value.fresh_var(lvl, dom)
    body_val = Eval.vapp(Eval.default_ctx(), val, arg)
    cod_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, cod)
    {:lam, mult, quote(lvl + 1, cod_val, body_val)}
  end

  # At Sigma type: eta-expand.
  def quote(lvl, {:vsigma, a, env, b}, val) do
    fst_val = Eval.vfst(val)
    snd_val = Eval.vsnd(val)
    b_val = Eval.eval(%{Eval.default_ctx() | env: [fst_val | env]}, b)
    {:pair, quote(lvl, a, fst_val), quote(lvl, b_val, snd_val)}
  end

  # At Type: quote the value structurally (types of types).
  def quote(lvl, {:vtype, _}, {:vpi, mult, dom, env, cod}) do
    arg = Value.fresh_var(lvl, dom)
    cod_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, cod)

    {:pi, mult, quote(lvl, {:vtype, {:llit, 0}}, dom),
     quote(lvl + 1, {:vtype, {:llit, 0}}, cod_val)}
  end

  def quote(lvl, {:vtype, _}, {:vsigma, a, env, b}) do
    arg = Value.fresh_var(lvl, a)
    b_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, b)
    {:sigma, quote(lvl, {:vtype, {:llit, 0}}, a), quote(lvl + 1, {:vtype, {:llit, 0}}, b_val)}
  end

  # Neutral at any type: structural readback.
  def quote(lvl, _type, {:vneutral, _ne_type, ne}) do
    quote_neutral(lvl, ne)
  end

  # Literals.
  def quote(_lvl, _type, {:vlit, v}) do
    {:lit, v}
  end

  # Universe.
  def quote(_lvl, _type, {:vtype, level}) do
    {:type, level}
  end

  # Builtin (as a value, e.g., a type like Int).
  def quote(_lvl, _type, {:vbuiltin, name}) when is_atom(name) do
    {:builtin, name}
  end

  # Partially applied builtin (shouldn't appear in normal forms, but handle gracefully).
  def quote(lvl, _type, {:vbuiltin, {name, args}}) do
    Enum.reduce(args, {:builtin, name}, fn arg, acc ->
      {:app, acc, quote_untyped(lvl, arg)}
    end)
  end

  # Pair (when not at Sigma type — structural).
  def quote(lvl, _type, {:vpair, a, b}) do
    {:pair, quote_untyped(lvl, a), quote_untyped(lvl, b)}
  end

  # Lambda (when not at Pi type — shouldn't happen in well-typed terms, but handle it).
  def quote(lvl, _type, {:vlam, mult, env, body}) do
    arg = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
    body_val = Eval.eval(%{Eval.default_ctx() | env: [arg | env]}, body)
    {:lam, mult, quote_untyped(lvl + 1, body_val)}
  end

  # Extern (opaque).
  def quote(_lvl, _type, {:vextern, mod, fun, arity}) do
    {:extern, mod, fun, arity}
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
end
