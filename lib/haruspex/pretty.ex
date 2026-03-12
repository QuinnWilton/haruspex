defmodule Haruspex.Pretty do
  @moduledoc """
  Value to string pretty-printer with name recovery from de Bruijn levels.

  Recovers human-readable names by mapping de Bruijn levels back to a
  provided name list. Handles shadowing by appending primes (x, x', x'').
  """

  alias Haruspex.Core
  alias Haruspex.Value

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Pretty-print a value using the given name list and current level.

  The name list is indexed by de Bruijn level (0 = oldest binding).
  The current level is used to generate fresh names for binders.
  """
  @spec pretty(Value.value(), [atom()], non_neg_integer()) :: String.t()
  def pretty(value, names \\ [], level \\ 0) do
    disambig = build_disambiguation(names)
    do_pretty(value, names, level, disambig)
  end

  @doc """
  Pretty-print a core term using the given name list.
  """
  @spec pretty_term(Core.expr(), [atom()]) :: String.t()
  def pretty_term(term, names \\ []) do
    disambig = build_disambiguation(names)
    do_pretty_term(term, names, length(names), disambig)
  end

  # ============================================================================
  # Disambiguation
  # ============================================================================

  # Build a map from level to disambiguated name string.
  # When the same atom appears at multiple levels, later occurrences get primes.
  @spec build_disambiguation([atom()]) :: %{non_neg_integer() => String.t()}
  defp build_disambiguation(names) do
    names
    |> Enum.with_index()
    |> Enum.reduce({%{}, %{}}, fn {name, level}, {disambig, seen_counts} ->
      count = Map.get(seen_counts, name, 0)
      display = Atom.to_string(name) <> String.duplicate("'", count)
      {Map.put(disambig, level, display), Map.put(seen_counts, name, count + 1)}
    end)
    |> elem(0)
  end

  # ============================================================================
  # Value pretty-printing
  # ============================================================================

  defp do_pretty({:vlit, value}, _names, _level, _disambig) do
    pretty_literal(value)
  end

  defp do_pretty({:vbuiltin, name}, _names, _level, _disambig) when is_atom(name) do
    pretty_builtin_name(name)
  end

  defp do_pretty({:vbuiltin, {name, args}}, names, level, disambig) do
    base = pretty_builtin_name(name)

    args
    |> Enum.reduce(base, fn arg, acc ->
      acc <> "(" <> do_pretty(arg, names, level, disambig) <> ")"
    end)
  end

  defp do_pretty({:vtype, level_val}, _names, _level, _disambig) do
    pretty_universe(level_val)
  end

  defp do_pretty({:vpair, a, b}, names, level, disambig) do
    "(" <>
      do_pretty(a, names, level, disambig) <>
      ", " <>
      do_pretty(b, names, level, disambig) <>
      ")"
  end

  defp do_pretty({:vpi, mult, dom, env, cod}, names, level, disambig) do
    # Check if the codomain body references var 0 (the bound variable).
    if uses_var_zero?(cod) do
      # Dependent: show binding.
      fresh = pick_name(names, level)
      new_names = names ++ [fresh]
      new_disambig = build_disambiguation(new_names)

      arg = Value.fresh_var(level, dom)
      cod_val = eval_closure(env, cod, arg)

      dom_str = do_pretty(dom, names, level, disambig)
      cod_str = do_pretty(cod_val, new_names, level + 1, new_disambig)
      binder_name = Map.get(new_disambig, level, Atom.to_string(fresh))

      case mult do
        :zero ->
          "{" <> binder_name <> " : " <> dom_str <> "} -> " <> cod_str

        :omega ->
          "(" <> binder_name <> " : " <> dom_str <> ") -> " <> cod_str
      end
    else
      # Non-dependent: arrow sugar.
      arg = Value.fresh_var(level, dom)
      cod_val = eval_closure(env, cod, arg)
      new_names = names ++ [pick_name(names, level)]
      new_disambig = build_disambiguation(new_names)

      dom_str = do_pretty_parens_if_arrow(dom, names, level, disambig)
      cod_str = do_pretty(cod_val, new_names, level + 1, new_disambig)

      case mult do
        :zero ->
          # Implicit non-dependent: still show braces.
          fresh = pick_name(names, level)
          binder_name = Map.get(new_disambig, level, Atom.to_string(fresh))
          "{" <> binder_name <> " : " <> dom_str <> "} -> " <> cod_str

        :omega ->
          dom_str <> " -> " <> cod_str
      end
    end
  end

  defp do_pretty({:vsigma, a, env, b}, names, level, disambig) do
    if uses_var_zero?(b) do
      # Dependent sigma: show binding.
      fresh = pick_name(names, level)
      new_names = names ++ [fresh]
      new_disambig = build_disambiguation(new_names)

      arg = Value.fresh_var(level, a)
      b_val = eval_closure(env, b, arg)

      a_str = do_pretty(a, names, level, disambig)
      b_str = do_pretty(b_val, new_names, level + 1, new_disambig)
      binder_name = Map.get(new_disambig, level, Atom.to_string(fresh))

      "(" <> binder_name <> " : " <> a_str <> ", " <> b_str <> ")"
    else
      # Non-dependent: product sugar.
      arg = Value.fresh_var(level, a)
      b_val = eval_closure(env, b, arg)
      new_names = names ++ [pick_name(names, level)]
      new_disambig = build_disambiguation(new_names)

      a_str = do_pretty(a, names, level, disambig)
      b_str = do_pretty(b_val, new_names, level + 1, new_disambig)

      a_str <> " * " <> b_str
    end
  end

  defp do_pretty({:vlam, _mult, env, body}, names, level, _disambig) do
    fresh = pick_name(names, level)
    new_names = names ++ [fresh]
    new_disambig = build_disambiguation(new_names)

    arg = Value.fresh_var(level, {:vtype, {:llit, 0}})
    body_val = eval_closure(env, body, arg)
    binder_name = Map.get(new_disambig, level, Atom.to_string(fresh))
    body_str = do_pretty(body_val, new_names, level + 1, new_disambig)

    "fn(" <> binder_name <> ") do " <> body_str <> " end"
  end

  defp do_pretty({:vneutral, _type, ne}, names, level, disambig) do
    do_pretty_neutral(ne, names, level, disambig)
  end

  defp do_pretty({:vextern, mod, fun, arity}, _names, _level, _disambig) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  # ============================================================================
  # Neutral pretty-printing
  # ============================================================================

  defp do_pretty_neutral({:nvar, lvl}, _names, _level, disambig) do
    case Map.get(disambig, lvl) do
      nil -> "_v#{lvl}"
      name -> name
    end
  end

  defp do_pretty_neutral({:napp, ne, arg}, names, level, disambig) do
    ne_str = do_pretty_neutral(ne, names, level, disambig)
    arg_str = do_pretty(arg, names, level, disambig)
    ne_str <> "(" <> arg_str <> ")"
  end

  defp do_pretty_neutral({:nfst, ne}, names, level, disambig) do
    do_pretty_neutral(ne, names, level, disambig) <> ".1"
  end

  defp do_pretty_neutral({:nsnd, ne}, names, level, disambig) do
    do_pretty_neutral(ne, names, level, disambig) <> ".2"
  end

  defp do_pretty_neutral({:nmeta, id}, _names, _level, _disambig) do
    "?#{id}"
  end

  defp do_pretty_neutral({:ndef, name, args}, names, level, disambig) do
    base = inspect(name)

    Enum.reduce(args, base, fn arg, acc ->
      acc <> "(" <> do_pretty(arg, names, level, disambig) <> ")"
    end)
  end

  defp do_pretty_neutral({:nbuiltin, name}, _names, _level, _disambig) do
    pretty_builtin_name(name)
  end

  # ============================================================================
  # Core term pretty-printing
  # ============================================================================

  defp do_pretty_term({:var, ix}, _names, depth, disambig) do
    # Convert de Bruijn index to level.
    lvl = depth - ix - 1

    case Map.get(disambig, lvl) do
      nil -> "_v#{lvl}"
      name -> name
    end
  end

  defp do_pretty_term({:lam, _mult, body}, names, depth, _disambig) do
    fresh = pick_name(names, depth)
    new_names = names ++ [fresh]
    new_disambig = build_disambiguation(new_names)
    binder_name = Map.get(new_disambig, depth, Atom.to_string(fresh))
    body_str = do_pretty_term(body, new_names, depth + 1, new_disambig)

    "fn(" <> binder_name <> ") do " <> body_str <> " end"
  end

  defp do_pretty_term({:app, f, a}, names, depth, disambig) do
    f_str = do_pretty_term(f, names, depth, disambig)
    a_str = do_pretty_term(a, names, depth, disambig)
    f_str <> "(" <> a_str <> ")"
  end

  defp do_pretty_term({:pi, mult, dom, cod}, names, depth, disambig) do
    if uses_var_zero?(cod) do
      fresh = pick_name(names, depth)
      new_names = names ++ [fresh]
      new_disambig = build_disambiguation(new_names)
      binder_name = Map.get(new_disambig, depth, Atom.to_string(fresh))
      dom_str = do_pretty_term(dom, names, depth, disambig)
      cod_str = do_pretty_term(cod, new_names, depth + 1, new_disambig)

      case mult do
        :zero -> "{" <> binder_name <> " : " <> dom_str <> "} -> " <> cod_str
        :omega -> "(" <> binder_name <> " : " <> dom_str <> ") -> " <> cod_str
      end
    else
      fresh = pick_name(names, depth)
      new_names = names ++ [fresh]
      new_disambig = build_disambiguation(new_names)
      dom_str = do_pretty_term(dom, names, depth, disambig)
      cod_str = do_pretty_term(cod, new_names, depth + 1, new_disambig)

      case mult do
        :zero ->
          binder_name = Map.get(new_disambig, depth, Atom.to_string(fresh))
          "{" <> binder_name <> " : " <> dom_str <> "} -> " <> cod_str

        :omega ->
          dom_str <> " -> " <> cod_str
      end
    end
  end

  defp do_pretty_term({:sigma, a, b}, names, depth, disambig) do
    if uses_var_zero?(b) do
      fresh = pick_name(names, depth)
      new_names = names ++ [fresh]
      new_disambig = build_disambiguation(new_names)
      binder_name = Map.get(new_disambig, depth, Atom.to_string(fresh))
      a_str = do_pretty_term(a, names, depth, disambig)
      b_str = do_pretty_term(b, new_names, depth + 1, new_disambig)
      "(" <> binder_name <> " : " <> a_str <> ", " <> b_str <> ")"
    else
      fresh = pick_name(names, depth)
      new_names = names ++ [fresh]
      new_disambig = build_disambiguation(new_names)
      a_str = do_pretty_term(a, names, depth, disambig)
      b_str = do_pretty_term(b, new_names, depth + 1, new_disambig)
      a_str <> " * " <> b_str
    end
  end

  defp do_pretty_term({:pair, a, b}, names, depth, disambig) do
    "(" <>
      do_pretty_term(a, names, depth, disambig) <>
      ", " <>
      do_pretty_term(b, names, depth, disambig) <> ")"
  end

  defp do_pretty_term({:fst, e}, names, depth, disambig) do
    do_pretty_term(e, names, depth, disambig) <> ".1"
  end

  defp do_pretty_term({:snd, e}, names, depth, disambig) do
    do_pretty_term(e, names, depth, disambig) <> ".2"
  end

  defp do_pretty_term({:let, def_val, body}, names, depth, disambig) do
    fresh = pick_name(names, depth)
    new_names = names ++ [fresh]
    new_disambig = build_disambiguation(new_names)
    binder_name = Map.get(new_disambig, depth, Atom.to_string(fresh))
    val_str = do_pretty_term(def_val, names, depth, disambig)
    body_str = do_pretty_term(body, new_names, depth + 1, new_disambig)
    "let " <> binder_name <> " = " <> val_str <> " in " <> body_str
  end

  defp do_pretty_term({:type, level_val}, _names, _depth, _disambig) do
    pretty_universe(level_val)
  end

  defp do_pretty_term({:lit, value}, _names, _depth, _disambig) do
    pretty_literal(value)
  end

  defp do_pretty_term({:builtin, name}, _names, _depth, _disambig) do
    pretty_builtin_name(name)
  end

  defp do_pretty_term({:extern, mod, fun, arity}, _names, _depth, _disambig) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  defp do_pretty_term({:meta, id}, _names, _depth, _disambig) do
    "?#{id}"
  end

  defp do_pretty_term({:inserted_meta, id, _mask}, _names, _depth, _disambig) do
    "?#{id}"
  end

  defp do_pretty_term({:spanned, _span, inner}, names, depth, disambig) do
    do_pretty_term(inner, names, depth, disambig)
  end

  defp do_pretty_term({:data, name, _args}, _names, _depth, _disambig) do
    "data #{name}"
  end

  defp do_pretty_term({:con, _type_name, con_name, args}, names, depth, disambig) do
    args_str = Enum.map_join(args, ", ", &do_pretty_term(&1, names, depth, disambig))

    if args == [] do
      Atom.to_string(con_name)
    else
      Atom.to_string(con_name) <> "(" <> args_str <> ")"
    end
  end

  defp do_pretty_term({:case, scrutinee, _branches}, names, depth, disambig) do
    scrut_str = do_pretty_term(scrutinee, names, depth, disambig)
    "case " <> scrut_str <> " { ... }"
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Check if a core term body references {:var, 0}.
  @spec uses_var_zero?(Core.expr()) :: boolean()
  defp uses_var_zero?({:var, 0}), do: true
  defp uses_var_zero?({:var, _}), do: false

  defp uses_var_zero?({:lam, _, body}), do: uses_var_zero_shifted?(body, 1)
  defp uses_var_zero?({:app, f, a}), do: uses_var_zero?(f) or uses_var_zero?(a)

  defp uses_var_zero?({:pi, _, dom, cod}),
    do: uses_var_zero?(dom) or uses_var_zero_shifted?(cod, 1)

  defp uses_var_zero?({:sigma, a, b}),
    do: uses_var_zero?(a) or uses_var_zero_shifted?(b, 1)

  defp uses_var_zero?({:pair, a, b}), do: uses_var_zero?(a) or uses_var_zero?(b)
  defp uses_var_zero?({:fst, e}), do: uses_var_zero?(e)
  defp uses_var_zero?({:snd, e}), do: uses_var_zero?(e)
  defp uses_var_zero?({:let, d, body}), do: uses_var_zero?(d) or uses_var_zero_shifted?(body, 1)
  defp uses_var_zero?({:spanned, _, inner}), do: uses_var_zero?(inner)

  defp uses_var_zero?({:case, scrut, branches}) do
    uses_var_zero?(scrut) or
      Enum.any?(branches, fn {_, arity, body} ->
        uses_var_zero_shifted?(body, arity)
      end)
  end

  defp uses_var_zero?({:con, _, _, args}), do: Enum.any?(args, &uses_var_zero?/1)
  defp uses_var_zero?({:data, _, args}), do: Enum.any?(args, &uses_var_zero?/1)
  defp uses_var_zero?(_), do: false

  # Check if a term uses var at a shifted index (under binders).
  defp uses_var_zero_shifted?({:var, ix}, shift), do: ix == shift

  defp uses_var_zero_shifted?({:lam, _, body}, shift),
    do: uses_var_zero_shifted?(body, shift + 1)

  defp uses_var_zero_shifted?({:app, f, a}, shift),
    do: uses_var_zero_shifted?(f, shift) or uses_var_zero_shifted?(a, shift)

  defp uses_var_zero_shifted?({:pi, _, dom, cod}, shift),
    do: uses_var_zero_shifted?(dom, shift) or uses_var_zero_shifted?(cod, shift + 1)

  defp uses_var_zero_shifted?({:sigma, a, b}, shift),
    do: uses_var_zero_shifted?(a, shift) or uses_var_zero_shifted?(b, shift + 1)

  defp uses_var_zero_shifted?({:pair, a, b}, shift),
    do: uses_var_zero_shifted?(a, shift) or uses_var_zero_shifted?(b, shift)

  defp uses_var_zero_shifted?({:fst, e}, shift), do: uses_var_zero_shifted?(e, shift)
  defp uses_var_zero_shifted?({:snd, e}, shift), do: uses_var_zero_shifted?(e, shift)

  defp uses_var_zero_shifted?({:let, d, body}, shift),
    do: uses_var_zero_shifted?(d, shift) or uses_var_zero_shifted?(body, shift + 1)

  defp uses_var_zero_shifted?({:spanned, _, inner}, shift),
    do: uses_var_zero_shifted?(inner, shift)

  defp uses_var_zero_shifted?(_, _shift), do: false

  # Parenthesize arrow types in domain position to disambiguate.
  defp do_pretty_parens_if_arrow({:vpi, _, _, _, _} = val, names, level, disambig) do
    "(" <> do_pretty(val, names, level, disambig) <> ")"
  end

  defp do_pretty_parens_if_arrow(val, names, level, disambig) do
    do_pretty(val, names, level, disambig)
  end

  # Pick a fresh name for a new binder at the given level.
  @name_cycle [:x, :y, :z, :w, :a, :b, :c, :d]
  defp pick_name(_names, level) do
    Enum.at(@name_cycle, rem(level, length(@name_cycle)))
  end

  defp pretty_literal(v) when is_integer(v), do: Integer.to_string(v)
  defp pretty_literal(v) when is_float(v), do: Float.to_string(v)
  defp pretty_literal(v) when is_binary(v), do: inspect(v)
  defp pretty_literal(true), do: "true"
  defp pretty_literal(false), do: "false"
  defp pretty_literal(v) when is_atom(v), do: inspect(v)

  defp pretty_builtin_name(name) when is_atom(name), do: Atom.to_string(name)

  defp pretty_universe({:llit, 0}), do: "Type"
  defp pretty_universe({:llit, n}), do: "Type #{n}"
  defp pretty_universe({:lvar, id}), do: "Type ?l#{id}"
  defp pretty_universe({:lsucc, l}), do: "Type (succ #{pretty_level(l)})"
  defp pretty_universe({:lmax, l1, l2}), do: "Type (max #{pretty_level(l1)} #{pretty_level(l2)})"

  defp pretty_level({:llit, n}), do: Integer.to_string(n)
  defp pretty_level({:lvar, id}), do: "?l#{id}"
  defp pretty_level({:lsucc, l}), do: "(succ #{pretty_level(l)})"
  defp pretty_level({:lmax, l1, l2}), do: "(max #{pretty_level(l1)} #{pretty_level(l2)})"

  # Evaluate a closure body with a value prepended to the captured env.
  defp eval_closure(env, body, arg) do
    Haruspex.Eval.eval(%{env: [arg | env], metas: %{}, defs: %{}, fuel: 1000}, body)
  end
end
