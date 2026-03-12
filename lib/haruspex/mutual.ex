defmodule Haruspex.Mutual do
  @moduledoc """
  Mutual block handling for mutually recursive definitions.

  Elaborates groups of definitions where all names are in scope during body
  elaboration. Works in three phases: collect signatures, extend the context
  with all names, then elaborate each body.
  """

  alias Haruspex.Core
  alias Haruspex.Elaborate

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Collect type signatures from a list of definitions without elaborating bodies.

  Each definition must have a return type annotation. Returns the updated
  elaboration context and a list of `{name, type_core}` pairs.
  """
  @spec collect_signatures(Elaborate.t(), [term()]) ::
          {:ok, Elaborate.t(), [{atom(), Core.expr()}]} | {:error, Elaborate.elab_error()}
  def collect_signatures(ctx, defs) do
    collect_signatures_acc(ctx, defs, [])
  end

  @doc """
  Elaborate a mutual block of definitions.

  All definition names are in scope during body elaboration, enabling mutual
  recursion. Each definition must have a return type annotation.
  """
  @spec elaborate_mutual(Elaborate.t(), [term()]) ::
          {:ok, [{atom(), Core.expr(), Core.expr()}], Elaborate.t()}
          | {:error, Elaborate.elab_error()}
  def elaborate_mutual(ctx, defs) do
    # Phase 1: Collect all signatures.
    with {:ok, ctx, sigs} <- collect_signatures(ctx, defs) do
      # Phase 2: Push all def names into context.
      mutual_ctx = push_mutual_names(ctx, sigs)

      # Phase 3: Elaborate each body in the mutual context.
      elaborate_bodies(mutual_ctx, ctx, defs, sigs, [])
    end
  end

  @doc """
  Check which mutual names are unreferenced by any sibling's body.

  For a mutual block of size 1, always returns `[]` (self-recursion is fine
  as a standalone definition). For size > 1, walks each body's core term
  looking for var indices that correspond to sibling mutual names, accounting
  for the lambda depth of each body.

  Returns a list of names that are NOT referenced by any sibling.
  """
  @spec check_cross_references([{atom(), Core.expr(), Core.expr()}], [atom()]) :: [atom()]
  def check_cross_references(_results, mutual_names) when length(mutual_names) <= 1, do: []

  def check_cross_references(results, mutual_names) do
    n = length(mutual_names)

    # For each def i, check if any sibling j (j != i) references it.
    # In body j with k_j lambda wrappers, mutual name i has index = (n - 1 - i) + k_j.
    results
    |> Enum.with_index()
    |> Enum.filter(fn {{_name_i, _type_i, _body_i}, i} ->
      # Check if any sibling j references def i.
      not Enum.any?(Enum.with_index(results), fn {{_name_j, _type_j, body_j}, j} ->
        if j == i do
          false
        else
          k_j = count_lambdas(body_j)
          target_ix = n - 1 - i + k_j
          inner_body = strip_lambdas(body_j)
          references_var?(inner_body, target_ix)
        end
      end)
    end)
    |> Enum.map(fn {{name, _, _}, _} -> name end)
  end

  # ============================================================================
  # Internal — cross-reference helpers
  # ============================================================================

  # Count the number of outer lambda wrappers on a core term.
  @spec count_lambdas(Core.expr()) :: non_neg_integer()
  defp count_lambdas({:lam, _mult, body}), do: 1 + count_lambdas(body)
  defp count_lambdas(_), do: 0

  # Strip outer lambda wrappers to get the inner body.
  @spec strip_lambdas(Core.expr()) :: Core.expr()
  defp strip_lambdas({:lam, _mult, body}), do: strip_lambdas(body)
  defp strip_lambdas(term), do: term

  # Check if a core term contains a reference to `{:var, ix}`.
  @spec references_var?(Core.expr(), non_neg_integer()) :: boolean()
  defp references_var?({:var, ix}, target), do: ix == target

  defp references_var?({:app, func, arg}, target),
    do: references_var?(func, target) or references_var?(arg, target)

  defp references_var?({:lam, _mult, body}, target), do: references_var?(body, target + 1)

  defp references_var?({:let, val, body}, target),
    do: references_var?(val, target) or references_var?(body, target + 1)

  defp references_var?({:pi, _mult, dom, cod}, target),
    do: references_var?(dom, target) or references_var?(cod, target + 1)

  defp references_var?({:sigma, fst, snd}, target),
    do: references_var?(fst, target) or references_var?(snd, target + 1)

  defp references_var?({:meta, _}, _target), do: false
  defp references_var?({:lit, _}, _target), do: false
  defp references_var?({:builtin, _}, _target), do: false
  defp references_var?({:type, _}, _target), do: false
  defp references_var?(_, _target), do: false

  # ============================================================================
  # Internal — signature collection
  # ============================================================================

  @spec collect_signatures_acc(Elaborate.t(), [term()], [{atom(), Core.expr()}]) ::
          {:ok, Elaborate.t(), [{atom(), Core.expr()}]} | {:error, Elaborate.elab_error()}
  defp collect_signatures_acc(ctx, [], acc) do
    {:ok, ctx, Enum.reverse(acc)}
  end

  defp collect_signatures_acc(ctx, [def_node | rest], acc) do
    {:def, span, {:sig, _sig_span, name, _name_span, params, return_type, _attrs}, _body} =
      def_node

    case return_type do
      nil ->
        {:error, {:missing_return_type, name, span}}

      _ ->
        with {:ok, type_core, ctx} <- elaborate_sig_type(ctx, params, return_type) do
          collect_signatures_acc(ctx, rest, [{name, type_core} | acc])
        end
    end
  end

  # Build a nested Pi type from params and return type, without pushing
  # permanent bindings into the outer context. We use a temporary context
  # for the binder scopes but propagate meta state back.
  @spec elaborate_sig_type(Elaborate.t(), [term()], term()) ::
          {:ok, Core.expr(), Elaborate.t()} | {:error, Elaborate.elab_error()}
  defp elaborate_sig_type(ctx, params, return_type) do
    elaborate_pi_chain(ctx, params, return_type)
  end

  @spec elaborate_pi_chain(Elaborate.t(), [term()], term()) ::
          {:ok, Core.expr(), Elaborate.t()} | {:error, Elaborate.elab_error()}
  defp elaborate_pi_chain(ctx, [], return_type) do
    Elaborate.elaborate_type(ctx, return_type)
  end

  defp elaborate_pi_chain(
         ctx,
         [{:param, _span, {name, mult, implicit?}, param_type} | rest],
         return_type
       ) do
    core_mult = if implicit?, do: :zero, else: mult

    with {:ok, dom_core, ctx} <- Elaborate.elaborate_type(ctx, param_type) do
      inner_ctx = push_temp_binding(ctx, name)

      with {:ok, cod_core, inner_ctx} <- elaborate_pi_chain(inner_ctx, rest, return_type) do
        ctx = restore_meta_state(ctx, inner_ctx)
        {:ok, {:pi, core_mult, dom_core, cod_core}, ctx}
      end
    end
  end

  # ============================================================================
  # Internal — mutual context extension
  # ============================================================================

  # Push all mutual definition names into the context so they are available
  # during body elaboration.
  @spec push_mutual_names(Elaborate.t(), [{atom(), Core.expr()}]) :: Elaborate.t()
  defp push_mutual_names(ctx, sigs) do
    Enum.reduce(sigs, ctx, fn {name, _type_core}, acc ->
      %{
        acc
        | names: [{name, acc.level} | acc.names],
          name_list: acc.name_list ++ [name],
          level: acc.level + 1
      }
    end)
  end

  # ============================================================================
  # Internal — body elaboration
  # ============================================================================

  @spec elaborate_bodies(Elaborate.t(), Elaborate.t(), [term()], [{atom(), Core.expr()}], [
          {atom(), Core.expr(), Core.expr()}
        ]) ::
          {:ok, [{atom(), Core.expr(), Core.expr()}], Elaborate.t()}
          | {:error, Elaborate.elab_error()}
  defp elaborate_bodies(mutual_ctx, original_ctx, [], _sigs, acc) do
    # Propagate meta state back to the original context level.
    ctx = restore_meta_state(original_ctx, mutual_ctx)
    {:ok, Enum.reverse(acc), ctx}
  end

  defp elaborate_bodies(
         mutual_ctx,
         original_ctx,
         [def_node | rest],
         [{name, type_core} | sig_rest],
         acc
       ) do
    {:def, _span, {:sig, _sig_span, _name, _name_span, params, _return_type, _attrs}, body} =
      def_node

    # Push param bindings on top of the mutual context.
    with {:ok, body_core, mutual_ctx} <- elaborate_def_body_in(mutual_ctx, params, body) do
      elaborate_bodies(mutual_ctx, original_ctx, rest, sig_rest, [
        {name, type_core, body_core} | acc
      ])
    end
  end

  # Elaborate a definition body with param bindings, wrapping in lambdas.
  @spec elaborate_def_body_in(Elaborate.t(), [term()], term()) ::
          {:ok, Core.expr(), Elaborate.t()} | {:error, Elaborate.elab_error()}
  defp elaborate_def_body_in(ctx, [], body) do
    Elaborate.elaborate(ctx, body)
  end

  defp elaborate_def_body_in(ctx, [{:param, _span, {name, mult, _implicit?}, _type} | rest], body) do
    inner_ctx = push_temp_binding(ctx, name)

    with {:ok, body_core, inner_ctx} <- elaborate_def_body_in(inner_ctx, rest, body) do
      ctx = restore_meta_state(ctx, inner_ctx)
      {:ok, {:lam, mult, body_core}, ctx}
    end
  end

  # ============================================================================
  # Internal — helpers
  # ============================================================================

  # Push a temporary binding for use in nested scopes.
  @spec push_temp_binding(Elaborate.t(), atom()) :: Elaborate.t()
  defp push_temp_binding(ctx, name) do
    %{
      ctx
      | names: [{name, ctx.level} | ctx.names],
        name_list: ctx.name_list ++ [name],
        level: ctx.level + 1
    }
  end

  # Propagate meta state, holes, and level var counter from inner to outer.
  @spec restore_meta_state(Elaborate.t(), Elaborate.t()) :: Elaborate.t()
  defp restore_meta_state(outer, inner) do
    %{
      outer
      | meta_state: inner.meta_state,
        holes: inner.holes,
        next_level_var: inner.next_level_var
    }
  end
end
