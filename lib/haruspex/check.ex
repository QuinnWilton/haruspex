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
  defstruct [
    :context,
    :names,
    :meta_state,
    :db,
    :uri,
    hole_reports: [],
    adts: %{},
    records: %{},
    classes: %{},
    instances: %{},
    class_param_metas: %{},
    total_defs: %{},
    fuel: 1000
  ]

  @type t :: %__MODULE__{
          context: Context.t(),
          names: [atom()],
          meta_state: MetaState.t(),
          db: term() | nil,
          uri: String.t() | nil,
          hole_reports: [hole_report()],
          adts: %{atom() => Haruspex.ADT.adt_decl()},
          records: %{atom() => Haruspex.Record.record_decl()},
          classes: %{atom() => Haruspex.TypeClass.class_decl()},
          instances: Haruspex.TypeClass.Search.instance_db(),
          class_param_metas: %{non_neg_integer() => atom()},
          total_defs: %{atom() => {Haruspex.Core.expr(), boolean()}},
          fuel: non_neg_integer()
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
  def synth(ctx, {:lit, true}), do: {:ok, {:lit, true}, {:vbuiltin, :Bool}, ctx}
  def synth(ctx, {:lit, false}), do: {:ok, {:lit, false}, {:vbuiltin, :Bool}, ctx}
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
  # Inserts fresh metas for leading zero-multiplicity (implicit) Pi binders
  # so that explicit arguments align with explicit Pi parameters.
  def synth(ctx, {:app, f, a}) do
    with {:ok, f_term, f_type, ctx} <- synth(ctx, f) do
      f_type = Eval.whnf(make_eval_ctx(ctx, []), f_type)

      # Peel implicit Pi's, wrapping f_term in applications to the inserted metas.
      {f_type, f_term, ctx} = peel_implicit_apps(ctx, f_type, f_term)

      case f_type do
        {:vpi, _mult, dom, env, cod} ->
          with {:ok, a_term, ctx} <- check(ctx, a, dom) do
            a_val = eval_in(ctx, a_term)
            cod_val = Eval.eval(make_eval_ctx(ctx, [a_val | env]), cod)
            # Resolve metas that were solved during arg checking but are
            # stale in the closure-captured env.
            cod_val = Eval.whnf(make_eval_ctx(ctx, []), cod_val)
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
      e_type = Eval.whnf(make_eval_ctx(ctx, []), e_type)

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
      e_type = Eval.whnf(make_eval_ctx(ctx, []), e_type)

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

  # ADT type constructor.
  def synth(ctx, {:data, name, args}) do
    case Map.fetch(ctx.adts, name) do
      {:ok, decl} ->
        # Check each arg and build the applied data type.
        {arg_terms, ctx} =
          Enum.reduce(args, {[], ctx}, fn arg, {acc, ctx} ->
            case synth(ctx, arg) do
              {:ok, term, _type, ctx} -> {[term | acc], ctx}
            end
          end)

        arg_terms = Enum.reverse(arg_terms)
        {:ok, {:data, name, arg_terms}, {:vtype, decl.universe_level}, ctx}

      :error ->
        # Unknown ADT — treat as Type 0 if not registered.
        {:ok, {:data, name, args}, {:vtype, {:llit, 0}}, ctx}
    end
  end

  # Data constructor.
  def synth(ctx, {:con, type_name, con_name, args}) do
    case Map.fetch(ctx.adts, type_name) do
      {:ok, decl} ->
        con_type_core = Haruspex.ADT.constructor_type(decl, con_name)
        con_type_val = eval_in(ctx, con_type_core)

        # Insert fresh metas for zero-multiplicity (implicit) params when
        # only explicit field args are provided (elaboration doesn't insert
        # implicits). Skip if args already include the implicit params.
        con = Enum.find(decl.constructors, &(&1.name == con_name))
        n_fields = if con, do: length(con.fields), else: length(args)

        {con_type_val, _implicit_args, ctx} =
          if length(args) <= n_fields do
            peel_implicit_pis(ctx, con_type_val)
          else
            {con_type_val, [], ctx}
          end

        {checked_args, result_type, ctx} =
          Enum.reduce(args, {[], con_type_val, ctx}, fn arg, {acc, fun_type, ctx} ->
            fun_type = Eval.whnf(make_eval_ctx(ctx, []), fun_type)

            case fun_type do
              {:vpi, _mult, dom, env, cod} ->
                dom = Eval.whnf(make_eval_ctx(ctx, []), dom)

                case check(ctx, arg, dom) do
                  {:ok, arg_term, ctx} ->
                    arg_val = eval_in(ctx, arg_term)
                    cod_val = Eval.eval(make_eval_ctx(ctx, [arg_val | env]), cod)
                    cod_val = Eval.whnf(make_eval_ctx(ctx, []), cod_val)
                    {[arg_term | acc], cod_val, ctx}
                end

              _ ->
                # Overapplied? Just accumulate.
                case synth(ctx, arg) do
                  {:ok, arg_term, _type, ctx} -> {[arg_term | acc], fun_type, ctx}
                end
            end
          end)

        # Output only the original args (excluding inserted implicit metas)
        # since implicit type params are erased at runtime.
        {:ok, {:con, type_name, con_name, Enum.reverse(checked_args)}, result_type, ctx}

      :error ->
        # Unknown ADT — synthesize args structurally.
        {checked_args, ctx} =
          Enum.reduce(args, {[], ctx}, fn arg, {acc, ctx} ->
            case synth(ctx, arg) do
              {:ok, term, _type, ctx} -> {[term | acc], ctx}
            end
          end)

        {:ok, {:con, type_name, con_name, Enum.reverse(checked_args)}, {:vdata, type_name, []},
         ctx}
    end
  end

  # Record projection: desugar to case expression.
  def synth(ctx, {:record_proj, field_name, expr}) do
    with {:ok, expr_term, expr_type, ctx} <- synth(ctx, expr) do
      forced = Eval.whnf(make_eval_ctx(ctx, []), expr_type)

      case record_proj_desugar(ctx, field_name, expr_term, forced) do
        {:ok, case_term, field_type} ->
          {:ok, case_term, field_type, ctx}

        :error ->
          {:error, {:not_a_record, forced, field_name}}
      end
    end
  end

  # Case expression.
  def synth(ctx, {:case, scrutinee, branches}) do
    with {:ok, scrut_term, scrut_type, ctx} <- synth(ctx, scrutinee) do
      forced_scrut_type = Eval.whnf(make_eval_ctx(ctx, []), scrut_type)

      # Type check each branch with refined field types.
      {checked_branches, result_type, ctx} =
        Enum.reduce(branches, {[], nil, ctx}, fn branch, {acc, ret_type, ctx} ->
          {inner_ctx, branch_head, _index_equations} =
            extend_branch_ctx(ctx, forced_scrut_type, branch)

          body = elem(branch, tuple_size(branch) - 1)

          case synth(inner_ctx, body) do
            {:ok, body_term, body_type, inner_ctx} ->
              ctx = restore_ctx(ctx, inner_ctx)

              ret =
                if ret_type == nil do
                  body_type
                else
                  ret_type
                end

              checked = put_elem(branch_head, tuple_size(branch_head) - 1, body_term)
              {[checked | acc], ret, ctx}
          end
        end)

      # Exhaustiveness checking (warnings only, GADT-aware).
      _exhaust =
        Haruspex.Pattern.check_exhaustiveness(
          ctx.adts,
          forced_scrut_type,
          branches,
          ctx.meta_state,
          Context.level(ctx.context)
        )

      result_type = result_type || {:vtype, {:llit, 0}}
      {:ok, {:case, scrut_term, Enum.reverse(checked_branches)}, result_type, ctx}
    end
  end

  # Definition reference: look up type from database.
  def synth(ctx, {:def_ref, name}) do
    if ctx.db do
      case synth_def_ref(ctx, name) do
        {:ok, _, _, _} = result -> result
        :error -> {:error, {:unbound_variable, name, nil}}
      end
    else
      {:error, {:unbound_variable, name, nil}}
    end
  end

  # Builtin type: check if it's a class method first for polymorphic resolution.
  def synth(ctx, {:builtin, name}) do
    case find_class_method(ctx.classes, name) do
      {:ok, class_name} ->
        synth_class_builtin(ctx, name, class_name)

      :error ->
        type = builtin_type(name)
        {:ok, {:builtin, name}, type, ctx}
    end
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

  # Case expression against a known expected type.
  # For GADT branches, index equations refine the expected type per branch
  # so that type-level functions (e.g., add) can reduce.
  def check(ctx, {:case, scrutinee, branches}, expected) do
    with {:ok, scrut_term, scrut_type, ctx} <- synth(ctx, scrutinee) do
      forced_scrut_type = Eval.whnf(make_eval_ctx(ctx, []), scrut_type)

      # Type check each branch with refined expected types.
      {checked_branches, ctx} =
        Enum.reduce(branches, {[], ctx}, fn branch, {acc, ctx} ->
          {inner_ctx, branch_head, index_equations} =
            extend_branch_ctx(ctx, forced_scrut_type, branch)

          # For GADT branches with index equations (e.g., n = zero in vnil),
          # substitute the learned equalities into the expected type so
          # type-level functions reduce. Otherwise use the expected type as-is.
          branch_expected =
            if index_equations != [] do
              apply_index_equations(inner_ctx, expected, index_equations)
            else
              expected
            end

          body = elem(branch, tuple_size(branch) - 1)

          case check(inner_ctx, body, branch_expected) do
            {:ok, body_term, inner_ctx} ->
              ctx = restore_ctx(ctx, inner_ctx)
              checked = put_elem(branch_head, tuple_size(branch_head) - 1, body_term)
              {[checked | acc], ctx}
          end
        end)

      # Exhaustiveness checking (warnings only, GADT-aware).
      _exhaust =
        Haruspex.Pattern.check_exhaustiveness(
          ctx.adts,
          forced_scrut_type,
          branches,
          ctx.meta_state,
          Context.level(ctx.context)
        )

      {:ok, {:case, scrut_term, Enum.reverse(checked_branches)}, ctx}
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

  @doc """
  Check a definition that belongs to a mutual group.

  All mutual siblings' types are added to the context before checking the body,
  so cross-recursive references type-check correctly.
  """
  @spec check_mutual_definition(
          t(),
          atom(),
          Core.expr(),
          Core.expr(),
          [{atom(), Core.expr()}]
        ) :: {:ok, Core.expr(), t()} | {:error, type_error()}
  def check_mutual_definition(ctx, _name, type_term, body_term, all_sigs) do
    # Extend context with all mutual names (in order).
    mutual_ctx =
      Enum.reduce(all_sigs, ctx, fn {sig_name, sig_type}, acc ->
        type_val = eval_in(acc, sig_type)
        extend_ctx(acc, sig_name, type_val, :omega)
      end)

    type_val = eval_in(mutual_ctx, type_term)

    with {:ok, checked_body, mutual_ctx} <- check(mutual_ctx, body_term, type_val) do
      ctx = restore_ctx(ctx, mutual_ctx)

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
        # Validate class parameter metas: check that solved class params have instances.
        case validate_class_params(ctx) do
          :ok ->
            case LevelSolver.solve(ms.level_constraints) do
              {:ok, _assignments} ->
                {:ok, ctx}

              {:error, {:universe_cycle, _}} ->
                {:error, {:universe_error, "universe level constraints are unsatisfiable"}}
            end

          {:error, _} = err ->
            err
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

  def zonk(ms, level, {:data, name, args}),
    do: {:data, name, Enum.map(args, &zonk(ms, level, &1))}

  def zonk(ms, level, {:con, type_name, con_name, args}),
    do: {:con, type_name, con_name, Enum.map(args, &zonk(ms, level, &1))}

  def zonk(ms, level, {:record_proj, field, expr}),
    do: {:record_proj, field, zonk(ms, level, expr)}

  def zonk(_ms, _level, {:def_ref, _} = term), do: term

  def zonk(ms, level, {:case, scrutinee, branches}),
    do:
      {:case, zonk(ms, level, scrutinee),
       Enum.map(branches, fn
         {:__lit, value, body} ->
           {:__lit, value, zonk(ms, level, body)}

         {cn, arity, body} ->
           {cn, arity, zonk(ms, level + arity, body)}
       end)}

  def zonk(_ms, _level, term), do: term

  # ============================================================================
  # Builtin types
  # ============================================================================

  @builtin_types %{
    Int: {:vtype, {:llit, 0}},
    Float: {:vtype, {:llit, 0}},
    String: {:vtype, {:llit, 0}},
    Atom: {:vtype, {:llit, 0}},
    Bool: {:vtype, {:llit, 0}}
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
    {:vpi, :omega, {:vbuiltin, :Bool}, [], {:builtin, :Bool}}
  end

  defp builtin_op_type(name) when name in [:eq, :neq, :lt, :gt, :lte, :gte] do
    int = {:vbuiltin, :Int}
    {:vpi, :omega, int, [], {:pi, :omega, {:builtin, :Int}, {:builtin, :Bool}}}
  end

  defp builtin_op_type(name) when name in [:and, :or] do
    bool = {:vbuiltin, :Bool}
    {:vpi, :omega, bool, [], {:pi, :omega, {:builtin, :Bool}, {:builtin, :Bool}}}
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
  # Record projection desugaring
  # ============================================================================

  # Desugar `record_proj(field, expr)` into a case expression that extracts the field.
  # Returns `{:ok, case_term, field_type}` or `:error`.
  defp record_proj_desugar(ctx, field_name, expr_term, {:vdata, type_name, type_args}) do
    case Map.fetch(ctx.records, type_name) do
      {:ok, record_decl} ->
        case Haruspex.Record.field_info(record_decl, field_name) do
          {:ok, field_idx, field_type_core} ->
            arity = length(record_decl.fields)

            # Build: case expr do mk_R(f0, f1, ...) -> f<idx> end
            # The body references the field at de Bruijn index (arity - 1 - field_idx).
            body = {:var, arity - 1 - field_idx}

            case_term =
              {:case, expr_term, [{record_decl.constructor_name, arity, body}]}

            # Evaluate the field type with type args substituted.
            param_env = Enum.reverse(type_args)
            eval_ctx = make_eval_ctx(ctx, param_env)
            field_type = Eval.eval(eval_ctx, field_type_core)

            {:ok, case_term, field_type}

          :error ->
            :error
        end

      :error ->
        :error
    end
  end

  defp record_proj_desugar(_ctx, _field_name, _expr_term, _type), do: :error

  # ============================================================================
  # Case branch context extension
  # ============================================================================

  # GADT Checking
  #
  # For each constructor branch, we create fresh metas for the ADT's type params
  # and unify the constructor's return type against the (relaxed) scrutinee type.
  # Neutral index args in the scrutinee are replaced with fresh metas so that
  # unification can learn index equations (e.g., n = zero in a vnil branch).
  # If unification fails, the branch is impossible and gets placeholder types.
  # Solved index equations are threaded back to refine the expected type via
  # substitution, allowing type-level computation to reduce in each branch.

  # Literal branch: 0 binders, no index equations.
  defp extend_branch_ctx(ctx, _scrut_type, {:__lit, value, _body}) do
    {ctx, {:__lit, value, nil}, []}
  end

  # Wildcard with 0 binders.
  defp extend_branch_ctx(ctx, _scrut_type, {:_, 0, _body}) do
    {ctx, {:_, 0, nil}, []}
  end

  # Wildcard with 1 binder: bind scrutinee with its type.
  defp extend_branch_ctx(ctx, scrut_type, {:_, 1, _body}) do
    {extend_ctx(ctx, :_match, scrut_type, :omega), {:_, 1, nil}, []}
  end

  # Constructor branch: use GADT-aware field type refinement.
  defp extend_branch_ctx(ctx, scrut_type, {con_name, arity, _body}) do
    case gadt_branch_ctx(ctx, scrut_type, con_name, arity) do
      {:ok, field_types, updated_ctx, index_equations} ->
        inner_ctx =
          Enum.reduce(field_types, updated_ctx, fn field_type, c ->
            extend_ctx(c, :_field, field_type, :omega)
          end)

        {inner_ctx, {con_name, arity, nil}, index_equations}

      :impossible ->
        # Branch is unreachable — placeholder types are safe since the body is dead code.
        inner_ctx =
          Enum.reduce(1..arity//1, ctx, fn _, c ->
            extend_ctx(c, :_field, {:vtype, {:llit, 0}}, :omega)
          end)

        {inner_ctx, {con_name, arity, nil}, []}

      :error ->
        # Non-ADT scrutinee or unknown constructor — use placeholder types as fallback.
        inner_ctx =
          Enum.reduce(1..arity//1, ctx, fn _, c ->
            extend_ctx(c, :_field, {:vtype, {:llit, 0}}, :omega)
          end)

        {inner_ctx, {con_name, arity, nil}, []}
    end
  end

  # GADT-aware branch context: create fresh metas for type params, unify the
  # constructor's return type with the scrutinee type, and extract refined
  # field types from the solved metas.
  #
  # Neutral type-index args in the scrutinee are "relaxed" to fresh metas so
  # that GADT unification can succeed even when the scrutinee has parametric
  # indices (e.g., Vec(Int, n) where n is a free variable). The learned
  # index equations (e.g., n = zero) are returned for refining the expected type.
  #
  # Returns {:ok, field_types, updated_ctx, index_equations} on success,
  # :impossible when the constructor can't match, or :error for non-ADT.
  defp gadt_branch_ctx(ctx, {:vdata, type_name, type_args} = _scrut_type, con_name, arity) do
    with {:ok, decl} <- Map.fetch(ctx.adts, type_name),
         con when con != nil <- Enum.find(decl.constructors, &(&1.name == con_name)),
         true <- length(con.fields) == arity do
      original_ms = ctx.meta_state
      lvl = Context.level(ctx.context)

      # Replace neutral type-index args with fresh metas so unification can
      # learn index equations (e.g., n = zero in the vnil branch).
      {relaxed_scrut, index_meta_map, ms} =
        relax_neutral_indices({:vdata, type_name, type_args}, original_ms, lvl)

      # Create fresh metas for each type parameter, evaluating kinds
      # incrementally under the partial env built so far.
      {rev_meta_vals, ms} =
        Enum.reduce(decl.params, {[], ms}, fn {_name, kind_core}, {acc, ms} ->
          # acc is already in de Bruijn env order (most recent at head).
          eval_ctx = make_eval_ctx(%{ctx | meta_state: ms}, acc)
          kind_val = Eval.eval(eval_ctx, kind_core)

          {id, ms} = MetaState.fresh_meta(ms, kind_val, lvl, :gadt)
          meta_val = {:vneutral, kind_val, {:nmeta, id}}

          {[meta_val | acc], ms}
        end)

      # de Bruijn env: most recent binding at head (rev_meta_vals is already in this order).
      param_env = rev_meta_vals

      # Evaluate the constructor's return type under the fresh meta env.
      return_type_core = con.return_type || Haruspex.ADT.default_return_type(decl)
      eval_ctx = make_eval_ctx(%{ctx | meta_state: ms}, param_env)
      return_type_val = Eval.eval(eval_ctx, return_type_core)

      # Unify with the relaxed scrutinee type to solve index variables.
      case Unify.unify(ms, lvl, return_type_val, relaxed_scrut) do
        {:ok, solved_ms} ->
          # Extract index equations: nvar_level → solved value.
          index_equations =
            Enum.flat_map(index_meta_map, fn {nvar_level, meta_id} ->
              case MetaState.lookup(solved_ms, meta_id) do
                {:solved, val} -> [{nvar_level, val}]
                _ -> []
              end
            end)

          # Force param env to resolve metas solved by unification, then
          # evaluate field types under the resolved env.
          updated_ctx = %{ctx | meta_state: solved_ms}
          whnf_ctx = make_eval_ctx(updated_ctx, [])

          forced_env =
            Enum.map(param_env, fn v -> Eval.whnf(whnf_ctx, v) end)

          eval_ctx = make_eval_ctx(updated_ctx, forced_env)

          field_types =
            Enum.map(con.fields, fn field_core ->
              Eval.eval(eval_ctx, field_core)
            end)

          {:ok, field_types, updated_ctx, index_equations}

        {:error, _} ->
          :impossible
      end
    else
      _ -> :error
    end
  end

  defp gadt_branch_ctx(_ctx, _scrut_type, _con_name, _arity), do: :error

  # Replace neutral variable args in an ADT type with fresh metas.
  # Returns the relaxed type, a map of {nvar_level, meta_id}, and updated meta state.
  defp relax_neutral_indices({:vdata, type_name, type_args}, ms, lvl) do
    {rev_relaxed_args, index_meta_map, ms} =
      Enum.reduce(type_args, {[], [], ms}, fn
        {:vneutral, type, {:nvar, var_level}}, {args, metas, ms} ->
          {id, ms} = MetaState.fresh_meta(ms, type, lvl, :gadt)
          meta_val = {:vneutral, type, {:nmeta, id}}
          {[meta_val | args], [{var_level, id} | metas], ms}

        arg, {args, metas, ms} ->
          {[arg | args], metas, ms}
      end)

    relaxed_args = Enum.reverse(rev_relaxed_args)
    {{:vdata, type_name, relaxed_args}, index_meta_map, ms}
  end

  # Apply GADT index equations to the expected type. Quotes the expected value
  # and evaluates it under a modified env where neutral vars are replaced by
  # the values learned from GADT unification. This allows type-level functions
  # like add(n, m) to reduce when n is known (e.g., n = zero in vnil branch).
  defp apply_index_equations(ctx, expected, index_equations) do
    lvl = Context.level(ctx.context)
    env = Context.env(ctx.context)

    modified_env =
      Enum.reduce(index_equations, env, fn {var_level, value}, env ->
        index = lvl - var_level - 1
        List.replace_at(env, index, value)
      end)

    expected_core = Quote.quote_untyped(lvl, expected)

    eval_ctx = make_eval_ctx(ctx, modified_env)
    Eval.eval(eval_ctx, expected_core)
  end

  # ============================================================================
  # check_is_type
  # ============================================================================

  # Synthesize a term and verify it's a Type, returning the level.
  defp check_is_type(ctx, term) do
    with {:ok, term, type, ctx} <- synth(ctx, term) do
      type = Eval.whnf(make_eval_ctx(ctx, []), type)

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

  # Restore outer context's bindings but keep inner's meta state, hole reports,
  # and class param meta tracking.
  defp restore_ctx(outer, inner) do
    %{
      outer
      | meta_state: inner.meta_state,
        hole_reports: inner.hole_reports,
        class_param_metas: inner.class_param_metas
    }
  end

  # Peel off leading zero-multiplicity (implicit) Pi binders from a function
  # type, wrapping the function term in applications to fresh metas. Used for
  # function application when the caller provides only explicit arguments.
  defp peel_implicit_apps(ctx, type, f_term) do
    type = Eval.whnf(make_eval_ctx(ctx, []), type)

    case type do
      {:vpi, :zero, dom, env, cod} ->
        lvl = Context.level(ctx.context)
        {id, ms} = MetaState.fresh_meta(ctx.meta_state, dom, lvl, :implicit)
        meta_val = {:vneutral, dom, {:nmeta, id}}
        ctx = %{ctx | meta_state: ms}
        cod_val = Eval.eval(make_eval_ctx(ctx, [meta_val | env]), cod)
        peel_implicit_apps(ctx, cod_val, {:app, f_term, {:meta, id}})

      _ ->
        {type, f_term, ctx}
    end
  end

  # Peel off leading zero-multiplicity (implicit) Pi binders by inserting
  # fresh metas. Returns the remaining type, the accumulated meta args (in
  # reverse order for the reduce accumulator), and updated context.
  defp peel_implicit_pis(ctx, type) do
    type = Eval.whnf(make_eval_ctx(ctx, []), type)

    case type do
      {:vpi, :zero, dom, env, cod} ->
        lvl = Context.level(ctx.context)
        # Use :gadt kind — constructor implicit metas may go unsolved for
        # unused params (e.g., n in vnil) and should not trigger errors.
        {id, ms} = MetaState.fresh_meta(ctx.meta_state, dom, lvl, :gadt)
        meta_val = {:vneutral, dom, {:nmeta, id}}
        ctx = %{ctx | meta_state: ms}
        cod_val = Eval.eval(make_eval_ctx(ctx, [meta_val | env]), cod)
        {cod_val, acc, ctx} = peel_implicit_pis(ctx, cod_val)
        {cod_val, [{:meta, id} | acc], ctx}

      _ ->
        {type, [], ctx}
    end
  end

  defp eval_in(ctx, term) do
    Eval.eval(make_eval_ctx(ctx, Context.env(ctx.context)), term)
  end

  defp make_eval_ctx(ctx, env) do
    %{
      env: env,
      metas: MetaState.solved_entries(ctx.meta_state),
      defs: ctx.total_defs,
      fuel: ctx.fuel
    }
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

  # ============================================================================
  # Internal — def_ref synthesis
  # ============================================================================

  # Synthesize the type of a same-file definition reference.
  defp synth_def_ref(ctx, name) do
    uri = ctx.uri

    if uri do
      case Roux.Runtime.query(ctx.db, :haruspex_elaborate, {uri, name}) do
        {:ok, {type_core, _body}} ->
          type_val = eval_in(ctx, type_core)
          {:ok, {:def_ref, name}, type_val, ctx}

        _ ->
          :error
      end
    else
      :error
    end
  end

  # ============================================================================
  # Internal — class param instance validation
  # ============================================================================

  # After checking, verify that solved class parameter metas have valid instances.
  # For example, if `{:builtin, :add}` was typed as `?a -> ?a -> ?a` and `?a`
  # solved to `String`, we check that `Num(String)` exists — and error if not.
  defp validate_class_params(ctx) do
    ms = ctx.meta_state

    Enum.reduce_while(ctx.class_param_metas, :ok, fn {meta_id, class_name}, :ok ->
      case Map.get(ms.entries, meta_id) do
        {:solved, val} ->
          search_ms = MetaState.new()
          goal = {class_name, [val]}

          case Haruspex.TypeClass.Search.search(ctx.instances, ctx.classes, search_ms, 0, goal) do
            {:found, _, _} -> {:cont, :ok}
            _ -> {:halt, {:error, {:no_instance, class_name, val}}}
          end

        {:unsolved, _, _, _} ->
          # Unsolved — will be caught by the unsolved implicit check.
          {:cont, :ok}

        nil ->
          {:cont, :ok}
      end
    end)
  end

  # ============================================================================
  # Internal — class method resolution
  # ============================================================================

  # Find which class a method belongs to.
  defp find_class_method(classes, method_name) do
    Enum.find_value(classes, :error, fn {class_name, decl} ->
      if Enum.any?(decl.methods, fn {name, _} -> name == method_name end) do
        {:ok, class_name}
      end
    end)
  end

  # Synthesize a polymorphic type for a builtin that's a class method.
  # Creates a fresh meta for the class type parameter and returns the
  # method type with the meta substituted. The meta is tagged with
  # :class_param kind so post_process can validate instance existence.
  defp synth_class_builtin(ctx, method_name, class_name) do
    class_decl = Map.fetch!(ctx.classes, class_name)
    {:ok, method_type_core} = Haruspex.TypeClass.method_type(class_decl, method_name)

    # Create a fresh meta for the class type parameter.
    lvl = Context.level(ctx.context)
    {meta_id, ms} = MetaState.fresh_meta(ctx.meta_state, {:vtype, {:llit, 0}}, lvl, :implicit)

    ctx = %{
      ctx
      | meta_state: ms,
        class_param_metas: Map.put(ctx.class_param_metas, meta_id, class_name)
    }

    meta_val = {:vneutral, {:vtype, {:llit, 0}}, {:nmeta, meta_id}}

    # Evaluate the method type with the meta as the class param (var 0).
    eval_ctx = make_eval_ctx(ctx, [meta_val])
    method_type_val = Eval.eval(eval_ctx, method_type_core)

    {:ok, {:builtin, method_name}, method_type_val, ctx}
  end
end
