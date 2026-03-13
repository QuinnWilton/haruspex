defmodule Haruspex.Elaborate do
  @moduledoc """
  Surface AST to core term elaboration.

  Transforms surface AST nodes (with names) into core terms (with de Bruijn
  indices), resolving names, desugaring operators, and creating metavariables
  for holes. Threads an elaboration context that tracks bindings, meta state,
  and accumulated hole information.
  """

  alias Haruspex.Core
  alias Haruspex.Unify.MetaState

  # ============================================================================
  # Types
  # ============================================================================

  @type hole_info :: %{
          meta_id: Core.meta_id(),
          span: Pentiment.Span.Byte.t(),
          level: non_neg_integer()
        }

  @type elab_error ::
          {:unbound_variable, atom(), Pentiment.Span.Byte.t()}
          | {:unsupported, atom(), Pentiment.Span.Byte.t()}
          | {:missing_return_type, atom(), Pentiment.Span.Byte.t()}

  @enforce_keys [
    :names,
    :name_list,
    :level,
    :meta_state,
    :holes,
    :auto_implicits,
    :next_level_var,
    :prelude,
    :db,
    :uri,
    :imports,
    :source_roots,
    :adts,
    :records
  ]
  defstruct [
    :names,
    :name_list,
    :level,
    :meta_state,
    :holes,
    :auto_implicits,
    :next_level_var,
    :prelude,
    :db,
    :uri,
    :imports,
    :source_roots,
    :adts,
    :records
  ]

  @type import_info :: %{
          module_path: [atom()],
          open: boolean() | [atom()] | nil
        }

  @type t :: %__MODULE__{
          names: [{atom(), non_neg_integer()}],
          name_list: [atom()],
          level: non_neg_integer(),
          meta_state: MetaState.t(),
          holes: [hole_info()],
          auto_implicits: %{atom() => term()},
          next_level_var: non_neg_integer(),
          prelude: %{atom() => {:builtin, atom()}},
          db: term() | nil,
          uri: String.t() | nil,
          imports: [import_info()],
          source_roots: [String.t()],
          adts: %{atom() => Haruspex.ADT.adt_decl()},
          records: %{atom() => Haruspex.Record.record_decl()}
        }

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create an empty elaboration context.

  Accepts an optional keyword list with `:db`, `:uri`, `:imports`,
  `:source_roots`, and `:no_prelude?` for cross-module resolution and
  prelude configuration. When omitted, import resolution is disabled
  (standalone elaboration) and the prelude is loaded by default.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    no_prelude? = Keyword.get(opts, :no_prelude?, false)
    prelude = if no_prelude?, do: %{}, else: Haruspex.Prelude.builtins()

    %__MODULE__{
      names: [],
      name_list: [],
      level: 0,
      meta_state: MetaState.new(),
      holes: [],
      auto_implicits: %{},
      next_level_var: 0,
      prelude: prelude,
      db: Keyword.get(opts, :db),
      uri: Keyword.get(opts, :uri),
      imports: Keyword.get(opts, :imports, []),
      source_roots: Keyword.get(opts, :source_roots, []),
      adts: Keyword.get(opts, :adts, %{}),
      records: Keyword.get(opts, :records, %{})
    }
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Elaborate a surface expression into a core term.
  """
  @spec elaborate(t(), term()) :: {:ok, Core.expr(), t()} | {:error, elab_error()}
  def elaborate(ctx, {:var, span, name}) do
    case resolve_name(ctx, name) do
      {:builtin, core} -> {:ok, core, ctx}
      {:bound, ix} -> {:ok, {:var, ix}, ctx}
      {:global, core} -> {:ok, core, ctx}
      {:constructor, type_name, con_name} -> {:ok, {:con, type_name, con_name, []}, ctx}
      {:adt_type, type_name} -> {:ok, {:data, type_name, []}, ctx}
      :not_found -> {:error, {:unbound_variable, name, span}}
    end
  end

  def elaborate(ctx, {:lit, _span, value}) do
    {:ok, {:lit, value}, ctx}
  end

  def elaborate(ctx, {:app, _span, func, args}) do
    with {:ok, func_core, ctx} <- elaborate(ctx, func) do
      case func_core do
        {:con, type_name, con_name, []} ->
          # Constructor application: elaborate args and build a Con term.
          elaborate_con_args(ctx, type_name, con_name, args)

        {:data, type_name, []} ->
          # ADT type application: e.g., Option(Int).
          elaborate_data_args(ctx, type_name, args)

        _ ->
          elaborate_app_args(ctx, func_core, args)
      end
    end
  end

  def elaborate(ctx, {:fn, _span, params, body}) do
    elaborate_lambda(ctx, params, body)
  end

  def elaborate(ctx, {:let, _span, name, value, body}) do
    with {:ok, val_core, ctx} <- elaborate(ctx, value) do
      inner_ctx = push_binding(ctx, name)

      with {:ok, body_core, inner_ctx} <- elaborate(inner_ctx, body) do
        # Propagate meta state changes back, but restore binding depth.
        ctx = restore_bindings(ctx, inner_ctx)
        {:ok, {:let, val_core, body_core}, ctx}
      end
    end
  end

  def elaborate(ctx, {:binop, _span, op, left, right}) do
    with {:ok, left_core, ctx} <- elaborate(ctx, left),
         {:ok, right_core, ctx} <- elaborate(ctx, right) do
      {:ok, {:app, {:app, {:builtin, op}, left_core}, right_core}, ctx}
    end
  end

  def elaborate(ctx, {:unaryop, _span, op, expr}) do
    with {:ok, expr_core, ctx} <- elaborate(ctx, expr) do
      {:ok, {:app, {:builtin, op}, expr_core}, ctx}
    end
  end

  def elaborate(ctx, {:pipe, _span, left, right}) do
    with {:ok, left_core, ctx} <- elaborate(ctx, left),
         {:ok, right_core, ctx} <- elaborate(ctx, right) do
      {:ok, {:app, right_core, left_core}, ctx}
    end
  end

  def elaborate(ctx, {:ann, _span, expr, type}) do
    with {:ok, expr_core, ctx} <- elaborate(ctx, expr),
         {:ok, _type_core, ctx} <- elaborate_type(ctx, type) do
      {:ok, expr_core, ctx}
    end
  end

  def elaborate(ctx, {:hole, span}) do
    placeholder_type = {:vtype, {:llit, 0}}
    {id, ms} = MetaState.fresh_meta(ctx.meta_state, placeholder_type, ctx.level, :hole)

    hole = %{meta_id: id, span: span, level: ctx.level}
    ctx = %{ctx | meta_state: ms, holes: [hole | ctx.holes]}

    {:ok, {:meta, id}, ctx}
  end

  def elaborate(ctx, {:dot, span, {:var, _var_span, module_name}, field_name}) do
    # Check if this is a local binding first — if so, treat as record projection.
    case resolve_name(ctx, module_name) do
      {:bound, ix} ->
        {:ok, {:record_proj, field_name, {:var, ix}}, ctx}

      _ ->
        # Not a local binding — try qualified module access.
        resolve_qualified(ctx, [module_name], field_name, span)
    end
  end

  def elaborate(ctx, {:dot, _span, target, field_name}) do
    # Non-variable dot target: always record projection.
    with {:ok, target_core, ctx} <- elaborate(ctx, target) do
      {:ok, {:record_proj, field_name, target_core}, ctx}
    end
  end

  def elaborate(ctx, {:record_construct, span, record_name, field_assignments}) do
    elaborate_record_construct(ctx, record_name, field_assignments, span)
  end

  def elaborate(ctx, {:record_update, span, record_name, target, field_updates}) do
    elaborate_record_update(ctx, record_name, target, field_updates, span)
  end

  def elaborate(ctx, {:case, _span, scrutinee, branches}) do
    with {:ok, scrut_core, ctx} <- elaborate(ctx, scrutinee) do
      elaborate_case_branches(ctx, scrut_core, branches)
    end
  end

  def elaborate(ctx, {:with, _span, scrutinees, branches}) do
    elaborate_with(ctx, scrutinees, branches)
  end

  def elaborate(ctx, {:if, _span, cond_expr, then_branch, else_branch}) do
    # Desugar: if c then a else b → case c do true -> a; false -> b end
    with {:ok, cond_core, ctx} <- elaborate(ctx, cond_expr) do
      elaborate_case_branches(ctx, cond_core, [
        {:branch, nil, {:pat_lit, nil, true}, then_branch},
        {:branch, nil, {:pat_lit, nil, false}, else_branch}
      ])
    end
  end

  # Fall through to type elaboration for type-like expressions used as terms.
  def elaborate(ctx, {:pi, _, _, _, _} = node), do: elaborate_type(ctx, node)
  def elaborate(ctx, {:sigma, _, _, _, _} = node), do: elaborate_type(ctx, node)
  def elaborate(ctx, {:type_universe, _, _} = node), do: elaborate_type(ctx, node)

  @doc """
  Elaborate a surface type expression into a core term.
  """
  @spec elaborate_type(t(), term()) :: {:ok, Core.expr(), t()} | {:error, elab_error()}
  def elaborate_type(ctx, {:pi, _span, {name, mult, implicit?}, domain, codomain}) do
    # Implicit binders use :zero multiplicity to mark erasure.
    core_mult = if implicit?, do: :zero, else: mult

    with {:ok, dom_core, ctx} <- elaborate_type(ctx, domain) do
      inner_ctx = push_binding(ctx, name)

      with {:ok, cod_core, inner_ctx} <- elaborate_type(inner_ctx, codomain) do
        ctx = restore_bindings(ctx, inner_ctx)
        {:ok, {:pi, core_mult, dom_core, cod_core}, ctx}
      end
    end
  end

  def elaborate_type(ctx, {:sigma, _span, name, fst_type, snd_type}) do
    with {:ok, fst_core, ctx} <- elaborate_type(ctx, fst_type) do
      inner_ctx = push_binding(ctx, name)

      with {:ok, snd_core, inner_ctx} <- elaborate_type(inner_ctx, snd_type) do
        ctx = restore_bindings(ctx, inner_ctx)
        {:ok, {:sigma, fst_core, snd_core}, ctx}
      end
    end
  end

  def elaborate_type(ctx, {:type_universe, _span, nil}) do
    # Fresh universe level variable.
    id = ctx.next_level_var
    ctx = %{ctx | next_level_var: id + 1}
    {:ok, {:type, {:lvar, id}}, ctx}
  end

  def elaborate_type(ctx, {:type_universe, _span, n}) when is_integer(n) do
    {:ok, {:type, {:llit, n}}, ctx}
  end

  # Any other expression used as a type falls through to regular elaboration.
  def elaborate_type(ctx, expr), do: elaborate(ctx, expr)

  @doc """
  Elaborate a top-level definition into `{name, type_core, body_core}`.

  The type is built as a nested Pi from the parameter list and return type.
  The body is wrapped in matching lambdas. The definition's own name is in
  scope during body elaboration to support self-recursion.
  """
  @spec elaborate_def(t(), term()) ::
          {:ok, {atom(), Core.expr(), Core.expr()}, t()} | {:error, elab_error()}
  def elaborate_def(
        ctx,
        {:def, span,
         {:sig, _sig_span, name, _name_span, params, return_type,
          %{extern: {mod, fun, arity}} = _attrs}, nil}
      ) do
    case return_type do
      nil ->
        {:error, {:missing_return_type, name, span}}

      _ ->
        # Extern: elaborate only the type, use {:extern, mod, fun, arity} as body.
        with {:ok, type_core, ctx} <- elaborate_pi_type(ctx, params, return_type) do
          {:ok, {name, type_core, {:extern, mod, fun, arity}}, ctx}
        end
    end
  end

  def elaborate_def(
        ctx,
        {:def, span, {:sig, _sig_span, name, _name_span, params, return_type, _attrs}, body}
      ) do
    case return_type do
      nil ->
        {:error, {:missing_return_type, name, span}}

      _ ->
        elaborate_def_with_return(ctx, name, params, return_type, body)
    end
  end

  @doc """
  Resolve auto-implicit parameters for a definition.

  Scans the param types and return type for free variables that match
  registered auto-implicit names. Prepends implicit params for each match,
  preserving order of first occurrence. Variables that are builtins, already
  bound as params, or already in `ctx.names` are excluded.
  """
  @spec resolve_auto_implicits(t(), term()) :: term()
  def resolve_auto_implicits(
        ctx,
        {:def, def_span, {:sig, sig_span, name, name_span, params, return_type, attrs}, body}
      ) do
    # Collect all {:var, span, name} references from param types and return type.
    param_type_vars =
      params
      |> Enum.flat_map(fn {:param, _span, _binding, type} -> collect_type_vars(type) end)

    return_type_vars = collect_type_vars(return_type)

    all_vars = param_type_vars ++ return_type_vars

    # Deduplicate preserving first-occurrence order.
    seen = MapSet.new()

    {unique_vars, _} =
      Enum.reduce(all_vars, {[], seen}, fn {var_name, var_span}, {acc, seen} ->
        if MapSet.member?(seen, var_name) do
          {acc, seen}
        else
          {[{var_name, var_span} | acc], MapSet.put(seen, var_name)}
        end
      end)

    unique_vars = Enum.reverse(unique_vars)

    # Collect names already bound as params.
    param_names = MapSet.new(params, fn {:param, _, {n, _, _}, _} -> n end)

    # Collect names already in context.
    ctx_names = MapSet.new(ctx.names, fn {n, _level} -> n end)

    # Filter to auto-implicit candidates.
    implicit_params =
      unique_vars
      |> Enum.filter(fn {var_name, _span} ->
        Map.has_key?(ctx.auto_implicits, var_name) and
          not MapSet.member?(param_names, var_name) and
          not Map.has_key?(ctx.prelude, var_name) and
          not MapSet.member?(ctx_names, var_name)
      end)
      |> Enum.map(fn {var_name, var_span} ->
        type = Map.fetch!(ctx.auto_implicits, var_name)
        {:param, var_span, {var_name, :zero, true}, type}
      end)

    new_params = implicit_params ++ params
    new_sig = {:sig, sig_span, name, name_span, new_params, return_type, attrs}
    {:def, def_span, new_sig, body}
  end

  @doc """
  Elaborate a type declaration into an ADT declaration and register it.

  Returns `{:ok, adt_decl, ctx}` with the ADT registered in the context
  so that constructor names are resolvable.
  """
  @spec elaborate_type_decl(t(), term()) ::
          {:ok, Haruspex.ADT.adt_decl(), t()} | {:error, elab_error()}
  def elaborate_type_decl(ctx, {:type_decl, span, name, type_params, constructors}) do
    # Pre-register the type name with a placeholder so constructors can reference it.
    # This allows recursive types like `type Nat = zero | succ(Nat)`.
    placeholder_decl = %{
      name: name,
      params: [],
      constructors: [],
      universe_level: {:llit, 0},
      span: span
    }

    ctx = %{ctx | adts: Map.put(ctx.adts, name, placeholder_decl)}

    # Elaborate type parameters.
    {elab_params, inner_ctx} =
      Enum.reduce(type_params, {[], ctx}, fn {param_name, kind_expr}, {acc, c} ->
        {:ok, kind_core, c} = elaborate_type(c, kind_expr)
        c = push_binding(c, param_name)
        {[{param_name, kind_core} | acc], c}
      end)

    elab_params = Enum.reverse(elab_params)
    n_params = length(elab_params)

    # Elaborate constructors.
    elab_cons =
      Enum.map(constructors, fn {:constructor, con_span, con_name, field_types, return_type} ->
        elab_fields =
          Enum.map(field_types, fn ft ->
            {:ok, core, _} = elaborate_type(inner_ctx, ft)
            core
          end)

        elab_return =
          case return_type do
            nil ->
              # Default: data type applied to param variables.
              args =
                Enum.map((n_params - 1)..0//-1, fn i ->
                  {:var, i}
                end)

              {:data, name, args}

            rt ->
              {:ok, core, _} = elaborate_type(inner_ctx, rt)
              core
          end

        %{
          name: con_name,
          fields: elab_fields,
          return_type: elab_return,
          span: con_span
        }
      end)

    ctx = restore_bindings(ctx, inner_ctx)

    decl = %{
      name: name,
      params: elab_params,
      constructors: elab_cons,
      universe_level: {:llit, 0},
      span: span
    }

    # Compute universe level.
    level = Haruspex.ADT.compute_level(decl)
    decl = %{decl | universe_level: level}

    # Register the ADT so constructor names resolve.
    ctx = register_adt(ctx, decl)

    {:ok, decl, ctx}
  end

  @doc """
  Register an ADT declaration in the elaboration context.
  """
  @spec register_adt(t(), Haruspex.ADT.adt_decl()) :: t()
  def register_adt(ctx, decl) do
    %{ctx | adts: Map.put(ctx.adts, decl.name, decl)}
  end

  @doc """
  Register auto-implicit declarations in the elaboration context.
  """
  @spec register_implicits(t(), term()) :: t()
  def register_implicits(ctx, {:implicit_decl, _span, params}) do
    Enum.reduce(params, ctx, fn {:param, _span, {name, _mult, _implicit?}, type}, acc ->
      %{acc | auto_implicits: Map.put(acc.auto_implicits, name, type)}
    end)
  end

  # ============================================================================
  # Internal — record elaboration
  # ============================================================================

  @doc """
  Elaborate a record declaration.

  Registers the record in the context and its desugared ADT so that
  constructor names and field projections resolve correctly.
  """
  @spec elaborate_record_decl(t(), term()) ::
          {:ok, Haruspex.Record.record_decl(), t()} | {:error, elab_error()}
  def elaborate_record_decl(ctx, {:record_decl, span, name, type_params, fields}) do
    con_name = Haruspex.Record.constructor_name(name)

    # Elaborate type parameters.
    {elab_params, inner_ctx} =
      Enum.reduce(type_params, {[], ctx}, fn {param_name, kind_expr}, {acc, c} ->
        {:ok, kind_core, c} = elaborate_type(c, kind_expr)
        c = push_binding(c, param_name)
        {[{param_name, kind_core} | acc], c}
      end)

    elab_params = Enum.reverse(elab_params)

    # Elaborate field types in telescope order (each field can reference previous ones).
    {elab_fields, inner_ctx} =
      Enum.reduce(fields, {[], inner_ctx}, fn {:field, _fspan, fname, ftype}, {acc, c} ->
        {:ok, type_core, c} = elaborate_type(c, ftype)
        c = push_binding(c, fname)
        {[{fname, type_core} | acc], c}
      end)

    elab_fields = Enum.reverse(elab_fields)

    ctx = restore_bindings(ctx, inner_ctx)

    record_decl = %{
      name: name,
      params: elab_params,
      fields: elab_fields,
      constructor_name: con_name,
      span: span
    }

    # Convert to ADT and register both.
    adt_decl = Haruspex.Record.record_to_adt(record_decl)
    level = Haruspex.ADT.compute_level(adt_decl)
    adt_decl = %{adt_decl | universe_level: level}

    ctx = register_adt(ctx, adt_decl)
    ctx = %{ctx | records: Map.put(ctx.records, name, record_decl)}

    {:ok, record_decl, ctx}
  end

  # Elaborate `%Point{x: 1.0, y: 2.0}` into `{:con, :Point, :mk_Point, [1.0, 2.0]}`.
  @spec elaborate_record_construct(t(), atom(), [{atom(), term()}], term()) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_record_construct(ctx, record_name, field_assignments, span) do
    case Map.fetch(ctx.records, record_name) do
      {:ok, record_decl} ->
        # Reorder assignments to match declaration order.
        # Fill missing fields with errors.
        ordered_values =
          Enum.map(record_decl.fields, fn {fname, _ftype} ->
            case List.keyfind(field_assignments, fname, 0) do
              {^fname, value} -> {:ok, value}
              nil -> {:error, fname}
            end
          end)

        missing = for {:error, fname} <- ordered_values, do: fname

        if missing != [] do
          {:error, {:missing_record_fields, record_name, missing, span}}
        else
          values = for {:ok, v} <- ordered_values, do: v
          elaborate_con_args(ctx, record_name, record_decl.constructor_name, values)
        end

      :error ->
        {:error, {:unknown_record, record_name, span}}
    end
  end

  defp elaborate_record_update(ctx, record_name, target, field_updates, span) do
    with {:ok, target_core, ctx} <- elaborate(ctx, target) do
      # Resolve the record: use explicit name if given, otherwise infer from fields.
      case resolve_update_record(ctx, record_name, field_updates, span) do
        {:ok, record_decl} ->
          # Elaborate each update value.
          {elab_updates, ctx} =
            Enum.reduce(field_updates, {%{}, ctx}, fn {fname, expr}, {acc, c} ->
              case elaborate(c, expr) do
                {:ok, core, c2} -> {Map.put(acc, fname, core), c2}
                {:error, _} = err -> throw(err)
              end
            end)

          # Check dependent field constraints: if a field is updated and other
          # fields depend on it, those dependent fields must also be updated.
          update_names = Map.keys(elab_updates) |> MapSet.new()

          case check_dependent_field_updates(record_decl, update_names, span) do
            :ok -> :ok
            {:error, _} = err -> throw(err)
          end

          # Build: case target of mk_R(f0, f1, ...) -> mk_R(f0', f1', ...)
          # where f_i' = update_val if in updates, else f_i (original via var).
          arity = length(record_decl.fields)

          reconstructed_args =
            record_decl.fields
            |> Enum.with_index()
            |> Enum.map(fn {{fname, _ftype}, idx} ->
              case Map.fetch(elab_updates, fname) do
                {:ok, update_core} ->
                  # Shift up by arity — we're under arity binders from the case branch.
                  Haruspex.Core.shift(update_core, arity, 0)

                :error ->
                  # Original field via de Bruijn index.
                  {:var, arity - 1 - idx}
              end
            end)

          body = {:con, record_decl.name, record_decl.constructor_name, reconstructed_args}
          {:ok, {:case, target_core, [{record_decl.constructor_name, arity, body}]}, ctx}

        {:error, _} = err ->
          err
      end
    end
  catch
    {:error, _} = err -> err
  end

  # Check that when updating a field, all fields that depend on it are also updated.
  # In the telescope, field i's type may reference fields 0..i-1 via de Bruijn vars.
  # Field i at position i has type with vars 0..i-1 referring to fields i-1..0.
  @doc false
  def check_dependent_field_updates(record_decl, updated_fields, span) do
    fields = record_decl.fields

    # For each field at index i, check if its type mentions any earlier field
    # (via de Bruijn variable). If so, and that earlier field is updated but
    # field i is not, it's an error.
    errors =
      fields
      |> Enum.with_index()
      |> Enum.flat_map(fn {{fname, ftype}, idx} ->
        # Field at idx has type where var j refers to field (idx - 1 - j).
        # Check if any updated field is referenced but this field is not updated.
        if MapSet.member?(updated_fields, fname) do
          []
        else
          # Find which earlier fields this field's type depends on.
          deps = field_type_dependencies(ftype, idx)

          # If any of those dependencies are being updated, this field must be too.
          missing =
            Enum.filter(deps, fn dep_idx ->
              {dep_name, _} = Enum.at(fields, dep_idx)
              MapSet.member?(updated_fields, dep_name)
            end)

          if missing != [] do
            dep_names = Enum.map(missing, fn i -> elem(Enum.at(fields, i), 0) end)
            [{fname, dep_names}]
          else
            []
          end
        end
      end)

    case errors do
      [] ->
        :ok

      [{dependent_field, dep_names} | _] ->
        {:error,
         {:dependent_field_not_updated, record_decl.name, dependent_field, dep_names, span}}
    end
  end

  # Find which fields (by index) a field type depends on.
  # In the telescope, field at index `idx` has type where de Bruijn var `j`
  # refers to field at index `idx - 1 - j`.
  defp field_type_dependencies(type_expr, field_idx) do
    vars = collect_free_vars(type_expr, 0)
    # Convert de Bruijn vars to field indices.
    vars
    |> Enum.filter(fn v -> v < field_idx end)
    |> Enum.map(fn v -> field_idx - 1 - v end)
    |> Enum.uniq()
  end

  # Collect free variables in a core term (variables with index >= cutoff).
  defp collect_free_vars({:var, n}, cutoff) when n >= cutoff, do: [n - cutoff]
  defp collect_free_vars({:var, _}, _cutoff), do: []
  defp collect_free_vars({:lit, _}, _cutoff), do: []
  defp collect_free_vars({:builtin, _}, _cutoff), do: []
  defp collect_free_vars({:type, _}, _cutoff), do: []
  defp collect_free_vars({:meta, _}, _cutoff), do: []
  defp collect_free_vars({:erased}, _cutoff), do: []

  defp collect_free_vars({:pi, _, dom, cod}, cutoff),
    do: collect_free_vars(dom, cutoff) ++ collect_free_vars(cod, cutoff + 1)

  defp collect_free_vars({:sigma, a, b}, cutoff),
    do: collect_free_vars(a, cutoff) ++ collect_free_vars(b, cutoff + 1)

  defp collect_free_vars({:app, f, a}, cutoff),
    do: collect_free_vars(f, cutoff) ++ collect_free_vars(a, cutoff)

  defp collect_free_vars({:lam, _, body}, cutoff), do: collect_free_vars(body, cutoff + 1)

  defp collect_free_vars({:let, d, b}, cutoff),
    do: collect_free_vars(d, cutoff) ++ collect_free_vars(b, cutoff + 1)

  defp collect_free_vars({:data, _, args}, cutoff),
    do: Enum.flat_map(args, &collect_free_vars(&1, cutoff))

  defp collect_free_vars({:con, _, _, args}, cutoff),
    do: Enum.flat_map(args, &collect_free_vars(&1, cutoff))

  defp collect_free_vars(_, _cutoff), do: []

  defp resolve_update_record(ctx, record_name, _field_updates, span)
       when is_atom(record_name) and record_name != nil do
    case Map.fetch(ctx.records, record_name) do
      {:ok, decl} -> {:ok, decl}
      :error -> {:error, {:unknown_record, record_name, span}}
    end
  end

  defp resolve_update_record(ctx, nil, field_updates, span) do
    update_names = MapSet.new(field_updates, fn {name, _} -> name end)

    matches =
      Enum.filter(ctx.records, fn {_name, decl} ->
        record_names = MapSet.new(decl.fields, fn {fname, _} -> fname end)
        MapSet.subset?(update_names, record_names)
      end)

    case matches do
      [{_name, decl}] -> {:ok, decl}
      [] -> {:error, {:unknown_record_for_update, MapSet.to_list(update_names), span}}
      _ -> {:error, {:ambiguous_record_update, Enum.map(matches, &elem(&1, 0)), span}}
    end
  end

  # ============================================================================
  # Internal — with elaboration
  # ============================================================================

  defp elaborate_with(ctx, [scrutinee], branches) do
    with {:ok, scrut_core, ctx} <- elaborate(ctx, scrutinee) do
      elaborate_case_branches(ctx, scrut_core, branches)
    end
  end

  defp elaborate_with(ctx, [first | rest], branches) do
    # Multiple scrutinees desugar to nested with expressions.
    # with e1, e2 do branches end → case e1 do _ -> with e2 do branches end end
    # The wildcard binds e1's value; branches match against the innermost scrutinee.
    inner_with = {:with, nil, rest, branches}
    wildcard_branch = {:branch, nil, {:pat_wildcard, nil}, inner_with}

    with {:ok, scrut_core, ctx} <- elaborate(ctx, first) do
      elaborate_case_branches(ctx, scrut_core, [wildcard_branch])
    end
  end

  # ============================================================================
  # Internal — case elaboration
  # ============================================================================

  @spec elaborate_case_branches(t(), Core.expr(), [term()]) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_case_branches(ctx, scrut_core, branches) do
    elaborated =
      Enum.reduce_while(branches, {:ok, [], ctx}, fn
        {:branch, _span, pattern, body}, {:ok, acc, ctx} ->
          case elaborate_branch(ctx, pattern, body) do
            {:ok, branch, ctx} -> {:cont, {:ok, [branch | acc], ctx}}
            {:error, _} = err -> {:halt, err}
          end
      end)

    case elaborated do
      {:ok, rev_branches, ctx} ->
        {:ok, {:case, scrut_core, Enum.reverse(rev_branches)}, ctx}

      {:error, _} = err ->
        err
    end
  end

  defp elaborate_branch(ctx, {:pat_constructor, span, con_name, sub_patterns}, body) do
    # Flatten nested constructor sub-patterns into nested case expressions.
    {flat_pats, body} = flatten_nested_patterns(sub_patterns, body, span)

    arity = length(flat_pats)

    # Bind pattern variables.
    {inner_ctx, _var_names} =
      Enum.reduce(flat_pats, {ctx, []}, fn
        {:pat_var, _span, var_name}, {c, names} ->
          {push_binding(c, var_name), [var_name | names]}

        {:pat_wildcard, _span}, {c, names} ->
          {push_binding(c, :_), [:_ | names]}

        {:pat_lit, _span, _value}, {c, names} ->
          # Literal sub-patterns in constructors: treat as a binding for now.
          {push_binding(c, :_), [:_ | names]}
      end)

    with {:ok, body_core, inner_ctx} <- elaborate(inner_ctx, body) do
      ctx = restore_bindings(ctx, inner_ctx)
      {:ok, {con_name, arity, body_core}, ctx}
    end
  end

  defp elaborate_branch(ctx, {:pat_var, span, var_name}, body) do
    # Check if the name is a known nullary constructor.
    case find_constructor(ctx.adts, var_name) do
      {:ok, _type_name} ->
        # Nullary constructor pattern — delegate to constructor branch handler.
        elaborate_branch(ctx, {:pat_constructor, span, var_name, []}, body)

      :error ->
        # Variable pattern: arity 1 catch-all that binds the scrutinee.
        inner_ctx = push_binding(ctx, var_name)

        with {:ok, body_core, inner_ctx} <- elaborate(inner_ctx, body) do
          ctx = restore_bindings(ctx, inner_ctx)
          {:ok, {:_, 1, body_core}, ctx}
        end
    end
  end

  defp elaborate_branch(ctx, {:pat_wildcard, _span}, body) do
    inner_ctx = push_binding(ctx, :_)

    with {:ok, body_core, inner_ctx} <- elaborate(inner_ctx, body) do
      ctx = restore_bindings(ctx, inner_ctx)
      {:ok, {:_, 1, body_core}, ctx}
    end
  end

  defp elaborate_branch(ctx, {:pat_record, _span, record_name, field_patterns}, body) do
    # Desugar to constructor pattern with fields reordered and wildcards for missing fields.
    case Map.fetch(ctx.records, record_name) do
      {:ok, record_decl} ->
        sub_patterns =
          Enum.map(record_decl.fields, fn {fname, _ftype} ->
            case List.keyfind(field_patterns, fname, 0) do
              {^fname, pat} -> pat
              nil -> {:pat_wildcard, nil}
            end
          end)

        elaborate_branch(
          ctx,
          {:pat_constructor, nil, record_decl.constructor_name, sub_patterns},
          body
        )

      :error ->
        {:error, {:unknown_record, record_name, nil}}
    end
  end

  defp elaborate_branch(ctx, {:pat_lit, _span, value}, body) do
    with {:ok, body_core, ctx} <- elaborate(ctx, body) do
      {:ok, {:__lit, value, body_core}, ctx}
    end
  end

  # ============================================================================
  # Internal — nested pattern flattening
  # ============================================================================

  # Replace nested constructor sub-patterns with fresh variables and wrap
  # the body in nested case expressions. Purely syntactic — no types needed.
  @spec flatten_nested_patterns([term()], term(), term()) :: {[term()], term()}
  defp flatten_nested_patterns(sub_patterns, body, _span) do
    {flat_pats, body, _n} =
      Enum.reduce(sub_patterns, {[], body, 0}, fn
        {:pat_constructor, pat_span, nested_con, nested_sub_pats}, {acc, body, n} ->
          fresh = :"_nested_#{n}"
          flat_pat = {:pat_var, pat_span, fresh}

          wrapped_body =
            {:case, pat_span, {:var, pat_span, fresh},
             [
               {:branch, pat_span, {:pat_constructor, pat_span, nested_con, nested_sub_pats},
                body}
             ]}

          {acc ++ [flat_pat], wrapped_body, n + 1}

        other_pat, {acc, body, n} ->
          {acc ++ [other_pat], body, n}
      end)

    {flat_pats, body}
  end

  # ============================================================================
  # Internal — name resolution
  # ============================================================================

  @spec resolve_name(t(), atom()) ::
          {:builtin, Core.expr()}
          | {:bound, Core.ix()}
          | {:global, Core.expr()}
          | {:adt_type, atom()}
          | {:constructor, atom(), atom()}
          | :not_found
  defp resolve_name(ctx, name) do
    # 1. Check prelude (builtins) first.
    case Map.fetch(ctx.prelude, name) do
      {:ok, core} ->
        {:builtin, core}

      :error ->
        # 2. Check local bindings.
        case find_binding(ctx.names, name) do
          {:ok, bound_level} ->
            {:bound, ctx.level - bound_level - 1}

          :error ->
            # 3. Check ADT type names.
            case Map.fetch(ctx.adts, name) do
              {:ok, _decl} ->
                {:adt_type, name}

              :error ->
                # 4. Check ADT constructor names.
                case find_constructor(ctx.adts, name) do
                  {:ok, type_name} ->
                    {:constructor, type_name, name}

                  :error ->
                    # 5. Check imported names (open imports).
                    resolve_imported_name(ctx, name)
                end
            end
        end
    end
  end

  defp find_constructor(adts, name) do
    Enum.find_value(adts, :error, fn {type_name, decl} ->
      if Enum.any?(decl.constructors, &(&1.name == name)) do
        {:ok, type_name}
      end
    end)
  end

  # Resolve an unqualified name from open imports.
  @spec resolve_imported_name(t(), atom()) :: {:global, Core.expr()} | :not_found
  defp resolve_imported_name(%{db: nil}, _name), do: :not_found

  defp resolve_imported_name(ctx, name) do
    Enum.find_value(ctx.imports, :not_found, fn import_info ->
      if name_visible_in_import?(import_info, name) do
        case resolve_from_module(ctx, import_info.module_path, name) do
          {:ok, core_term} -> {:global, core_term}
          :error -> nil
        end
      end
    end)
  end

  # Resolve a qualified name like Math.add or Data.Vec.new.
  # Checks if the module (or its last segment) matches an import.
  defp resolve_qualified(%{db: nil}, _module_path, _name, span) do
    {:error, {:unsupported, :qualified_access, span}}
  end

  defp resolve_qualified(ctx, module_path, name, span) do
    # Find an import whose module_path matches (full or last-segment shorthand).
    matching_import =
      Enum.find(ctx.imports, fn import_info ->
        import_info.module_path == module_path or
          List.last(import_info.module_path) == List.first(module_path)
      end)

    case matching_import do
      nil ->
        {:error, {:unknown_module, Module.concat(module_path), span}}

      import_info ->
        case resolve_from_module(ctx, import_info.module_path, name) do
          {:ok, core_term} -> {:ok, core_term, ctx}
          :error -> {:error, {:unbound_variable, name, span}}
        end
    end
  end

  defp name_visible_in_import?(%{open: true}, _name), do: true
  defp name_visible_in_import?(%{open: names}, name) when is_list(names), do: name in names
  defp name_visible_in_import?(%{open: nil}, _name), do: false

  # Resolve a name from an imported module by querying its definitions.
  @spec resolve_from_module(t(), [atom()], atom()) :: {:ok, Core.expr()} | :error
  defp resolve_from_module(ctx, module_path, name) do
    uri = module_path_to_uri(module_path, ctx.source_roots)

    try do
      case Roux.Runtime.query(ctx.db, :haruspex_parse, uri) do
        {:ok, entity_ids} ->
          find_exported_definition(ctx.db, entity_ids, name, module_path)

        {:error, _} ->
          :error
      end
    rescue
      Roux.Input.NotSetError -> :error
    end
  end

  # Find a non-private definition by name in a list of entity IDs.
  defp find_exported_definition(db, entity_ids, name, module_path) do
    Enum.find_value(entity_ids, :error, fn entity_id ->
      entity_name = Roux.Runtime.field(db, Haruspex.Definition, entity_id, :name)

      if entity_name == name do
        is_private = Roux.Runtime.field(db, Haruspex.Definition, entity_id, :private?)

        if is_private do
          :error
        else
          module_name = Module.concat(module_path)
          uri = Roux.Runtime.field(db, Haruspex.Definition, entity_id, :uri)

          # Trigger elaboration to populate the type field.
          case Roux.Runtime.query(db, :haruspex_elaborate, {uri, name}) do
            {:ok, {type_core, _body_core}} ->
              arity = count_runtime_params(type_core)
              {:ok, {:global, module_name, name, arity}}

            {:error, _} ->
              :error
          end
        end
      end
    end)
  end

  # Count runtime (omega) params in a pi type.
  defp count_runtime_params({:pi, :omega, _dom, cod}), do: 1 + count_runtime_params(cod)
  defp count_runtime_params({:pi, :zero, _dom, cod}), do: count_runtime_params(cod)
  defp count_runtime_params(_), do: 0

  # Convert a module path to a file URI.
  defp module_path_to_uri(module_path, source_roots) do
    path_segments =
      Enum.map(module_path, fn segment ->
        segment |> Atom.to_string() |> Macro.underscore()
      end)

    relative = Path.join(path_segments) <> ".hx"

    case source_roots do
      [root | _] -> Path.join(root, relative)
      [] -> relative
    end
  end

  # Scan the name stack from the head (most recent binding) for the first match.
  @spec find_binding([{atom(), non_neg_integer()}], atom()) :: {:ok, non_neg_integer()} | :error
  defp find_binding([], _name), do: :error

  defp find_binding([{n, level} | _rest], name) when n == name, do: {:ok, level}

  defp find_binding([_ | rest], name), do: find_binding(rest, name)

  # ============================================================================
  # Internal — binding management
  # ============================================================================

  # Push a new binding, incrementing the level.
  @spec push_binding(t(), atom()) :: t()
  defp push_binding(ctx, name) do
    %{
      ctx
      | names: [{name, ctx.level} | ctx.names],
        name_list: ctx.name_list ++ [name],
        level: ctx.level + 1
    }
  end

  # Propagate meta state and holes from an inner context back to the outer,
  # restoring the outer binding state.
  @spec restore_bindings(t(), t()) :: t()
  defp restore_bindings(outer, inner) do
    %{
      outer
      | meta_state: inner.meta_state,
        holes: inner.holes,
        next_level_var: inner.next_level_var
    }
  end

  # ============================================================================
  # Internal — application arguments
  # ============================================================================

  @spec elaborate_data_args(t(), atom(), [term()]) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_data_args(ctx, type_name, args) do
    elaborated =
      Enum.reduce_while(args, {:ok, [], ctx}, fn arg, {:ok, acc, ctx} ->
        case elaborate(ctx, arg) do
          {:ok, arg_core, ctx} -> {:cont, {:ok, [arg_core | acc], ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case elaborated do
      {:ok, rev_args, ctx} ->
        {:ok, {:data, type_name, Enum.reverse(rev_args)}, ctx}

      {:error, _} = err ->
        err
    end
  end

  @spec elaborate_con_args(t(), atom(), atom(), [term()]) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_con_args(ctx, type_name, con_name, args) do
    elaborated =
      Enum.reduce_while(args, {:ok, [], ctx}, fn arg, {:ok, acc, ctx} ->
        case elaborate(ctx, arg) do
          {:ok, arg_core, ctx} -> {:cont, {:ok, [arg_core | acc], ctx}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case elaborated do
      {:ok, rev_args, ctx} ->
        {:ok, {:con, type_name, con_name, Enum.reverse(rev_args)}, ctx}

      {:error, _} = err ->
        err
    end
  end

  @spec elaborate_app_args(t(), Core.expr(), [term()]) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_app_args(ctx, func_core, []) do
    {:ok, func_core, ctx}
  end

  defp elaborate_app_args(ctx, func_core, [arg | rest]) do
    with {:ok, arg_core, ctx} <- elaborate(ctx, arg) do
      elaborate_app_args(ctx, {:app, func_core, arg_core}, rest)
    end
  end

  # ============================================================================
  # Internal — lambda elaboration
  # ============================================================================

  @spec elaborate_lambda(t(), [term()], term()) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_lambda(ctx, [], body) do
    elaborate(ctx, body)
  end

  defp elaborate_lambda(ctx, [{:param, _span, {name, mult, _implicit?}, _type} | rest], body) do
    inner_ctx = push_binding(ctx, name)

    with {:ok, body_core, inner_ctx} <- elaborate_lambda(inner_ctx, rest, body) do
      ctx = restore_bindings(ctx, inner_ctx)
      {:ok, {:lam, mult, body_core}, ctx}
    end
  end

  # ============================================================================
  # Internal — def elaboration
  # ============================================================================

  @spec elaborate_def_with_return(t(), atom(), [term()], term(), term()) ::
          {:ok, {atom(), Core.expr(), Core.expr()}, t()} | {:error, elab_error()}
  defp elaborate_def_with_return(ctx, name, params, return_type, body) do
    # Phase 1: Build the Pi type from params and return type.
    with {:ok, type_core, ctx} <- elaborate_pi_type(ctx, params, return_type) do
      # Phase 2: Push the def name so the body can self-reference.
      def_ctx = push_binding(ctx, name)

      # Phase 3: Push each param as a binding and elaborate the body.
      with {:ok, body_core, def_ctx} <- elaborate_def_body(def_ctx, params, body) do
        ctx = restore_bindings(ctx, def_ctx)
        {:ok, {name, type_core, body_core}, ctx}
      end
    end
  end

  # Build a nested Pi type from a param list and return type.
  @spec elaborate_pi_type(t(), [term()], term()) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_pi_type(ctx, [], return_type) do
    elaborate_type(ctx, return_type)
  end

  defp elaborate_pi_type(
         ctx,
         [{:param, _span, {name, mult, implicit?}, param_type} | rest],
         return_type
       ) do
    core_mult = if implicit?, do: :zero, else: mult

    with {:ok, dom_core, ctx} <- elaborate_type(ctx, param_type) do
      inner_ctx = push_binding(ctx, name)

      with {:ok, cod_core, inner_ctx} <- elaborate_pi_type(inner_ctx, rest, return_type) do
        ctx = restore_bindings(ctx, inner_ctx)
        {:ok, {:pi, core_mult, dom_core, cod_core}, ctx}
      end
    end
  end

  # Elaborate the body of a def, wrapping in lambdas for each param.
  @spec elaborate_def_body(t(), [term()], term()) ::
          {:ok, Core.expr(), t()} | {:error, elab_error()}
  defp elaborate_def_body(ctx, [], body) do
    elaborate(ctx, body)
  end

  defp elaborate_def_body(ctx, [{:param, _span, {name, mult, _implicit?}, _type} | rest], body) do
    inner_ctx = push_binding(ctx, name)

    with {:ok, body_core, inner_ctx} <- elaborate_def_body(inner_ctx, rest, body) do
      ctx = restore_bindings(ctx, inner_ctx)
      {:ok, {:lam, mult, body_core}, ctx}
    end
  end

  # ============================================================================
  # Internal — type variable collection
  # ============================================================================

  # Collect all `{:var, span, name}` references from a type expression.
  # Returns a list of `{name, span}` tuples in order of appearance.
  @spec collect_type_vars(term()) :: [{atom(), Pentiment.Span.Byte.t()}]
  defp collect_type_vars({:var, span, name}), do: [{name, span}]

  defp collect_type_vars({:pi, _span, _binding, domain, codomain}),
    do: collect_type_vars(domain) ++ collect_type_vars(codomain)

  defp collect_type_vars({:sigma, _span, _name, fst, snd}),
    do: collect_type_vars(fst) ++ collect_type_vars(snd)

  defp collect_type_vars({:app, _span, func, args}),
    do: collect_type_vars(func) ++ Enum.flat_map(args, &collect_type_vars/1)

  defp collect_type_vars({:type_universe, _span, _}), do: []
  defp collect_type_vars({:lit, _span, _}), do: []
  defp collect_type_vars(_), do: []
end
