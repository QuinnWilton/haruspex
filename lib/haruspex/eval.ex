defmodule Haruspex.Eval do
  @moduledoc """
  Evaluation: core terms to values (normalization-by-evaluation).

  Takes a core term and an evaluation context and produces a value in
  weak head normal form. Closures capture the environment for binders.
  Stuck computations (free variables, unsolved metas, opaque functions)
  produce neutral values.
  """

  alias Haruspex.Core
  alias Haruspex.Value

  @default_fuel 1000

  # ============================================================================
  # Types
  # ============================================================================

  @type eval_ctx :: %{
          env: Value.env(),
          metas: %{Core.meta_id() => {:solved, Value.value()} | :unsolved},
          defs: %{atom() => {Core.expr(), boolean()}},
          fuel: non_neg_integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a default evaluation context with the given environment.
  """
  @spec default_ctx(Value.env()) :: eval_ctx()
  def default_ctx(env \\ []) do
    %{env: env, metas: %{}, defs: %{}, fuel: @default_fuel}
  end

  @doc """
  Evaluate a core term to a value in the given context.
  """
  @spec eval(eval_ctx(), Core.expr()) :: Value.value()
  def eval(ctx, term)

  def eval(ctx, {:var, ix}) do
    Enum.at(ctx.env, ix)
  end

  def eval(ctx, {:lam, mult, body}) do
    {:vlam, mult, ctx.env, body}
  end

  def eval(ctx, {:app, f, a}) do
    vapp(ctx, eval(ctx, f), eval(ctx, a))
  end

  def eval(ctx, {:pi, mult, dom, cod}) do
    {:vpi, mult, eval(ctx, dom), ctx.env, cod}
  end

  def eval(ctx, {:sigma, a, b}) do
    {:vsigma, eval(ctx, a), ctx.env, b}
  end

  def eval(ctx, {:pair, a, b}) do
    {:vpair, eval(ctx, a), eval(ctx, b)}
  end

  def eval(ctx, {:fst, e}) do
    vfst(eval(ctx, e))
  end

  def eval(ctx, {:snd, e}) do
    vsnd(eval(ctx, e))
  end

  def eval(ctx, {:let, def_val, body}) do
    val = eval(ctx, def_val)
    eval(%{ctx | env: [val | ctx.env]}, body)
  end

  def eval(_ctx, {:type, level}) do
    {:vtype, level}
  end

  def eval(_ctx, {:lit, value}) do
    {:vlit, value}
  end

  def eval(_ctx, {:builtin, name}) do
    {:vbuiltin, name}
  end

  def eval(_ctx, {:extern, mod, fun, arity}) do
    {:vextern, mod, fun, arity}
  end

  def eval(_ctx, {:global, mod, name, arity}) do
    {:vglobal, mod, name, arity}
  end

  # Definition reference: look up in defs map and unfold if total + fuel > 0.
  def eval(ctx, {:def_ref, name}) do
    case Map.get(ctx.defs, name) do
      {body, true} when ctx.fuel > 0 ->
        # Total definition with fuel — unfold.
        eval(%{ctx | fuel: ctx.fuel - 1}, body)

      {_body, _total?} ->
        # No fuel or non-total — stuck neutral.
        {:vneutral, {:vtype, {:llit, 0}}, {:ndef_ref, name}}

      nil ->
        # Unknown definition — stuck neutral.
        {:vneutral, {:vtype, {:llit, 0}}, {:ndef_ref, name}}
    end
  end

  def eval(ctx, {:meta, id}) do
    case Map.get(ctx.metas, id) do
      {:solved, val} -> val
      _ -> {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id}}
    end
  end

  def eval(ctx, {:inserted_meta, id, mask}) do
    meta_val =
      case Map.get(ctx.metas, id) do
        {:solved, val} -> val
        _ -> {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, id}}
      end

    # Apply the meta to each env variable where mask is true.
    # Mask is indexed by de Bruijn level (0 = oldest binding).
    depth = length(ctx.env)

    mask
    |> Enum.with_index()
    |> Enum.filter(fn {included, _} -> included end)
    |> Enum.reduce(meta_val, fn {_, level}, acc ->
      env_ix = depth - level - 1
      vapp(ctx, acc, Enum.at(ctx.env, env_ix))
    end)
  end

  def eval(ctx, {:data, name, args}) do
    {:vdata, name, Enum.map(args, &eval(ctx, &1))}
  end

  def eval(ctx, {:con, type_name, con_name, args}) do
    {:vcon, type_name, con_name, Enum.map(args, &eval(ctx, &1))}
  end

  def eval(ctx, {:case, scrutinee, branches}) do
    vcase(ctx, eval(ctx, scrutinee), branches)
  end

  def eval(ctx, {:spanned, _span, inner}) do
    eval(ctx, inner)
  end

  # ============================================================================
  # Case reduction
  # ============================================================================

  @doc """
  Reduce a case expression. If the scrutinee is a constructor, find the
  matching branch and evaluate the body with constructor args in scope.
  If the scrutinee is neutral, produce a stuck case.
  """
  @spec vcase(eval_ctx(), Value.value(), [{atom(), non_neg_integer(), Core.expr()}]) ::
          Value.value()
  def vcase(ctx, {:vcon, _type_name, con_name, con_args} = scrutinee, branches) do
    case find_constructor_branch(branches, con_name) do
      {:ok, _arity, body} ->
        # Extend the environment with constructor arguments (most recent first).
        env = Enum.reverse(con_args) ++ ctx.env
        eval(%{ctx | env: env}, body)

      :error ->
        # Fall through to wildcard branch.
        case find_wildcard_branch(branches) do
          {:ok, 1, body} ->
            eval(%{ctx | env: [scrutinee | ctx.env]}, body)

          {:ok, 0, body} ->
            eval(ctx, body)

          :error ->
            raise Haruspex.CompilerBug,
                  "no branch for constructor #{con_name} in case expression"
        end
    end
  end

  def vcase(ctx, {:vlit, value} = scrutinee, branches) do
    case find_literal_branch(branches, value) do
      {:ok, body} ->
        eval(ctx, body)

      :error ->
        # Fall through to wildcard branch.
        case find_wildcard_branch(branches) do
          {:ok, 1, body} ->
            eval(%{ctx | env: [scrutinee | ctx.env]}, body)

          {:ok, 0, body} ->
            eval(ctx, body)

          :error ->
            raise Haruspex.CompilerBug,
                  "no branch for literal #{inspect(value)} in case expression"
        end
    end
  end

  def vcase(ctx, {:vneutral, type, ne}, branches) do
    # Store per-branch closures: each branch captures the current env.
    closures =
      Enum.map(branches, fn
        {:__lit, value, body} -> {:__lit, value, {ctx.env, body}}
        {con_name, arity, body} -> {con_name, arity, {ctx.env, body}}
      end)

    {:vneutral, type, {:ncase, ne, closures}}
  end

  defp find_constructor_branch(branches, con_name) do
    Enum.find_value(branches, :error, fn
      {^con_name, arity, body} when con_name not in [:__lit, :_] -> {:ok, arity, body}
      _ -> nil
    end)
  end

  defp find_literal_branch(branches, value) do
    Enum.find_value(branches, :error, fn
      {:__lit, ^value, body} -> {:ok, body}
      _ -> nil
    end)
  end

  defp find_wildcard_branch(branches) do
    Enum.find_value(branches, :error, fn
      {:_, arity, body} -> {:ok, arity, body}
      _ -> nil
    end)
  end

  # ============================================================================
  # Application
  # ============================================================================

  @doc """
  Apply a value to an argument. Handles beta reduction for lambdas,
  delta reduction for builtins, and stuck application for neutrals.
  """
  @spec vapp(eval_ctx(), Value.value(), Value.value()) :: Value.value()
  def vapp(ctx, fun, arg)

  # Beta reduction.
  def vapp(ctx, {:vlam, _mult, env, body}, arg) do
    eval(%{ctx | env: [arg | env]}, body)
  end

  # Stuck application on neutral.
  def vapp(ctx, {:vneutral, {:vpi, _m, _dom, env, cod}, ne}, arg) do
    # The result type is the codomain instantiated with the argument.
    # Thread metas and defs so solved metas in the codomain resolve correctly.
    cod_type = eval(%{ctx | env: [arg | env]}, cod)
    {:vneutral, cod_type, {:napp, ne, arg}}
  end

  # Neutral without Pi type (can happen during meta solving).
  def vapp(_ctx, {:vneutral, type, ne}, arg) do
    {:vneutral, type, {:napp, ne, arg}}
  end

  # Builtin application — collect args, attempt delta when fully applied.
  def vapp(ctx, {:vbuiltin, name}, arg) when is_atom(name) do
    arity = builtin_arity(name)

    cond do
      # Type builtins have arity 0, shouldn't be applied.
      arity == 0 ->
        {:vneutral, {:vtype, {:llit, 0}}, {:napp, {:nbuiltin, name}, arg}}

      arity == 1 ->
        delta_reduce(ctx, name, [arg])

      true ->
        {:vbuiltin, {name, [arg]}}
    end
  end

  def vapp(ctx, {:vbuiltin, {name, args}}, arg) do
    all_args = args ++ [arg]
    arity = builtin_arity(name)

    if length(all_args) == arity do
      delta_reduce(ctx, name, all_args)
    else
      {:vbuiltin, {name, all_args}}
    end
  end

  # Extern application — always stuck.
  def vapp(_ctx, {:vextern, mod, fun, arity}, arg) do
    {:vneutral, {:vtype, {:llit, 0}}, {:napp, {:ndef, {mod, fun, arity}, []}, arg}}
  end

  # Global (cross-module) application — always stuck.
  def vapp(_ctx, {:vglobal, mod, name, arity}, arg) do
    {:vneutral, {:vtype, {:llit, 0}}, {:napp, {:ndef, {mod, name, arity}, []}, arg}}
  end

  # ============================================================================
  # Projections
  # ============================================================================

  @doc """
  First projection of a pair or stuck projection of a neutral.
  """
  @spec vfst(Value.value()) :: Value.value()
  def vfst({:vpair, a, _b}), do: a

  def vfst({:vneutral, {:vsigma, a, _env, _b}, ne}) do
    {:vneutral, a, {:nfst, ne}}
  end

  def vfst({:vneutral, type, ne}) do
    {:vneutral, type, {:nfst, ne}}
  end

  @doc """
  Second projection of a pair or stuck projection of a neutral.
  """
  @spec vsnd(Value.value()) :: Value.value()
  def vsnd({:vpair, _a, b}), do: b

  def vsnd({:vneutral, {:vsigma, fst_type, env, b}, ne}) do
    # The second component's type depends on the first component's value.
    fst_val = {:vneutral, fst_type, {:nfst, ne}}
    b_type = do_eval_in_env(env, b, fst_val)
    {:vneutral, b_type, {:nsnd, ne}}
  end

  def vsnd({:vneutral, type, ne}) do
    {:vneutral, type, {:nsnd, ne}}
  end

  # ============================================================================
  # Delta reduction
  # ============================================================================

  @builtin_arities %{
    # Type builtins (not applied).
    Int: 0,
    Float: 0,
    String: 0,
    Atom: 0,
    # Unary operations.
    neg: 1,
    not: 1,
    # Binary operations.
    add: 2,
    sub: 2,
    mul: 2,
    div: 2,
    fadd: 2,
    fsub: 2,
    fmul: 2,
    fdiv: 2,
    eq: 2,
    neq: 2,
    lt: 2,
    gt: 2,
    lte: 2,
    gte: 2,
    and: 2,
    or: 2
  }

  defp builtin_arity(name), do: Map.get(@builtin_arities, name, 0)

  # Attempt delta reduction. If all args are literals, reduce. Otherwise stuck.
  defp delta_reduce(ctx, name, args) do
    if all_literals?(args) do
      lit_args = Enum.map(args, fn {:vlit, v} -> v end)

      case do_delta(name, lit_args) do
        {:ok, result} -> result
        :stuck -> make_stuck_builtin(ctx, name, args)
      end
    else
      make_stuck_builtin(ctx, name, args)
    end
  end

  defp all_literals?(args) do
    Enum.all?(args, fn
      {:vlit, _} -> true
      _ -> false
    end)
  end

  # Integer arithmetic.
  defp do_delta(:add, [a, b]), do: {:ok, {:vlit, a + b}}
  defp do_delta(:sub, [a, b]), do: {:ok, {:vlit, a - b}}
  defp do_delta(:mul, [a, b]), do: {:ok, {:vlit, a * b}}
  defp do_delta(:div, [_, 0]), do: :stuck
  defp do_delta(:div, [a, b]), do: {:ok, {:vlit, Kernel.div(a, b)}}
  defp do_delta(:neg, [a]), do: {:ok, {:vlit, -a}}

  # Float arithmetic.
  defp do_delta(:fadd, [a, b]), do: {:ok, {:vlit, a + b}}
  defp do_delta(:fsub, [a, b]), do: {:ok, {:vlit, a - b}}
  defp do_delta(:fmul, [a, b]), do: {:ok, {:vlit, a * b}}
  defp do_delta(:fdiv, [_, +0.0]), do: :stuck
  defp do_delta(:fdiv, [a, b]), do: {:ok, {:vlit, a / b}}

  # Comparison (produce boolean literals for now; becomes VCon at tier 5).
  defp do_delta(:eq, [a, b]), do: {:ok, {:vlit, a == b}}
  defp do_delta(:neq, [a, b]), do: {:ok, {:vlit, a != b}}
  defp do_delta(:lt, [a, b]), do: {:ok, {:vlit, a < b}}
  defp do_delta(:gt, [a, b]), do: {:ok, {:vlit, a > b}}
  defp do_delta(:lte, [a, b]), do: {:ok, {:vlit, a <= b}}
  defp do_delta(:gte, [a, b]), do: {:ok, {:vlit, a >= b}}

  # Boolean operations.
  defp do_delta(:and, [a, b]), do: {:ok, {:vlit, a and b}}
  defp do_delta(:or, [a, b]), do: {:ok, {:vlit, a or b}}
  defp do_delta(:not, [a]), do: {:ok, {:vlit, not a}}

  defp do_delta(_, _), do: :stuck

  # Build a stuck neutral from a builtin applied to args (at least one non-literal).
  defp make_stuck_builtin(_ctx, name, args) do
    result_type = builtin_result_type(name)
    ne = Enum.reduce(args, {:nbuiltin, name}, fn arg, ne -> {:napp, ne, arg} end)
    {:vneutral, result_type, ne}
  end

  @builtin_result_types %{
    add: {:vbuiltin, :Int},
    sub: {:vbuiltin, :Int},
    mul: {:vbuiltin, :Int},
    div: {:vbuiltin, :Int},
    neg: {:vbuiltin, :Int},
    fadd: {:vbuiltin, :Float},
    fsub: {:vbuiltin, :Float},
    fmul: {:vbuiltin, :Float},
    fdiv: {:vbuiltin, :Float},
    eq: {:vbuiltin, :Bool},
    neq: {:vbuiltin, :Bool},
    lt: {:vbuiltin, :Bool},
    gt: {:vbuiltin, :Bool},
    lte: {:vbuiltin, :Bool},
    gte: {:vbuiltin, :Bool},
    and: {:vbuiltin, :Bool},
    or: {:vbuiltin, :Bool},
    not: {:vbuiltin, :Bool}
  }

  defp builtin_result_type(name), do: Map.get(@builtin_result_types, name, {:vtype, {:llit, 0}})

  # ============================================================================
  # Internal helpers
  # ============================================================================

  # Evaluate a closure body with a single argument prepended to the captured env.
  # Used for computing codomain types in Pi/Sigma applications.
  # Extract the env and plain branches from ncase closures.
  defp unwrap_closures(closures) do
    env =
      case closures do
        [{_, _, {e, _}} | _] -> e
        [{_, _, _, {e, _}} | _] -> e
        _ -> []
      end

    branches =
      Enum.map(closures, fn
        {:__lit, value, {_env, body}} -> {:__lit, value, body}
        {con_name, arity, {_env, body}} -> {con_name, arity, body}
      end)

    {env, branches}
  end

  defp do_eval_in_env(env, body, arg) do
    eval(%{env: [arg | env], metas: %{}, defs: %{}, fuel: @default_fuel}, body)
  end

  # ============================================================================
  # Weak head normal form with meta resolution
  # ============================================================================

  @doc """
  Reduce a value to weak head normal form, resolving solved metas.

  Unlike `MetaState.force/2` which only follows top-level meta chains, `whnf`
  re-reduces computations that were stuck on unsolved metas that have since
  been solved. This handles:

  - Bare solved metas: `?m` where `?m := v` → `whnf(v)`
  - Applied solved metas: `?m(a1)(a2)` → `whnf(v(a1)(a2))`
  - Stuck cases on solved metas: `case ?m of ...` where `?m := C(...)` → reduce case

  Use this instead of `MetaState.force` whenever the value may contain
  stale meta references from closure-captured environments.
  """
  @spec whnf(eval_ctx(), Value.value()) :: Value.value()
  def whnf(ctx, {:vneutral, _type, ne} = val) do
    case whnf_neutral(ctx, ne) do
      {:reduced, new_val} -> whnf(ctx, new_val)
      :stuck -> val
    end
  end

  def whnf(_ctx, val), do: val

  # Try to unstick a neutral by resolving solved metas.
  # Returns {:reduced, value} if the neutral became a non-neutral value,
  # or :stuck if it remains neutral.
  @spec whnf_neutral(eval_ctx(), Value.neutral()) :: {:reduced, Value.value()} | :stuck
  defp whnf_neutral(ctx, {:nmeta, id}) do
    case Map.get(ctx.metas, id) do
      {:solved, solution} -> {:reduced, solution}
      _ -> :stuck
    end
  end

  # Applied neutral: if the head is a solved meta, collect the spine,
  # resolve the head, and re-apply.
  defp whnf_neutral(ctx, {:napp, ne, arg}) do
    case whnf_neutral(ctx, ne) do
      {:reduced, fun_val} -> {:reduced, vapp(ctx, fun_val, arg)}
      :stuck -> :stuck
    end
  end

  # Stuck case: if the scrutinee is now a constructor, re-reduce.
  defp whnf_neutral(ctx, {:ncase, ne, closures}) do
    case whnf_neutral(ctx, ne) do
      {:reduced, scrut_val} ->
        # Unwrap closures back to plain branches for vcase, using the
        # first closure's env as the evaluation env.
        {env, branches} = unwrap_closures(closures)
        {:reduced, vcase(%{ctx | env: env}, scrut_val, branches)}

      :stuck ->
        :stuck
    end
  end

  # Stuck fst/snd: if the inner neutral resolves, re-project.
  defp whnf_neutral(ctx, {:nfst, ne}) do
    case whnf_neutral(ctx, ne) do
      {:reduced, val} -> {:reduced, vfst(val)}
      :stuck -> :stuck
    end
  end

  defp whnf_neutral(ctx, {:nsnd, ne}) do
    case whnf_neutral(ctx, ne) do
      {:reduced, val} -> {:reduced, vsnd(val)}
      :stuck -> :stuck
    end
  end

  # Everything else stays stuck.
  defp whnf_neutral(_ctx, _ne), do: :stuck
end
