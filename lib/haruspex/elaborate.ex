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
    :source_roots
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
    :source_roots
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
          source_roots: [String.t()]
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
      source_roots: Keyword.get(opts, :source_roots, [])
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
      :not_found -> {:error, {:unbound_variable, name, span}}
    end
  end

  def elaborate(ctx, {:lit, _span, value}) do
    {:ok, {:lit, value}, ctx}
  end

  def elaborate(ctx, {:app, _span, func, args}) do
    with {:ok, func_core, ctx} <- elaborate(ctx, func) do
      elaborate_app_args(ctx, func_core, args)
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

  def elaborate(ctx, {:dot, span, {:var, _span2, module_name}, field_name}) do
    # Qualified access: Module.field
    resolve_qualified(ctx, [module_name], field_name, span)
  end

  def elaborate(_ctx, {:if, span, _cond, _then_branch, _else_branch}) do
    {:error, {:unsupported, :if, span}}
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
  Register auto-implicit declarations in the elaboration context.
  """
  @spec register_implicits(t(), term()) :: t()
  def register_implicits(ctx, {:implicit_decl, _span, params}) do
    Enum.reduce(params, ctx, fn {:param, _span, {name, _mult, _implicit?}, type}, acc ->
      %{acc | auto_implicits: Map.put(acc.auto_implicits, name, type)}
    end)
  end

  # ============================================================================
  # Internal — name resolution
  # ============================================================================

  @spec resolve_name(t(), atom()) ::
          {:builtin, Core.expr()} | {:bound, Core.ix()} | {:global, Core.expr()} | :not_found
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
            # 3. Check imported names (open imports).
            resolve_imported_name(ctx, name)
        end
    end
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
  @spec resolve_from_module(t(), [atom()] | {:erlang_mod, atom()}, atom()) ::
          {:ok, Core.expr()} | :error
  defp resolve_from_module(_ctx, {:erlang_mod, _}, _name), do: :error

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
