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

  alias Haruspex.Quote
  alias Haruspex.Unify
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
    case scrut_type do
      {:vdata, type_name, _type_args} ->
        check_adt_exhaustiveness(adts, type_name, branches)

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

  defp check_adt_exhaustiveness(adts, type_name, branches) do
    case Map.fetch(adts, type_name) do
      {:ok, decl} ->
        if has_wildcard?(branches) do
          :ok
        else
          con_names = MapSet.new(decl.constructors, & &1.name)

          covered =
            branches
            |> Enum.reduce(MapSet.new(), fn
              {:__lit, _, _}, acc -> acc
              {:_, _, _}, acc -> acc
              {name, _, _}, acc -> MapSet.put(acc, name)
            end)

          missing = MapSet.difference(con_names, covered) |> MapSet.to_list()

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
    # Quote the goal type back to core, then walk the core term replacing
    # sub-expressions that match the scrutinee.
    goal_core = Quote.quote_untyped(lvl, goal_type)
    scrutinee_core = Quote.quote_untyped(lvl, scrutinee_val)

    case abstract_core(goal_core, scrutinee_core, meta_state, lvl) do
      {:error, _} = err -> err
      abstracted -> {:ok, abstracted}
    end
  end

  @doc false
  @spec abstract_core_term(
          Haruspex.Core.expr(),
          Haruspex.Core.expr(),
          Unify.MetaState.t(),
          Value.lvl()
        ) :: {:ok, Haruspex.Core.expr()} | {:error, term()}
  def abstract_core_term(goal_core, scrutinee_core, meta_state, lvl) do
    case abstract_core(goal_core, scrutinee_core, meta_state, lvl) do
      {:error, _} = err -> err
      result -> {:ok, result}
    end
  end

  # Wrap abstract_core to return {:ok, result} | {:error, reason} for use in with chains.
  defp wrap_abstract(term, target, ms, lvl) do
    case abstract_core(term, target, ms, lvl) do
      {:error, _} = err -> err
      result -> {:ok, result}
    end
  end

  # Walk a core term, replacing occurrences of `target` with {:var, 0}
  # (shifted appropriately under binders).
  defp abstract_core(term, target, ms, lvl) do
    # First check if the whole term is convertible with the target.
    if core_convertible?(term, target, ms, lvl) do
      {:var, 0}
    else
      abstract_subterms(term, target, ms, lvl)
    end
  end

  defp abstract_subterms({:pi, mult, dom, cod}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)

    with {:ok, dom2} <- wrap_abstract(dom, target, ms, lvl),
         :ok <- check_binder_capture(shifted_target, target),
         {:ok, cod2} <- wrap_abstract(cod, shifted_target, ms, lvl + 1) do
      {:pi, mult, dom2, cod2}
    end
  end

  defp abstract_subterms({:sigma, a, b}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)

    with {:ok, a2} <- wrap_abstract(a, target, ms, lvl),
         :ok <- check_binder_capture(shifted_target, target),
         {:ok, b2} <- wrap_abstract(b, shifted_target, ms, lvl + 1) do
      {:sigma, a2, b2}
    end
  end

  defp abstract_subterms({:app, f, a}, target, ms, lvl) do
    with {:ok, f2} <- wrap_abstract(f, target, ms, lvl),
         {:ok, a2} <- wrap_abstract(a, target, ms, lvl) do
      {:app, f2, a2}
    end
  end

  defp abstract_subterms({:lam, mult, body}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)

    with :ok <- check_binder_capture(shifted_target, target),
         {:ok, body2} <- wrap_abstract(body, shifted_target, ms, lvl + 1) do
      {:lam, mult, body2}
    end
  end

  defp abstract_subterms({:let, def_val, body}, target, ms, lvl) do
    shifted_target = Haruspex.Core.shift(target, 1, 0)

    with {:ok, def2} <- wrap_abstract(def_val, target, ms, lvl),
         :ok <- check_binder_capture(shifted_target, target),
         {:ok, body2} <- wrap_abstract(body, shifted_target, ms, lvl + 1) do
      {:let, def2, body2}
    end
  end

  defp abstract_subterms({:pair, a, b}, target, ms, lvl) do
    with {:ok, a2} <- wrap_abstract(a, target, ms, lvl),
         {:ok, b2} <- wrap_abstract(b, target, ms, lvl) do
      {:pair, a2, b2}
    end
  end

  defp abstract_subterms({:fst, e}, target, ms, lvl) do
    with {:ok, e2} <- wrap_abstract(e, target, ms, lvl), do: {:fst, e2}
  end

  defp abstract_subterms({:snd, e}, target, ms, lvl) do
    with {:ok, e2} <- wrap_abstract(e, target, ms, lvl), do: {:snd, e2}
  end

  defp abstract_subterms({:data, name, args}, target, ms, lvl) do
    case abstract_list(args, target, ms, lvl) do
      {:error, _} = err -> err
      args2 -> {:data, name, args2}
    end
  end

  defp abstract_subterms({:con, tn, cn, args}, target, ms, lvl) do
    case abstract_list(args, target, ms, lvl) do
      {:error, _} = err -> err
      args2 -> {:con, tn, cn, args2}
    end
  end

  defp abstract_subterms({:record_proj, field, expr}, target, ms, lvl) do
    with {:ok, e2} <- wrap_abstract(expr, target, ms, lvl), do: {:record_proj, field, e2}
  end

  defp abstract_subterms({:case, scrut, branches}, target, ms, lvl) do
    with {:ok, scrut2} <- wrap_abstract(scrut, target, ms, lvl) do
      case abstract_branches(branches, target, ms, lvl) do
        {:error, _} = err -> err
        branches2 -> {:case, scrut2, branches2}
      end
    end
  end

  # Leaves: var, lit, builtin, type, extern, global, meta, erased, spanned.
  defp abstract_subterms(term, _target, _ms, _lvl), do: term

  defp abstract_list(terms, target, ms, lvl) do
    Enum.reduce_while(terms, [], fn term, acc ->
      case abstract_core(term, target, ms, lvl) do
        {:error, _} = err -> {:halt, err}
        result -> {:cont, [result | acc]}
      end
    end)
    |> case do
      {:error, _} = err -> err
      results -> Enum.reverse(results)
    end
  end

  defp abstract_branches(branches, target, ms, lvl) do
    Enum.reduce_while(branches, [], fn branch, acc ->
      case abstract_branch(branch, target, ms, lvl) do
        {:error, _} = err -> {:halt, err}
        result -> {:cont, [result | acc]}
      end
    end)
    |> case do
      {:error, _} = err -> err
      results -> Enum.reverse(results)
    end
  end

  defp abstract_branch({:__lit, value, body}, target, ms, lvl) do
    case abstract_core(body, target, ms, lvl) do
      {:error, _} = err -> err
      body2 -> {:__lit, value, body2}
    end
  end

  defp abstract_branch({tag, arity, body}, target, ms, lvl) do
    shifted = Enum.reduce(1..arity//1, target, fn _, t -> Haruspex.Core.shift(t, 1, 0) end)

    case abstract_core(body, shifted, ms, lvl + arity) do
      {:error, _} = err -> err
      body2 -> {tag, arity, body2}
    end
  end

  # Check whether the scrutinee depends on a variable that is being bound.
  # After shifting, if the shifted target contains {:var, 0}, the scrutinee
  # references the bound variable — abstraction fails.
  defp check_binder_capture(shifted_target, original_target) do
    if mentions_var_zero?(shifted_target) and not mentions_var_zero?(original_target) do
      {:error, {:abstraction_failure, :scrutinee_captures_bound_variable}}
    else
      :ok
    end
  end

  defp mentions_var_zero?({:var, 0}), do: true
  defp mentions_var_zero?({:var, _}), do: false
  defp mentions_var_zero?({:lit, _}), do: false
  defp mentions_var_zero?({:builtin, _}), do: false
  defp mentions_var_zero?({:type, _}), do: false
  defp mentions_var_zero?({:meta, _}), do: false
  defp mentions_var_zero?({:erased}), do: false

  defp mentions_var_zero?({:pi, _, dom, cod}),
    do: mentions_var_zero?(dom) or mentions_var_zero?(cod)

  defp mentions_var_zero?({:sigma, a, b}), do: mentions_var_zero?(a) or mentions_var_zero?(b)
  defp mentions_var_zero?({:app, f, a}), do: mentions_var_zero?(f) or mentions_var_zero?(a)
  defp mentions_var_zero?({:lam, _, body}), do: mentions_var_zero?(body)
  defp mentions_var_zero?({:let, d, b}), do: mentions_var_zero?(d) or mentions_var_zero?(b)
  defp mentions_var_zero?({:pair, a, b}), do: mentions_var_zero?(a) or mentions_var_zero?(b)
  defp mentions_var_zero?({:fst, e}), do: mentions_var_zero?(e)
  defp mentions_var_zero?({:snd, e}), do: mentions_var_zero?(e)

  defp mentions_var_zero?({:data, _, args}), do: Enum.any?(args, &mentions_var_zero?/1)
  defp mentions_var_zero?({:con, _, _, args}), do: Enum.any?(args, &mentions_var_zero?/1)
  defp mentions_var_zero?({:record_proj, _, e}), do: mentions_var_zero?(e)

  defp mentions_var_zero?({:case, scrut, branches}) do
    mentions_var_zero?(scrut) or
      Enum.any?(branches, fn
        {:__lit, _, body} -> mentions_var_zero?(body)
        {_, _, body} -> mentions_var_zero?(body)
      end)
  end

  defp mentions_var_zero?(_), do: false

  # Check if two core terms are syntactically equal (simple structural comparison).
  # For a more precise check, we could evaluate both and use NbE conversion,
  # but syntactic equality is sufficient for the common case where the
  # scrutinee appears literally in the goal type.
  defp core_convertible?(term, target, _ms, _lvl) do
    term == target
  end
end
