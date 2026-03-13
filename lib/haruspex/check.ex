defmodule Haruspex.Check do
  @moduledoc """
  Bidirectional type checker.

  Implements synth (type inference) and check (type verification) modes with
  multiplicity tracking, implicit argument insertion, and post-definition
  processing (hole reports, level solving, zonking).
  """

  alias Haruspex.Context
  alias Haruspex.Core
  alias Haruspex.Eval
  alias Haruspex.Pretty
  alias Haruspex.Quote
  alias Haruspex.Unify
  alias Haruspex.Unify.LevelSolver
  alias Haruspex.Unify.MetaState
  alias Haruspex.Value

  # ============================================================================
  # Types
  # ============================================================================

  @type hole_report :: %{
          span: Pentiment.Span.Byte.t() | nil,
          expected_type: String.t(),
          bindings: [{atom(), String.t()}]
        }

  @type type_error ::
          {:type_mismatch, expected :: Value.value(), got :: Value.value()}
          | {:not_a_function, Value.value()}
          | {:not_a_pair, Value.value()}
          | {:not_a_type, Value.value()}
          | {:unsolved_meta, Core.meta_id(), Value.value()}
          | {:multiplicity_violation, atom(), Core.mult(), non_neg_integer()}
          | {:multiplicity_mismatch, Core.mult(), Core.mult()}
          | {:universe_error, String.t()}

  @enforce_keys [:context, :names, :meta_state]
  defstruct [:context, :names, :meta_state, :db, hole_reports: []]

  @type t :: %__MODULE__{
          context: Context.t(),
          names: [atom()],
          meta_state: MetaState.t(),
          db: term() | nil,
          hole_reports: [hole_report()]
        }

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create an empty check context.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      context: Context.empty(),
      names: [],
      meta_state: MetaState.new()
    }
  end

  @doc """
  Create a check context from an existing meta state.
  """
  @spec from_meta_state(MetaState.t()) :: t()
  def from_meta_state(ms) do
    %__MODULE__{
      context: Context.empty(),
      names: [],
      meta_state: ms
    }
  end

  # ============================================================================
  # Public API — synth
  # ============================================================================

  @doc """
  Synthesize the type of a core term. Returns the elaborated term, its type,
  and updated context.
  """
  @spec synth(t(), Core.expr()) ::
          {:ok, Core.expr(), Value.value(), t()} | {:error, type_error()}
  def synth(ctx, term)

  # Var: look up type in context, track usage.
  def synth(ctx, {:var, ix}) do
    type = Context.lookup_type(ctx.context, ix)
    context = Context.use_var(ctx.context, ix)
    {:ok, {:var, ix}, type, %{ctx | context: context}}
  end

  # Literal typing.
  def synth(ctx, {:lit, n}) when is_integer(n), do: {:ok, {:lit, n}, {:vbuiltin, :Int}, ctx}
  def synth(ctx, {:lit, f}) when is_float(f), do: {:ok, {:lit, f}, {:vbuiltin, :Float}, ctx}
  def synth(ctx, {:lit, s}) when is_binary(s), do: {:ok, {:lit, s}, {:vbuiltin, :String}, ctx}
  def synth(ctx, {:lit, true}), do: {:ok, {:lit, true}, {:vbuiltin, :Atom}, ctx}
  def synth(ctx, {:lit, false}), do: {:ok, {:lit, false}, {:vbuiltin, :Atom}, ctx}
  def synth(ctx, {:lit, a}) when is_atom(a), do: {:ok, {:lit, a}, {:vbuiltin, :Atom}, ctx}

  # Type universe.
  def synth(ctx, {:type, level}) do
    {:ok, {:type, level}, {:vtype, {:lsucc, level}}, ctx}
  end

  # Pi type: check domain is Type, check codomain is Type in extended context.
  def synth(ctx, {:pi, mult, dom, cod}) do
    with {:ok, dom_term, dom_level, ctx} <- check_is_type(ctx, dom) do
      dom_val = eval_in(ctx, dom_term)
      inner_ctx = extend_ctx(ctx, :_pi_dom, dom_val, mult)

      with {:ok, cod_term, cod_level, inner_ctx} <- check_is_type(inner_ctx, cod) do
        ctx = restore_ctx(ctx, inner_ctx)
        result_level = {:lmax, dom_level, cod_level}
        {:ok, {:pi, mult, dom_term, cod_term}, {:vtype, result_level}, ctx}
      end
    end
  end

  # Sigma type.
  def synth(ctx, {:sigma, a, b}) do
    with {:ok, a_term, a_level, ctx} <- check_is_type(ctx, a) do
      a_val = eval_in(ctx, a_term)
      inner_ctx = extend_ctx(ctx, :_sigma_fst, a_val, :omega)

      with {:ok, b_term, b_level, inner_ctx} <- check_is_type(inner_ctx, b) do
        ctx = restore_ctx(ctx, inner_ctx)
        result_level = {:lmax, a_level, b_level}
        {:ok, {:sigma, a_term, b_term}, {:vtype, result_level}, ctx}
      end
    end
  end

  # Application: synth function, expect Pi, check argument.
  def synth(ctx, {:app, f, a}) do
    with {:ok, f_term, f_type, ctx} <- synth(ctx, f) do
      f_type = MetaState.force(ctx.meta_state, f_type)

      case f_type do
        {:vpi, _mult, dom, env, cod} ->
          with {:ok, a_term, ctx} <- check(ctx, a, dom) do
            a_val = eval_in(ctx, a_term)
            cod_val = Eval.eval(make_eval_ctx(ctx, [a_val | env]), cod)
            {:ok, {:app, f_term, a_term}, cod_val, ctx}
          end

        _ ->
          {:error, {:not_a_function, f_type}}
      end
    end
  end

  # Fst projection.
  def synth(ctx, {:fst, e}) do
    with {:ok, e_term, e_type, ctx} <- synth(ctx, e) do
      e_type = MetaState.force(ctx.meta_state, e_type)

      case e_type do
        {:vsigma, a, _env, _b} ->
          {:ok, {:fst, e_term}, a, ctx}

        _ ->
          {:error, {:not_a_pair, e_type}}
      end
    end
  end

  # Snd projection.
  def synth(ctx, {:snd, e}) do
    with {:ok, e_term, e_type, ctx} <- synth(ctx, e) do
      e_type = MetaState.force(ctx.meta_state, e_type)

      case e_type do
        {:vsigma, _a, env, b} ->
          fst_val = Eval.vfst(eval_in(ctx, e_term))
          snd_type = Eval.eval(make_eval_ctx(ctx, [fst_val | env]), b)
          {:ok, {:snd, e_term}, snd_type, ctx}

        _ ->
          {:error, {:not_a_pair, e_type}}
      end
    end
  end

  # Builtin type.
  def synth(ctx, {:builtin, name}) do
    type = builtin_type(name)
    {:ok, {:builtin, name}, type, ctx}
  end

  # Global cross-module reference: look up the type via roux query.
  def synth(ctx, {:global, mod, name, _arity} = term) do
    if ctx.db do
      # Find the URI for this module and elaborate to get the type.
      uri = global_module_uri(mod)

      case Roux.Runtime.query(ctx.db, :haruspex_elaborate, {uri, name}) do
        {:ok, {type_core, _body_core}} ->
          type_val = eval_in(ctx, type_core)
          # Strip zero-multiplicity pi prefixes — erased params are already
          # excluded from the global's arity and won't appear at call sites.
          type_val = strip_erased_pis(type_val)
          {:ok, term, type_val, ctx}

        {:error, _} = err ->
          err
      end
    else
      # No DB — treat as opaque with unknown type.
      {:ok, term, {:vtype, {:llit, 0}}, ctx}
    end
  end

  # Meta: look up type in MetaState.
  def synth(ctx, {:meta, id}) do
    case MetaState.lookup(ctx.meta_state, id) do
      {:unsolved, type, _level, _kind} ->
        {:ok, {:meta, id}, type, ctx}

      {:solved, val} ->
        term = Quote.quote_untyped(Context.level(ctx.context), val)
        synth(ctx, term)
    end
  end

  # Inserted meta: evaluate and synth the result.
  def synth(ctx, {:inserted_meta, _id, _mask} = term) do
    val = Eval.eval(make_eval_ctx(ctx, Context.env(ctx.context)), term)
    quoted = Quote.quote_untyped(Context.level(ctx.context), val)
    synth(ctx, quoted)
  end

  # Let: synth definition, extend context, synth body.
  def synth(ctx, {:let, def_val, body}) do
    with {:ok, def_term, def_type, ctx} <- synth(ctx, def_val) do
      def_val_v = eval_in(ctx, def_term)
      inner_ctx = extend_def_ctx(ctx, :_let, def_type, :omega, def_val_v)

      with {:ok, body_term, body_type, inner_ctx} <- synth(inner_ctx, body) do
        ctx = restore_ctx(ctx, inner_ctx)
        {:ok, {:let, def_term, body_term}, body_type, ctx}
      end
    end
  end

  # Pair: can only synth if both components can be synthed.
  def synth(ctx, {:pair, a, b}) do
    with {:ok, a_term, a_type, ctx} <- synth(ctx, a),
         {:ok, b_term, b_type, ctx} <- synth(ctx, b) do
      b_type_term = Quote.quote_untyped(Context.level(ctx.context), b_type)
      # Non-dependent sigma: codomain doesn't use the bound variable.
      sig_type = {:vsigma, a_type, Context.env(ctx.context), Core.shift(b_type_term, 1, 0)}
      {:ok, {:pair, a_term, b_term}, sig_type, ctx}
    end
  end

  # Spanned: unwrap and synth inner.
  def synth(ctx, {:spanned, _span, inner}) do
    synth(ctx, inner)
  end

  # ============================================================================
  # Public API — check
  # ============================================================================

  @doc """
  Check a core term against an expected type. Returns the elaborated term
  and updated context.
  """
  @spec check(t(), Core.expr(), Value.value()) ::
          {:ok, Core.expr(), t()} | {:error, type_error()}

  # Lambda against Pi.
  def check(ctx, {:lam, mult, body}, {:vpi, pi_mult, dom, env, cod}) do
    if mult != pi_mult do
      {:error, {:multiplicity_mismatch, pi_mult, mult}}
    else
      name = pick_binder_name(ctx)
      inner_ctx = extend_ctx(ctx, name, dom, pi_mult)

      arg = Value.fresh_var(Context.level(ctx.context), dom)
      cod_val = Eval.eval(make_eval_ctx(ctx, [arg | env]), cod)

      with {:ok, body_term, inner_ctx} <- check(inner_ctx, body, cod_val) do
        case Context.check_usage(inner_ctx.context, 0) do
          :ok ->
            ctx = restore_ctx(ctx, inner_ctx)
            {:ok, {:lam, mult, body_term}, ctx}

          {:error, {:multiplicity_violation, vname, vmult, vusage}} ->
            {:error, {:multiplicity_violation, vname, vmult, vusage}}
        end
      end
    end
  end

  # Pair against Sigma.
  def check(ctx, {:pair, a, b}, {:vsigma, fst_ty, env, snd_ty}) do
    with {:ok, a_term, ctx} <- check(ctx, a, fst_ty) do
      a_val = eval_in(ctx, a_term)
      snd_ty_val = Eval.eval(make_eval_ctx(ctx, [a_val | env]), snd_ty)

      with {:ok, b_term, ctx} <- check(ctx, b, snd_ty_val) do
        {:ok, {:pair, a_term, b_term}, ctx}
      end
    end
  end

  # Let against expected type.
  def check(ctx, {:let, def_val, body}, expected) do
    with {:ok, def_term, def_type, ctx} <- synth(ctx, def_val) do
      def_val_v = eval_in(ctx, def_term)
      inner_ctx = extend_def_ctx(ctx, :_let, def_type, :omega, def_val_v)

      with {:ok, body_term, inner_ctx} <- check(inner_ctx, body, expected) do
        ctx = restore_ctx(ctx, inner_ctx)
        {:ok, {:let, def_term, body_term}, ctx}
      end
    end
  end

  # Fallback: synth and unify.
  def check(ctx, term, expected) do
    with {:ok, term, inferred, ctx} <- synth(ctx, term) do
      case Unify.unify(ctx.meta_state, Context.level(ctx.context), inferred, expected) do
        {:ok, ms} ->
          {:ok, term, %{ctx | meta_state: ms}}

        {:error, _unify_err} ->
          {:error, {:type_mismatch, expected, inferred}}
      end
    end
  end

  # ============================================================================
  # Definition checking
  # ============================================================================

  @doc """
  Check a top-level definition. The type_term is the annotated type,
  body_term is the implementation.

  Returns the zonked body and updated context after post-processing
  (hole reports, level solving).
  """
  @spec check_definition(t(), atom(), Core.expr(), Core.expr()) ::
          {:ok, Core.expr(), t()} | {:error, type_error()}
  def check_definition(ctx, name, type_term, {:global, _mod, _fun, arity} = body_term) do
    # Global cross-module reference: trust the type, validate arity.
    runtime_params = count_runtime_params(type_term)

    if runtime_params != arity do
      {:error, {:global_arity_mismatch, name, arity, runtime_params}}
    else
      type_val = eval_in(ctx, type_term)
      _def_ctx = extend_ctx(ctx, name, type_val, :omega)

      with {:ok, ctx} <- post_process(ctx) do
        {:ok, body_term, ctx}
      end
    end
  end

  def check_definition(ctx, name, type_term, {:extern, mod, fun, arity} = body_term) do
    # Extern: trust the declared type, validate arity matches.
    runtime_params = count_runtime_params(type_term)

    if runtime_params != arity do
      {:error, {:extern_arity_mismatch, name, mod, fun, arity, runtime_params}}
    else
      type_val = eval_in(ctx, type_term)
      _def_ctx = extend_ctx(ctx, name, type_val, :omega)

      with {:ok, ctx} <- post_process(ctx) do
        {:ok, body_term, ctx}
      end
    end
  end

  def check_definition(ctx, name, type_term, body_term) do
    type_val = eval_in(ctx, type_term)
    def_ctx = extend_ctx(ctx, name, type_val, :omega)

    with {:ok, checked_body, def_ctx} <- check(def_ctx, body_term, type_val) do
      ctx = restore_ctx(ctx, def_ctx)

      with {:ok, ctx} <- post_process(ctx) do
        zonked = zonk(ctx.meta_state, Context.level(ctx.context), checked_body)
        {:ok, zonked, ctx}
      end
    end
  end

  # ============================================================================
  # Post-processing
  # ============================================================================

  @doc """
  Post-definition processing: collect hole reports, check for unsolved
  implicits, solve level constraints.
  """
  @spec post_process(t()) :: {:ok, t()} | {:error, type_error()}
  def post_process(ctx) do
    ms = ctx.meta_state

    # Collect hole reports and find the first unsolved implicit.
    {hole_reports, unsolved_implicit} =
      ms.entries
      |> Enum.reduce({[], nil}, fn
        {_id, {:unsolved, type, _level, :hole}}, {reports, imp} ->
          report = %{
            span: nil,
            expected_type: Pretty.pretty(type, ctx.names, Context.level(ctx.context)),
            bindings: collect_bindings(ctx)
          }

          {[report | reports], imp}

        {id, {:unsolved, type, _level, :implicit}}, {reports, nil} ->
          {reports, {id, type}}

        _, acc ->
          acc
      end)

    ctx = %{ctx | hole_reports: Enum.reverse(hole_reports) ++ ctx.hole_reports}

    case unsolved_implicit do
      {id, type} ->
        {:error, {:unsolved_meta, id, type}}

      nil ->
        case LevelSolver.solve(ms.level_constraints) do
          {:ok, _assignments} ->
            {:ok, ctx}

          {:error, {:universe_cycle, _}} ->
            {:error, {:universe_error, "universe level constraints are unsatisfiable"}}
        end
    end
  end

  # ============================================================================
  # Zonking
  # ============================================================================

  @doc """
  Substitute all solved metas in a core term with their solutions.
  """
  @spec zonk(MetaState.t(), non_neg_integer(), Core.expr()) :: Core.expr()
  def zonk(ms, level, term)

  def zonk(ms, level, {:meta, id}) do
    case MetaState.lookup(ms, id) do
      {:solved, val} ->
        quoted = Quote.quote_untyped(level, val)
        zonk(ms, level, quoted)

      {:unsolved, _, _, _} ->
        {:meta, id}
    end
  end

  def zonk(ms, level, {:inserted_meta, id, mask}) do
    case MetaState.lookup(ms, id) do
      {:solved, val} ->
        quoted = Quote.quote_untyped(level, val)
        zonk(ms, level, quoted)

      {:unsolved, _, _, _} ->
        {:inserted_meta, id, mask}
    end
  end

  def zonk(ms, level, {:app, f, a}), do: {:app, zonk(ms, level, f), zonk(ms, level, a)}
  def zonk(ms, level, {:lam, m, body}), do: {:lam, m, zonk(ms, level + 1, body)}

  def zonk(ms, level, {:pi, m, dom, cod}),
    do: {:pi, m, zonk(ms, level, dom), zonk(ms, level + 1, cod)}

  def zonk(ms, level, {:sigma, a, b}),
    do: {:sigma, zonk(ms, level, a), zonk(ms, level + 1, b)}

  def zonk(ms, level, {:pair, a, b}), do: {:pair, zonk(ms, level, a), zonk(ms, level, b)}
  def zonk(ms, level, {:fst, e}), do: {:fst, zonk(ms, level, e)}
  def zonk(ms, level, {:snd, e}), do: {:snd, zonk(ms, level, e)}

  def zonk(ms, level, {:let, d, body}),
    do: {:let, zonk(ms, level, d), zonk(ms, level + 1, body)}

  def zonk(ms, level, {:spanned, span, inner}),
    do: {:spanned, span, zonk(ms, level, inner)}

  def zonk(_ms, _level, term), do: term

  # ============================================================================
  # Builtin types
  # ============================================================================

  @builtin_types %{
    Int: {:vtype, {:llit, 0}},
    Float: {:vtype, {:llit, 0}},
    String: {:vtype, {:llit, 0}},
    Atom: {:vtype, {:llit, 0}}
  }

  defp builtin_type(name) do
    case Map.get(@builtin_types, name) do
      nil -> builtin_op_type(name)
      type -> type
    end
  end

  # Binary: Int -> Int -> Int.
  defp builtin_op_type(name) when name in [:add, :sub, :mul, :div] do
    int = {:vbuiltin, :Int}
    {:vpi, :omega, int, [], {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}
  end

  defp builtin_op_type(name) when name in [:fadd, :fsub, :fmul, :fdiv] do
    flt = {:vbuiltin, :Float}
    {:vpi, :omega, flt, [], {:pi, :omega, {:builtin, :Float}, {:builtin, :Float}}}
  end

  defp builtin_op_type(:neg) do
    {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
  end

  defp builtin_op_type(:not) do
    {:vpi, :omega, {:vbuiltin, :Atom}, [], {:builtin, :Atom}}
  end

  defp builtin_op_type(name) when name in [:eq, :neq, :lt, :gt, :lte, :gte] do
    int = {:vbuiltin, :Int}
    {:vpi, :omega, int, [], {:pi, :omega, {:builtin, :Int}, {:builtin, :Atom}}}
  end

  defp builtin_op_type(name) when name in [:and, :or] do
    atom = {:vbuiltin, :Atom}
    {:vpi, :omega, atom, [], {:pi, :omega, {:builtin, :Atom}, {:builtin, :Atom}}}
  end

  defp builtin_op_type(_name) do
    {:vtype, {:llit, 0}}
  end

  # Count non-erased (omega) parameters in a core type.
  defp count_runtime_params({:pi, :omega, _dom, cod}), do: 1 + count_runtime_params(cod)
  defp count_runtime_params({:pi, :zero, _dom, cod}), do: count_runtime_params(cod)
  defp count_runtime_params(_), do: 0

  # Strip leading zero-multiplicity pi binders from a value type.
  # Cross-module globals have erased params excluded from their arity,
  # so callers never provide those arguments.
  defp strip_erased_pis({:vpi, :zero, _dom, env, cod}) do
    cod_val = Eval.eval(%{env: [:erased | env], metas: %{}, defs: %{}, fuel: 1000}, cod)
    strip_erased_pis(cod_val)
  end

  defp strip_erased_pis(type), do: type

  # Convert a compiled module name back to a URI.
  # E.g., MathA → "lib/math_a.hx" (assumes "lib" source root).
  defp global_module_uri(mod) do
    parts =
      mod
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)

    source_root = hd(Haruspex.source_roots())
    Path.join([source_root | parts]) <> ".hx"
  end

  # ============================================================================
  # check_is_type
  # ============================================================================

  # Synthesize a term and verify it's a Type, returning the level.
  defp check_is_type(ctx, term) do
    with {:ok, term, type, ctx} <- synth(ctx, term) do
      type = MetaState.force(ctx.meta_state, type)

      case type do
        {:vtype, level} ->
          {:ok, term, level, ctx}

        _ ->
          {:error, {:not_a_type, type}}
      end
    end
  end

  # ============================================================================
  # Context helpers
  # ============================================================================

  defp extend_ctx(ctx, name, type, mult) do
    %{ctx | context: Context.extend(ctx.context, name, type, mult), names: ctx.names ++ [name]}
  end

  defp extend_def_ctx(ctx, name, type, mult, definition) do
    %{
      ctx
      | context: Context.extend_def(ctx.context, name, type, mult, definition),
        names: ctx.names ++ [name]
    }
  end

  # Restore outer context's bindings but keep inner's meta state and hole reports.
  defp restore_ctx(outer, inner) do
    %{outer | meta_state: inner.meta_state, hole_reports: inner.hole_reports}
  end

  defp eval_in(ctx, term) do
    Eval.eval(make_eval_ctx(ctx, Context.env(ctx.context)), term)
  end

  defp make_eval_ctx(ctx, env) do
    solved =
      ctx.meta_state.entries
      |> Enum.filter(fn {_, entry} -> match?({:solved, _}, entry) end)
      |> Map.new(fn {id, {:solved, val}} -> {id, {:solved, val}} end)

    %{env: env, metas: solved, defs: %{}, fuel: 1000}
  end

  defp pick_binder_name(ctx) do
    names = [:x, :y, :z, :w, :a, :b, :c, :d]
    level = Context.level(ctx.context)
    Enum.at(names, rem(level, length(names)))
  end

  defp collect_bindings(ctx) do
    ctx.context.bindings
    |> Enum.reverse()
    |> Enum.map(fn binding ->
      type_str = Pretty.pretty(binding.type, ctx.names, Context.level(ctx.context))
      {binding.name, type_str}
    end)
  end
end
