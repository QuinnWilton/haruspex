defmodule Haruspex.Totality do
  @moduledoc """
  Structural recursion checker for `@total` functions.

  Verifies that at least one parameter decreases structurally in every
  recursive call. A variable is a structural subterm of parameter `p` if
  it was bound by a constructor pattern in a `case` that scrutinizes `p`.

  The checker operates on checked core terms (post type checking) and
  the function's Pi type. It does not use the value domain — it works
  purely on `Core.expr()` syntax with de Bruijn indices.
  """

  alias Haruspex.Core

  # Dialyzer struggles with MapSet as an opaque type in private functions.
  @dialyzer {:no_opaque, do_check: 6}
  @dialyzer {:no_opaque, check_branches: 6}
  @dialyzer {:no_opaque, check_case_branches: 5}
  @dialyzer {:no_opaque, check_arg_is_subterm: 2}
  @dialyzer {:no_opaque, shift_subterms: 2}

  # ============================================================================
  # Types
  # ============================================================================

  @type totality_error ::
          {:no_decreasing_arg, atom(), Pentiment.Span.Byte.t() | nil}
          | {:non_structural_recursion, atom(), non_neg_integer(), Core.expr()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check that a function is structurally recursive.

  Returns `:total` if at least one parameter decreases structurally in every
  recursive call, or `{:not_total, reason}` otherwise. Functions with no
  recursive calls are trivially total.
  """
  @spec check_totality(atom(), Core.expr(), Core.expr(), %{atom() => map()}) ::
          :total | {:not_total, totality_error()}
  def check_totality(name, type, body, adts) do
    # Extract parameter info from the Pi type.
    params = extract_params(type, 0)

    # Strip lambdas from body to get the raw inner term.
    {inner, num_params} = strip_lambdas(body)

    # The self-reference is at de Bruijn index num_params under the stripped body
    # (check_definition binds the name before the lambdas).
    self_ix = num_params

    # Find all recursive calls in the body.
    rec_calls = find_recursive_calls(inner, self_ix, 0)

    cond do
      rec_calls == [] ->
        # No recursion — trivially total.
        :total

      true ->
        # Find candidate decreasing parameters: runtime params with ADT types.
        candidates =
          params
          |> Enum.filter(fn {_pos, mult, dom} ->
            mult == :omega and adt_type?(dom, adts)
          end)
          |> Enum.map(fn {pos, _, _} -> pos end)

        if candidates == [] do
          {:not_total, {:no_decreasing_arg, name, nil}}
        else
          try_candidates(candidates, inner, self_ix, num_params, rec_calls, name)
        end
    end
  end

  # ============================================================================
  # Parameter extraction
  # ============================================================================

  defp extract_params({:pi, mult, dom, cod}, pos) do
    [{pos, mult, dom} | extract_params(cod, pos + 1)]
  end

  defp extract_params(_, _pos), do: []

  defp strip_lambdas({:lam, _mult, body}) do
    {inner, count} = strip_lambdas(body)
    {inner, count + 1}
  end

  defp strip_lambdas(body), do: {body, 0}

  defp adt_type?({:data, name, _args}, adts), do: Map.has_key?(adts, name)
  defp adt_type?(_, _), do: false

  # ============================================================================
  # Candidate checking
  # ============================================================================

  # Try each candidate parameter. If any works for ALL recursive calls, total.
  defp try_candidates([], _inner, _self_ix, _num_params, _rec_calls, name) do
    {:not_total, {:no_decreasing_arg, name, nil}}
  end

  defp try_candidates([candidate | rest], inner, self_ix, num_params, rec_calls, name) do
    # The candidate parameter's de Bruijn index under the stripped body.
    param_ix = num_params - 1 - candidate

    case check_candidate(inner, self_ix, param_ix, candidate, 0) do
      :ok -> :total
      {:error, _} -> try_candidates(rest, inner, self_ix, num_params, rec_calls, name)
    end
  end

  # Check that all recursive calls in `term` decrease on the candidate parameter.
  # `depth` tracks additional binders introduced by case branches and lets.
  # `subterms` is the set of de Bruijn indices known to be structural subterms
  # of the candidate parameter at the current depth.
  defp check_candidate(term, self_ix, param_ix, param_pos, depth) do
    do_check(term, self_ix, param_ix, param_pos, depth, MapSet.new())
  end

  # Walk the term. `subterms` tracks which de Bruijn indices are known structural
  # subterms of the candidate parameter at the current binder depth.
  defp do_check(term, self_ix, param_ix, param_pos, depth, subterms) do
    case term do
      {:app, _, _} ->
        case collect_self_call(term, self_ix + depth) do
          {:self_call, args} ->
            # Check that the argument at the candidate position is a subterm.
            arg = Enum.at(args, param_pos)
            check_arg_is_subterm(arg, subterms)

          :not_self_call ->
            # Not a self-call — check sub-expressions.
            check_app_parts(term, self_ix, param_ix, param_pos, depth, subterms)
        end

      {:case, {:var, scrutinee_ix}, branches} when scrutinee_ix == param_ix + depth ->
        # Case on the candidate parameter — branches bind subterms.
        check_case_branches(branches, self_ix, param_ix, param_pos, depth)

      {:case, {:var, scrutinee_ix} = scrutinee, branches} ->
        # If the scrutinee is a known subterm, branch variables are also subterms.
        if MapSet.member?(subterms, scrutinee_ix) do
          check_case_branches_with_existing(
            branches,
            self_ix,
            param_ix,
            param_pos,
            depth,
            subterms
          )
        else
          with :ok <- do_check(scrutinee, self_ix, param_ix, param_pos, depth, subterms) do
            check_branches(branches, self_ix, param_ix, param_pos, depth, subterms)
          end
        end

      {:case, scrutinee, branches} ->
        # Case on something else — check scrutinee and branches.
        with :ok <- do_check(scrutinee, self_ix, param_ix, param_pos, depth, subterms) do
          check_branches(branches, self_ix, param_ix, param_pos, depth, subterms)
        end

      {:lam, _mult, body} ->
        do_check(body, self_ix, param_ix, param_pos, depth + 1, shift_subterms(subterms, 1))

      {:let, def_val, body} ->
        with :ok <- do_check(def_val, self_ix, param_ix, param_pos, depth, subterms) do
          do_check(body, self_ix, param_ix, param_pos, depth + 1, shift_subterms(subterms, 1))
        end

      {:con, _type, _con, args} ->
        check_list(args, self_ix, param_ix, param_pos, depth, subterms)

      {:pair, a, b} ->
        with :ok <- do_check(a, self_ix, param_ix, param_pos, depth, subterms) do
          do_check(b, self_ix, param_ix, param_pos, depth, subterms)
        end

      {:fst, e} ->
        do_check(e, self_ix, param_ix, param_pos, depth, subterms)

      {:snd, e} ->
        do_check(e, self_ix, param_ix, param_pos, depth, subterms)

      {:record_proj, _field, e} ->
        do_check(e, self_ix, param_ix, param_pos, depth, subterms)

      # Leaf terms — no recursive calls possible.
      {:var, _} ->
        :ok

      {:lit, _} ->
        :ok

      {:builtin, _} ->
        :ok

      {:extern, _, _, _} ->
        :ok

      {:global, _, _, _} ->
        :ok

      {:self_ref, _} ->
        :ok

      {:data, _, _} ->
        :ok

      {:type, _} ->
        :ok

      {:meta, _} ->
        :ok

      :erased ->
        :ok

      _ ->
        :ok
    end
  end

  # Check all branches of a case that is NOT on the candidate parameter.
  defp check_branches(branches, self_ix, param_ix, param_pos, depth, subterms) do
    Enum.reduce_while(branches, :ok, fn
      {:__lit, _value, body}, :ok ->
        case do_check(body, self_ix, param_ix, param_pos, depth, subterms) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      {:_, arity, body}, :ok ->
        shifted = shift_subterms(subterms, arity)

        case do_check(body, self_ix, param_ix, param_pos, depth + arity, shifted) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      {_con, arity, body}, :ok ->
        shifted = shift_subterms(subterms, arity)

        case do_check(body, self_ix, param_ix, param_pos, depth + arity, shifted) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
    end)
  end

  # Check branches of a case on the candidate parameter.
  # Pattern variables (indices 0..arity-1) are structural subterms.
  defp check_case_branches(branches, self_ix, param_ix, param_pos, depth) do
    Enum.reduce_while(branches, :ok, fn
      {:__lit, _value, body}, :ok ->
        # Literal branch — no subterms introduced.
        case do_check(body, self_ix, param_ix, param_pos, depth, MapSet.new()) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      {:_, 0, body}, :ok ->
        case do_check(body, self_ix, param_ix, param_pos, depth, MapSet.new()) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      {:_, arity, body}, :ok ->
        subterms = MapSet.new(0..(arity - 1))

        case do_check(body, self_ix, param_ix, param_pos, depth + arity, subterms) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      {_con, arity, body}, :ok ->
        # Constructor branch: variables 0..arity-1 are subterms.
        subterms = if arity > 0, do: MapSet.new(0..(arity - 1)), else: MapSet.new()

        case do_check(body, self_ix, param_ix, param_pos, depth + arity, subterms) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
    end)
  end

  # Check branches of a case on a known subterm — transitive subterm tracking.
  # Both the existing subterms AND new pattern variables are subterms.
  defp check_case_branches_with_existing(branches, self_ix, param_ix, param_pos, depth, existing) do
    Enum.reduce_while(branches, :ok, fn
      {:__lit, _value, body}, :ok ->
        shifted = shift_subterms(existing, 0)

        case do_check(body, self_ix, param_ix, param_pos, depth, shifted) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      {_con_or_wildcard, arity, body}, :ok ->
        # Shift existing subterms up by arity, then add new pattern vars 0..arity-1.
        shifted = shift_subterms(existing, arity)

        new_subterms =
          if arity > 0 do
            Enum.reduce(0..(arity - 1), shifted, &MapSet.put(&2, &1))
          else
            shifted
          end

        case do_check(body, self_ix, param_ix, param_pos, depth + arity, new_subterms) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
    end)
  end

  # ============================================================================
  # Recursive call detection
  # ============================================================================

  # Collect a curried self-call: App(App(Var(self_ix), a1), a2) → [a1, a2].
  defp collect_self_call(term, target_ix) do
    case collect_app_chain(term) do
      {{:var, ix}, args} when ix == target_ix -> {:self_call, args}
      _ -> :not_self_call
    end
  end

  # Unfurl a curried application into {head, [args]}.
  defp collect_app_chain({:app, f, a}) do
    {head, args} = collect_app_chain(f)
    {head, args ++ [a]}
  end

  defp collect_app_chain(term), do: {term, []}

  # Find all recursive calls in a term (for the top-level check).
  defp find_recursive_calls(term, self_ix, depth) do
    case term do
      {:app, _, _} ->
        case collect_self_call(term, self_ix + depth) do
          {:self_call, args} ->
            [{args, depth}]

          :not_self_call ->
            find_in_app_parts(term, self_ix, depth)
        end

      {:case, scrutinee, branches} ->
        find_recursive_calls(scrutinee, self_ix, depth) ++
          Enum.flat_map(branches, fn
            {:__lit, _, body} -> find_recursive_calls(body, self_ix, depth)
            {_, arity, body} -> find_recursive_calls(body, self_ix, depth + arity)
          end)

      {:lam, _, body} ->
        find_recursive_calls(body, self_ix, depth + 1)

      {:let, d, b} ->
        find_recursive_calls(d, self_ix, depth) ++
          find_recursive_calls(b, self_ix, depth + 1)

      {:con, _, _, args} ->
        Enum.flat_map(args, &find_recursive_calls(&1, self_ix, depth))

      {:pair, a, b} ->
        find_recursive_calls(a, self_ix, depth) ++
          find_recursive_calls(b, self_ix, depth)

      {:fst, e} ->
        find_recursive_calls(e, self_ix, depth)

      {:snd, e} ->
        find_recursive_calls(e, self_ix, depth)

      _ ->
        []
    end
  end

  defp find_in_app_parts({:app, f, a}, self_ix, depth) do
    find_recursive_calls(f, self_ix, depth) ++
      find_recursive_calls(a, self_ix, depth)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp check_arg_is_subterm({:var, ix}, subterms) do
    if MapSet.member?(subterms, ix) do
      :ok
    else
      {:error, {:not_subterm, {:var, ix}}}
    end
  end

  defp check_arg_is_subterm(term, _subterms) do
    {:error, {:not_subterm, term}}
  end

  defp check_app_parts({:app, f, a}, self_ix, param_ix, param_pos, depth, subterms) do
    with :ok <- do_check(f, self_ix, param_ix, param_pos, depth, subterms) do
      do_check(a, self_ix, param_ix, param_pos, depth, subterms)
    end
  end

  defp check_list([], _self_ix, _param_ix, _param_pos, _depth, _subterms), do: :ok

  defp check_list([h | t], self_ix, param_ix, param_pos, depth, subterms) do
    with :ok <- do_check(h, self_ix, param_ix, param_pos, depth, subterms) do
      check_list(t, self_ix, param_ix, param_pos, depth, subterms)
    end
  end

  # Shift all subterm indices up by `n` (to account for new binders).
  defp shift_subterms(subterms, n) do
    MapSet.new(subterms, fn ix -> ix + n end)
  end
end
