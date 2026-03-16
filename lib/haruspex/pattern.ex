defmodule Haruspex.Pattern do
  @moduledoc """
  Pattern exhaustiveness checking and with-abstraction.

  Checks whether a set of case branches covers all constructors of an ADT.
  Returns warnings (not errors) for missing patterns — hard errors for
  non-exhaustive matches come with `@total` in a later tier.

  Also provides goal type abstraction for `with` expressions: given a
  scrutinee value and a goal type, replaces occurrences of the scrutinee
  in the goal type with a fresh variable, producing a motive function.
  """

  alias Haruspex.Eval
  alias Haruspex.Quote
  alias Haruspex.Unify
  alias Haruspex.Unify.MetaState
  alias Haruspex.Value

  # ============================================================================
  # Public API
  # ============================================================================

  @type exhaustiveness_result :: :ok | {:warning, {:missing_patterns, [atom()]}}

  @doc """
  Check whether case branches exhaustively cover the scrutinee type.

  For ADT types, verifies all constructors are handled (or a wildcard exists).
  For literal patterns without a wildcard, warns about missing coverage.
  For unknown types, returns `:ok` (no checking possible).
  """
  @spec check_exhaustiveness(map(), Value.value(), list()) :: exhaustiveness_result()
  def check_exhaustiveness(adts, scrut_type, branches) do
    check_exhaustiveness(adts, scrut_type, branches, MetaState.new(), 0)
  end

  @doc """
  GADT-aware exhaustiveness checking.

  Filters the constructor set to only those whose return types are compatible
  with the scrutinee type. Impossible constructors (those whose return types
  cannot unify with the scrutinee) are excluded from the required set.
  """
  @spec check_exhaustiveness(map(), Value.value(), list(), MetaState.t(), non_neg_integer()) ::
          exhaustiveness_result()
  def check_exhaustiveness(adts, scrut_type, branches, meta_state, lvl) do
    case scrut_type do
      {:vdata, type_name, _type_args} ->
        check_adt_exhaustiveness(adts, type_name, scrut_type, branches, meta_state, lvl)

      _ ->
        # Non-ADT: warn if literal patterns exist without a wildcard.
        if has_literal_branches?(branches) and not has_wildcard?(branches) do
          {:warning, {:missing_patterns, [:_]}}
        else
          :ok
        end
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp check_adt_exhaustiveness(adts, type_name, scrut_type, branches, meta_state, lvl) do
    case Map.fetch(adts, type_name) do
      {:ok, decl} ->
        if has_wildcard?(branches) do
          :ok
        else
          # Filter to only constructors whose return types are compatible
          # with the scrutinee type (GADT-aware).
          possible_cons =
            decl.constructors
            |> Enum.filter(&constructor_possible?(&1, decl, scrut_type, meta_state, lvl))
            |> MapSet.new(& &1.name)

          covered =
            branches
            |> Enum.reduce(MapSet.new(), fn
              {:__lit, _, _}, acc -> acc
              {:_, _, _}, acc -> acc
              {name, _, _}, acc -> MapSet.put(acc, name)
            end)

          missing = MapSet.difference(possible_cons, covered) |> MapSet.to_list()

          if missing == [] do
            :ok
          else
            {:warning, {:missing_patterns, Enum.sort(missing)}}
          end
        end

      :error ->
        :ok
    end
  end

  defp has_wildcard?(branches) do
    Enum.any?(branches, fn
      {:_, _, _} -> true
      _ -> false
    end)
  end

  defp has_literal_branches?(branches) do
    Enum.any?(branches, fn
      {:__lit, _, _} -> true
      _ -> false
    end)
  end

  # ============================================================================
  # GADT constructor possibility check
  # ============================================================================

  # Check whether a constructor's return type can unify with the scrutinee type.
  # Creates temporary metas for type params, evaluates the return type, and
  # tries unification. If unification fails, the constructor is impossible
  # for this scrutinee and can be excluded from the required set.
  defp constructor_possible?(con, decl, scrut_type, meta_state, lvl) do
    # Create fresh metas for each type parameter, evaluating kinds incrementally.
    {meta_vals, temp_ms} =
      Enum.reduce(decl.params, {[], meta_state}, fn {_name, kind_core}, {acc, ms} ->
        param_env = Enum.reverse(acc)
        eval_ctx = %{env: param_env, metas: solved_metas(ms), defs: %{}, fuel: 1000}
        kind_val = Eval.eval(eval_ctx, kind_core)

        {id, ms} = MetaState.fresh_meta(ms, kind_val, lvl, :gadt)
        meta_val = {:vneutral, kind_val, {:nmeta, id}}

        {acc ++ [meta_val], ms}
      end)

    param_env = Enum.reverse(meta_vals)

    # Compute return type (use default if not a GADT constructor).
    return_type_core = con.return_type || default_con_return_type(decl)

    eval_ctx = %{env: param_env, metas: solved_metas(temp_ms), defs: %{}, fuel: 1000}
    return_type_val = Eval.eval(eval_ctx, return_type_core)

    match?({:ok, _}, Unify.unify(temp_ms, lvl, return_type_val, scrut_type))
  end

  defp default_con_return_type(decl) do
    n_params = length(decl.params)
    args = Enum.map((n_params - 1)..0//-1, fn i -> {:var, i} end)
    {:data, decl.name, args}
  end

  defp solved_metas(ms) do
    ms.entries
    |> Enum.filter(fn {_, entry} -> match?({:solved, _}, entry) end)
    |> Map.new(fn {id, {:solved, val}} -> {id, {:solved, val}} end)
  end

  # ============================================================================
  # With-abstraction: goal type generalization
  # ============================================================================

  @doc """
  Abstract a scrutinee value out of a goal type, producing a motive.

  Walks the goal type, replacing sub-values convertible with `scrutinee_val`
  with `{:var, 0}`. Returns the abstracted core term (ready to be wrapped in
  a lambda as the motive for dependent case splitting).

  If the scrutinee does not appear in the goal type, the abstraction is
  trivial (the motive ignores its argument).
  """
  @spec abstract_over(
          Value.value(),
          Value.value(),
          Unify.MetaState.t(),
          Value.lvl()
        ) :: {:ok, Haruspex.Core.expr()}
  def abstract_over(scrutinee_val, goal_type, meta_state, lvl) do
    goal_core = Quote.quote_untyped(lvl, goal_type)
    scrutinee_core = Quote.quote_untyped(lvl, scrutinee_val)
    {:ok, abstract_core(goal_core, scrutinee_core, meta_state, lvl)}
  end

  @doc false
  @spec abstract_core_term(
          Haruspex.Core.expr(),
          Haruspex.Core.expr(),
          Unify.MetaState.t(),
          Value.lvl()
        ) :: {:ok, Haruspex.Core.expr()}
  def abstract_core_term(goal_core, scrutinee_core, meta_state, lvl) do
    {:ok, abstract_core(goal_core, scrutinee_core, meta_state, lvl)}
  end

  # Walk a core term, replacing occurrences of `target` with {:var, 0}
  # (shifted appropriately under binders).
  defp abstract_core(term, target, ms, lvl) do
    if core_convertible?(term, target, ms, lvl) do
      {:var, 0}
    else
      abstract_subterms(term, target, ms, lvl)
    end
  end

  defp abstract_subterms({:pi, mult, dom, cod}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)
    dom2 = abstract_core(dom, target, ms, lvl)
    cod2 = abstract_core(cod, shifted_target, ms, lvl + 1)
    {:pi, mult, dom2, cod2}
  end

  defp abstract_subterms({:sigma, a, b}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)
    a2 = abstract_core(a, target, ms, lvl)
    b2 = abstract_core(b, shifted_target, ms, lvl + 1)
    {:sigma, a2, b2}
  end

  defp abstract_subterms({:app, f, a}, target, ms, lvl) do
    {:app, abstract_core(f, target, ms, lvl), abstract_core(a, target, ms, lvl)}
  end

  defp abstract_subterms({:lam, mult, body}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)
    {:lam, mult, abstract_core(body, shifted_target, ms, lvl + 1)}
  end

  defp abstract_subterms({:let, def_val, body}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)
    def2 = abstract_core(def_val, target, ms, lvl)
    body2 = abstract_core(body, shifted_target, ms, lvl + 1)
    {:let, def2, body2}
  end

  defp abstract_subterms({:pair, a, b}, target, ms, lvl) do
    {:pair, abstract_core(a, target, ms, lvl), abstract_core(b, target, ms, lvl)}
  end

  defp abstract_subterms({:fst, e}, target, ms, lvl) do
    {:fst, abstract_core(e, target, ms, lvl)}
  end

  defp abstract_subterms({:snd, e}, target, ms, lvl) do
    {:snd, abstract_core(e, target, ms, lvl)}
  end

  defp abstract_subterms({:data, name, args}, target, ms, lvl) do
    {:data, name, Enum.map(args, &abstract_core(&1, target, ms, lvl))}
  end

  defp abstract_subterms({:con, tn, cn, args}, target, ms, lvl) do
    {:con, tn, cn, Enum.map(args, &abstract_core(&1, target, ms, lvl))}
  end

  defp abstract_subterms({:record_proj, field, expr}, target, ms, lvl) do
    {:record_proj, field, abstract_core(expr, target, ms, lvl)}
  end

  defp abstract_subterms({:case, scrut, branches}, target, ms, lvl) do
    scrut2 = abstract_core(scrut, target, ms, lvl)

    branches2 =
      Enum.map(branches, fn
        {:__lit, value, body} ->
          {:__lit, value, abstract_core(body, target, ms, lvl)}

        {tag, arity, body} ->
          shifted =
            Enum.reduce(1..arity//1, target, fn _, t -> Haruspex.Core.shift(t, 1, 0) end)

          {tag, arity, abstract_core(body, shifted, ms, lvl + arity)}
      end)

    {:case, scrut2, branches2}
  end

  # Leaves: var, lit, builtin, type, extern, global, meta, erased, spanned.
  defp abstract_subterms(term, _target, _ms, _lvl), do: term

  # Check if two core terms are syntactically equal (simple structural comparison).
  # For a more precise check, we could evaluate both and use NbE conversion,
  # but syntactic equality is sufficient for the common case where the
  # scrutinee appears literally in the goal type.
  defp core_convertible?(term, target, _ms, _lvl) do
    term == target
  end
end
