defmodule Haruspex.Unify do
  @moduledoc """
  Higher-order pattern unification for metavariable solving.

  Unifies two values in the value domain, threading a `MetaState` through
  all operations. Handles flex-flex, flex-rigid (pattern unification),
  rigid-rigid (structural), and eta-expansion cases.
  """

  alias Haruspex.Core
  alias Haruspex.Eval
  alias Haruspex.Quote
  alias Haruspex.Value
  alias Haruspex.Unify.MetaState

  # ============================================================================
  # Types
  # ============================================================================

  @type unify_error ::
          {:mismatch, Value.value(), Value.value()}
          | {:occurs_check, Core.meta_id(), Value.value()}
          | {:scope_escape, Core.meta_id(), Value.value()}
          | {:not_pattern, Core.meta_id(), [Value.value()]}
          | {:multiplicity_mismatch, Core.mult(), Core.mult()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Unify two values at the given de Bruijn level.

  Returns `{:ok, updated_meta_state}` on success or `{:error, reason}` on failure.
  Level constraints from universe unification are accumulated in the meta state.
  """
  @spec unify(MetaState.t(), non_neg_integer(), Value.value(), Value.value()) ::
          {:ok, MetaState.t()} | {:error, unify_error()}
  def unify(ms, lvl, lhs, rhs) do
    whnf_ctx = %{Eval.default_ctx() | metas: ms.entries}
    lhs = Eval.whnf(whnf_ctx, lhs)
    rhs = Eval.whnf(whnf_ctx, rhs)

    cond do
      # Same pointer / structurally identical.
      lhs == rhs ->
        {:ok, ms}

      # Flex-flex: both sides are unsolved metas.
      flex?(lhs) and flex?(rhs) ->
        unify_flex_flex(ms, lvl, lhs, rhs)

      # Flex-rigid: left side is meta.
      flex?(lhs) ->
        solve_flex_rigid(ms, lvl, lhs, rhs)

      # Flex-rigid: right side is meta.
      flex?(rhs) ->
        solve_flex_rigid(ms, lvl, rhs, lhs)

      # Rigid-rigid: same head constructor.
      true ->
        unify_rigid(ms, lvl, lhs, rhs)
    end
  end

  # ============================================================================
  # Flex detection
  # ============================================================================

  defp flex?({:vneutral, _type, ne}), do: meta_head?(ne)
  defp flex?(_), do: false

  defp meta_head?({:nmeta, _}), do: true
  defp meta_head?({:napp, ne, _}), do: meta_head?(ne)
  defp meta_head?(_), do: false

  # ============================================================================
  # Flex-flex unification
  # ============================================================================

  defp unify_flex_flex(ms, _lvl, {:vneutral, _t1, {:nmeta, id1}}, {:vneutral, _t2, {:nmeta, id2}}) do
    # Both are bare metas (no spine). Solve one to the other.
    if id1 == id2 do
      {:ok, ms}
    else
      # Solve the higher-numbered meta to the lower-numbered one.
      {solve_id, target} =
        if id1 > id2 do
          {id1, {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id2}}}
        else
          {id2, {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id1}}}
        end

      MetaState.solve(ms, solve_id, target)
    end
  end

  defp unify_flex_flex(ms, lvl, lhs, rhs) do
    # One or both have spines. Try pattern unification on the left first.
    case solve_flex_rigid(ms, lvl, lhs, rhs) do
      {:ok, _} = ok -> ok
      {:error, _} -> solve_flex_rigid(ms, lvl, rhs, lhs)
    end
  end

  # ============================================================================
  # Flex-rigid (pattern unification)
  # ============================================================================

  defp solve_flex_rigid(ms, lvl, flex, rigid) do
    {meta_id, spine} = extract_spine(flex)

    if spine == [] do
      # Bare meta (no spine): solve directly to the rigid value.
      # The scope check uses the meta's creation level — the solution may
      # only reference variables at levels below that.
      {:unsolved, _, ctx_level, _} = MetaState.lookup(ms, meta_id)
      allowed = Enum.to_list(0..(ctx_level - 1)//1)

      with :ok <- occurs_check(ms, meta_id, rigid),
           :ok <- scope_check(meta_id, rigid, allowed) do
        MetaState.solve(ms, meta_id, rigid)
      end
    else
      with :ok <- check_pattern(meta_id, spine),
           spine_levels = Enum.map(spine, fn {:vneutral, _, {:nvar, l}} -> l end),
           :ok <- occurs_check(ms, meta_id, rigid),
           :ok <- scope_check(meta_id, rigid, spine_levels) do
        solution = abstract(lvl, spine_levels, rigid)
        # Evaluate the abstracted core term to get a value, passing the
        # meta entries so that meta type annotations are preserved correctly.
        eval_ctx = %{Eval.default_ctx() | metas: ms.entries}
        solution_val = Eval.eval(eval_ctx, solution)
        MetaState.solve(ms, meta_id, solution_val)
      end
    end
  end

  # Extract the meta ID and spine (list of arguments) from a flex value.
  defp extract_spine({:vneutral, _type, ne}) do
    do_extract_spine(ne, [])
  end

  defp do_extract_spine({:nmeta, id}, acc), do: {id, acc}
  defp do_extract_spine({:napp, ne, arg}, acc), do: do_extract_spine(ne, [arg | acc])

  # Verify the spine consists of distinct bound variables.
  defp check_pattern(meta_id, spine) do
    levels =
      Enum.map(spine, fn
        {:vneutral, _, {:nvar, l}} -> {:ok, l}
        _ -> :not_var
      end)

    if Enum.any?(levels, &(&1 == :not_var)) do
      {:error, {:not_pattern, meta_id, spine}}
    else
      extracted = Enum.map(levels, fn {:ok, l} -> l end)

      if length(extracted) == length(Enum.uniq(extracted)) do
        :ok
      else
        {:error, {:not_pattern, meta_id, spine}}
      end
    end
  end

  # Check that the meta does not occur in the value.
  defp occurs_check(ms, meta_id, value) do
    if occurs_in?(ms, meta_id, value) do
      {:error, {:occurs_check, meta_id, value}}
    else
      :ok
    end
  end

  defp occurs_in?(ms, meta_id, value) do
    value = Eval.whnf(%{Eval.default_ctx() | metas: ms.entries}, value)

    case value do
      {:vneutral, type, ne} ->
        occurs_in?(ms, meta_id, type) or occurs_in_neutral?(ms, meta_id, ne)

      {:vpi, _mult, dom, env, cod} ->
        occurs_in?(ms, meta_id, dom) or occurs_in_closure?(ms, meta_id, env, cod)

      {:vlam, _mult, env, body} ->
        occurs_in_closure?(ms, meta_id, env, body)

      {:vsigma, a, env, b} ->
        occurs_in?(ms, meta_id, a) or occurs_in_closure?(ms, meta_id, env, b)

      {:vpair, a, b} ->
        occurs_in?(ms, meta_id, a) or occurs_in?(ms, meta_id, b)

      {:vtype, _} ->
        false

      {:vlit, _} ->
        false

      {:vbuiltin, _} ->
        false

      {:vextern, _, _, _} ->
        false

      {:vdata, _, args} ->
        Enum.any?(args, &occurs_in?(ms, meta_id, &1))

      {:vcon, _, _, args} ->
        Enum.any?(args, &occurs_in?(ms, meta_id, &1))
    end
  end

  defp occurs_in_neutral?(ms, meta_id, ne) do
    case ne do
      {:nmeta, id} -> id == meta_id
      {:nvar, _} -> false
      {:napp, head, arg} -> occurs_in_neutral?(ms, meta_id, head) or occurs_in?(ms, meta_id, arg)
      {:nfst, head} -> occurs_in_neutral?(ms, meta_id, head)
      {:nsnd, head} -> occurs_in_neutral?(ms, meta_id, head)
      {:ndef, _, args} -> Enum.any?(args, &occurs_in?(ms, meta_id, &1))
      {:nbuiltin, _} -> false
      {:ndef_ref, _} -> false
      {:ncase, head, _branches, _env} -> occurs_in_neutral?(ms, meta_id, head)
    end
  end

  # Check if a meta occurs in a closure. Evaluate the body with a fresh variable
  # to inspect it.
  defp occurs_in_closure?(ms, meta_id, env, body) do
    lvl = length(env)
    fresh = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
    body_val = Eval.eval(%{Eval.default_ctx() | env: [fresh | env]}, body)
    occurs_in?(ms, meta_id, body_val)
  end

  # Check all free variables (NVar levels) in the rhs are in the spine's level list.
  defp scope_check(meta_id, value, spine_levels) do
    if scope_ok?(value, spine_levels) do
      :ok
    else
      {:error, {:scope_escape, meta_id, value}}
    end
  end

  defp scope_ok?(value, allowed_levels) do
    case value do
      {:vneutral, _type, ne} ->
        scope_ok_neutral?(ne, allowed_levels)

      {:vpi, _mult, dom, env, cod} ->
        scope_ok?(dom, allowed_levels) and scope_ok_closure?(env, cod, allowed_levels)

      {:vlam, _mult, env, body} ->
        scope_ok_closure?(env, body, allowed_levels)

      {:vsigma, a, env, b} ->
        scope_ok?(a, allowed_levels) and scope_ok_closure?(env, b, allowed_levels)

      {:vpair, a, b} ->
        scope_ok?(a, allowed_levels) and scope_ok?(b, allowed_levels)

      {:vtype, _} ->
        true

      {:vlit, _} ->
        true

      {:vbuiltin, _} ->
        true

      {:vextern, _, _, _} ->
        true

      {:vdata, _, args} ->
        Enum.all?(args, &scope_ok?(&1, allowed_levels))

      {:vcon, _, _, args} ->
        Enum.all?(args, &scope_ok?(&1, allowed_levels))
    end
  end

  defp scope_ok_neutral?(ne, allowed_levels) do
    case ne do
      {:nvar, lvl} ->
        lvl in allowed_levels

      {:nmeta, _} ->
        true

      {:napp, head, arg} ->
        scope_ok_neutral?(head, allowed_levels) and scope_ok?(arg, allowed_levels)

      {:nfst, head} ->
        scope_ok_neutral?(head, allowed_levels)

      {:nsnd, head} ->
        scope_ok_neutral?(head, allowed_levels)

      {:ndef, _, args} ->
        Enum.all?(args, &scope_ok?(&1, allowed_levels))

      {:nbuiltin, _} ->
        true

      {:ndef_ref, _} ->
        true

      {:ncase, head, _branches, _env} ->
        scope_ok_neutral?(head, allowed_levels)
    end
  end

  defp scope_ok_closure?(env, body, allowed_levels) do
    lvl = length(env)
    fresh = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
    body_val = Eval.eval(%{Eval.default_ctx() | env: [fresh | env]}, body)
    # The fresh variable at `lvl` is a new binder, so it's always in scope.
    scope_ok?(body_val, [lvl | allowed_levels])
  end

  # ============================================================================
  # Abstraction
  # ============================================================================

  # Quote the rhs, then rename variables corresponding to spine levels into
  # the new lambda-bound indices, and wrap in lambdas.
  defp abstract(lvl, spine_levels, rhs) do
    # Quote the rhs at the current level to get a core term.
    quoted = Quote.quote_untyped(lvl, rhs)

    # Build a mapping: for each spine variable at position i (0-indexed from left),
    # the spine level `l` should become de Bruijn index `(n - 1 - i)` in the
    # lambda-wrapped term, where n is the number of spine variables.
    n = length(spine_levels)

    # In the quoted term, spine level `l` is represented as de Bruijn index `lvl - l - 1`.
    # We need to rename it to `n - 1 - i`.
    rename_map =
      spine_levels
      |> Enum.with_index()
      |> Map.new(fn {l, i} -> {lvl - l - 1, n - 1 - i} end)

    renamed = rename_vars(quoted, rename_map, 0)

    # Wrap in n lambdas.
    Enum.reduce(1..n//1, renamed, fn _, body -> {:lam, :omega, body} end)
  end

  # Rename free variables in a core term according to the map.
  # `depth` tracks how many binders we've gone under (to adjust indices).
  defp rename_vars({:var, ix}, rename_map, depth) do
    if ix >= depth do
      # This is a free variable. Check if it's in the rename map.
      original_ix = ix - depth

      case Map.get(rename_map, original_ix) do
        nil -> {:var, ix}
        new_ix -> {:var, new_ix + depth}
      end
    else
      {:var, ix}
    end
  end

  defp rename_vars({:lam, mult, body}, rename_map, depth) do
    {:lam, mult, rename_vars(body, rename_map, depth + 1)}
  end

  defp rename_vars({:app, f, a}, rename_map, depth) do
    {:app, rename_vars(f, rename_map, depth), rename_vars(a, rename_map, depth)}
  end

  defp rename_vars({:pi, mult, dom, cod}, rename_map, depth) do
    {:pi, mult, rename_vars(dom, rename_map, depth), rename_vars(cod, rename_map, depth + 1)}
  end

  defp rename_vars({:sigma, a, b}, rename_map, depth) do
    {:sigma, rename_vars(a, rename_map, depth), rename_vars(b, rename_map, depth + 1)}
  end

  defp rename_vars({:pair, a, b}, rename_map, depth) do
    {:pair, rename_vars(a, rename_map, depth), rename_vars(b, rename_map, depth)}
  end

  defp rename_vars({:fst, e}, rename_map, depth) do
    {:fst, rename_vars(e, rename_map, depth)}
  end

  defp rename_vars({:snd, e}, rename_map, depth) do
    {:snd, rename_vars(e, rename_map, depth)}
  end

  defp rename_vars({:let, def_val, body}, rename_map, depth) do
    {:let, rename_vars(def_val, rename_map, depth), rename_vars(body, rename_map, depth + 1)}
  end

  defp rename_vars({:spanned, span, inner}, rename_map, depth) do
    {:spanned, span, rename_vars(inner, rename_map, depth)}
  end

  defp rename_vars({:data, name, args}, rename_map, depth) do
    {:data, name, Enum.map(args, &rename_vars(&1, rename_map, depth))}
  end

  defp rename_vars({:con, type_name, con_name, args}, rename_map, depth) do
    {:con, type_name, con_name, Enum.map(args, &rename_vars(&1, rename_map, depth))}
  end

  defp rename_vars({:record_proj, field, expr}, rename_map, depth) do
    {:record_proj, field, rename_vars(expr, rename_map, depth)}
  end

  defp rename_vars({:def_ref, name}, _rename_map, _depth), do: {:def_ref, name}

  defp rename_vars({:case, scrutinee, branches}, rename_map, depth) do
    {:case, rename_vars(scrutinee, rename_map, depth),
     Enum.map(branches, fn
       {:__lit, value, body} ->
         {:__lit, value, rename_vars(body, rename_map, depth)}

       {con_name, arity, body} ->
         {con_name, arity, rename_vars(body, rename_map, depth + arity)}
     end)}
  end

  defp rename_vars(term, _rename_map, _depth)
       when elem(term, 0) in [:type, :lit, :builtin, :extern, :meta, :inserted_meta] do
    term
  end

  # ============================================================================
  # Rigid-rigid unification
  # ============================================================================

  defp unify_rigid(ms, lvl, lhs, rhs) do
    case {lhs, rhs} do
      # Pi vs Pi.
      {{:vpi, mult1, dom1, env1, cod1}, {:vpi, mult2, dom2, env2, cod2}} ->
        if mult1 != mult2 do
          {:error, {:multiplicity_mismatch, mult1, mult2}}
        else
          with {:ok, ms} <- unify(ms, lvl, dom1, dom2) do
            # Evaluate codomains with a fresh variable.
            fresh = Value.fresh_var(lvl, dom1)
            cod1_val = Eval.eval(%{Eval.default_ctx() | env: [fresh | env1]}, cod1)
            cod2_val = Eval.eval(%{Eval.default_ctx() | env: [fresh | env2]}, cod2)
            unify(ms, lvl + 1, cod1_val, cod2_val)
          end
        end

      # Sigma vs Sigma.
      {{:vsigma, a1, env1, b1}, {:vsigma, a2, env2, b2}} ->
        with {:ok, ms} <- unify(ms, lvl, a1, a2) do
          fresh = Value.fresh_var(lvl, a1)
          b1_val = Eval.eval(%{Eval.default_ctx() | env: [fresh | env1]}, b1)
          b2_val = Eval.eval(%{Eval.default_ctx() | env: [fresh | env2]}, b2)
          unify(ms, lvl + 1, b1_val, b2_val)
        end

      # Lam vs Lam.
      {{:vlam, _m1, env1, body1}, {:vlam, _m2, env2, body2}} ->
        fresh = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
        b1 = Eval.eval(%{Eval.default_ctx() | env: [fresh | env1]}, body1)
        b2 = Eval.eval(%{Eval.default_ctx() | env: [fresh | env2]}, body2)
        unify(ms, lvl + 1, b1, b2)

      # Pair vs Pair.
      {{:vpair, a1, b1}, {:vpair, a2, b2}} ->
        with {:ok, ms} <- unify(ms, lvl, a1, a2) do
          unify(ms, lvl, b1, b2)
        end

      # Type vs Type: accumulate level constraint.
      {{:vtype, l1}, {:vtype, l2}} ->
        {:ok, MetaState.add_constraint(ms, {:eq, l1, l2})}

      # Lit vs Lit.
      {{:vlit, v1}, {:vlit, v2}} ->
        if v1 == v2, do: {:ok, ms}, else: {:error, {:mismatch, lhs, rhs}}

      # Builtin vs Builtin.
      {{:vbuiltin, n1}, {:vbuiltin, n2}} ->
        if n1 == n2, do: {:ok, ms}, else: {:error, {:mismatch, lhs, rhs}}

      # Data vs Data (ADT type constructors).
      {{:vdata, n1, args1}, {:vdata, n2, args2}} ->
        if n1 == n2 and length(args1) == length(args2) do
          Enum.zip(args1, args2)
          |> Enum.reduce_while({:ok, ms}, fn {a1, a2}, {:ok, ms_acc} ->
            case unify(ms_acc, lvl, a1, a2) do
              {:ok, _} = ok -> {:cont, ok}
              err -> {:halt, err}
            end
          end)
        else
          {:error, {:mismatch, lhs, rhs}}
        end

      # Con vs Con (data constructors).
      {{:vcon, t1, c1, args1}, {:vcon, t2, c2, args2}} ->
        if t1 == t2 and c1 == c2 and length(args1) == length(args2) do
          Enum.zip(args1, args2)
          |> Enum.reduce_while({:ok, ms}, fn {a1, a2}, {:ok, ms_acc} ->
            case unify(ms_acc, lvl, a1, a2) do
              {:ok, _} = ok -> {:cont, ok}
              err -> {:halt, err}
            end
          end)
        else
          {:error, {:mismatch, lhs, rhs}}
        end

      # Extern vs Extern.
      {{:vextern, m1, f1, a1}, {:vextern, m2, f2, a2}} ->
        if m1 == m2 and f1 == f2 and a1 == a2 do
          {:ok, ms}
        else
          {:error, {:mismatch, lhs, rhs}}
        end

      # Eta for functions: VLam vs non-VLam.
      {{:vlam, _mult, env, body}, _} ->
        fresh = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
        lhs_body = Eval.eval(%{Eval.default_ctx() | env: [fresh | env]}, body)
        rhs_body = Eval.vapp(Eval.default_ctx(), rhs, fresh)
        unify(ms, lvl + 1, lhs_body, rhs_body)

      {_, {:vlam, _mult, env, body}} ->
        fresh = Value.fresh_var(lvl, {:vtype, {:llit, 0}})
        rhs_body = Eval.eval(%{Eval.default_ctx() | env: [fresh | env]}, body)
        lhs_body = Eval.vapp(Eval.default_ctx(), lhs, fresh)
        unify(ms, lvl + 1, lhs_body, rhs_body)

      # Eta for pairs: VPair vs non-VPair at sigma type.
      {{:vpair, a1, b1}, _} ->
        with {:ok, ms} <- unify(ms, lvl, a1, Eval.vfst(rhs)) do
          unify(ms, lvl, b1, Eval.vsnd(rhs))
        end

      {_, {:vpair, a2, b2}} ->
        with {:ok, ms} <- unify(ms, lvl, Eval.vfst(lhs), a2) do
          unify(ms, lvl, Eval.vsnd(lhs), b2)
        end

      # Neutral vs Neutral.
      {{:vneutral, _, ne1}, {:vneutral, _, ne2}} ->
        unify_neutral(ms, lvl, ne1, ne2)

      # Mismatch.
      _ ->
        {:error, {:mismatch, lhs, rhs}}
    end
  end

  # ============================================================================
  # Neutral unification
  # ============================================================================

  defp unify_neutral(ms, _lvl, {:nvar, l1}, {:nvar, l2}) do
    if l1 == l2, do: {:ok, ms}, else: {:error, {:mismatch, {:nvar, l1}, {:nvar, l2}}}
  end

  defp unify_neutral(ms, lvl, {:napp, ne1, arg1}, {:napp, ne2, arg2}) do
    with {:ok, ms} <- unify_neutral(ms, lvl, ne1, ne2) do
      unify(ms, lvl, arg1, arg2)
    end
  end

  defp unify_neutral(ms, lvl, {:nfst, ne1}, {:nfst, ne2}) do
    unify_neutral(ms, lvl, ne1, ne2)
  end

  defp unify_neutral(ms, lvl, {:nsnd, ne1}, {:nsnd, ne2}) do
    unify_neutral(ms, lvl, ne1, ne2)
  end

  defp unify_neutral(ms, _lvl, {:nmeta, id1}, {:nmeta, id2}) do
    if id1 == id2, do: {:ok, ms}, else: {:error, {:mismatch, {:nmeta, id1}, {:nmeta, id2}}}
  end

  defp unify_neutral(ms, _lvl, {:nbuiltin, n1}, {:nbuiltin, n2}) do
    if n1 == n2, do: {:ok, ms}, else: {:error, {:mismatch, {:nbuiltin, n1}, {:nbuiltin, n2}}}
  end

  defp unify_neutral(ms, _lvl, {:ndef_ref, n1}, {:ndef_ref, n2}) do
    if n1 == n2, do: {:ok, ms}, else: {:error, {:mismatch, {:ndef_ref, n1}, {:ndef_ref, n2}}}
  end

  defp unify_neutral(ms, lvl, {:ndef, name1, args1}, {:ndef, name2, args2}) do
    if name1 == name2 and length(args1) == length(args2) do
      Enum.zip(args1, args2)
      |> Enum.reduce_while({:ok, ms}, fn {a1, a2}, {:ok, ms_acc} ->
        case unify(ms_acc, lvl, a1, a2) do
          {:ok, _} = ok -> {:cont, ok}
          err -> {:halt, err}
        end
      end)
    else
      {:error, {:mismatch, {:ndef, name1, args1}, {:ndef, name2, args2}}}
    end
  end

  # Stuck case expressions: if the scrutinees are equal (same stuck neutral),
  # the cases produce the same result (same branches from the same definition).
  defp unify_neutral(ms, lvl, {:ncase, ne1, _b1, _env1}, {:ncase, ne2, _b2, _env2}) do
    unify_neutral(ms, lvl, ne1, ne2)
  end

  defp unify_neutral(_ms, _lvl, ne1, ne2) do
    {:error, {:mismatch, ne1, ne2}}
  end
end
