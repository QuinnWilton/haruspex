defmodule Haruspex.TypeClass.Search do
  @moduledoc """
  Depth-bounded instance search with specificity-based overlap resolution.

  Given a goal like `{:Eq, [{:vbuiltin, :Int}]}`, searches the instance database
  for a matching instance, resolving constraints recursively. Search depth is
  bounded to prevent divergence from recursive instances.
  """

  alias Haruspex.Core
  alias Haruspex.Eval
  alias Haruspex.Unify
  alias Haruspex.Unify.MetaState
  alias Haruspex.Value

  # ============================================================================
  # Types
  # ============================================================================

  @type class_constraint :: {atom(), [Core.expr()]}

  @type instance_entry :: %{
          class_name: atom(),
          n_params: non_neg_integer(),
          head: [Core.expr()],
          constraints: [class_constraint()],
          methods: [{atom(), Core.expr()}],
          span: Pentiment.Span.Byte.t() | nil,
          module: atom() | nil
        }

  @type instance_db :: %{atom() => [instance_entry()]}

  @type search_result ::
          {:found, Core.expr(), MetaState.t()}
          | {:not_found, class_constraint()}
          | {:ambiguous, [instance_entry()]}
          | {:depth_exceeded, class_constraint(), non_neg_integer()}

  @default_max_depth 32

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Search for an instance matching the given goal.

  The goal is `{class_name, value_args}` where value_args are evaluated types.
  Returns `{:found, dict_term, meta_state}` on success.
  """
  @spec search(
          instance_db(),
          %{atom() => term()},
          MetaState.t(),
          non_neg_integer(),
          {atom(), [Value.value()]},
          keyword()
        ) ::
          search_result()
  def search(db, classes, ms, level, goal, opts \\ []) do
    depth = Keyword.get(opts, :depth, 0)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    do_search(db, classes, ms, level, goal, depth, max_depth)
  end

  @doc """
  Create an empty instance database.
  """
  @spec empty_db() :: instance_db()
  def empty_db, do: %{}

  @doc """
  Register an instance in the database.
  """
  @spec register(instance_db(), instance_entry()) :: instance_db()
  def register(db, entry) do
    Map.update(db, entry.class_name, [entry], fn entries -> entries ++ [entry] end)
  end

  @doc """
  Check if instance A is more specific than instance B.

  A is more specific if A's head is a substitution instance of B's head.
  We freshen B's params, then try to unify A's head with B's freshened head.
  """
  @spec more_specific?(instance_entry(), instance_entry(), MetaState.t(), non_neg_integer()) ::
          boolean()
  def more_specific?(inst_a, inst_b, ms, level) do
    # Create fresh metas for B's params (the flex side).
    {b_ms, b_metas} = freshen_params(ms, level, inst_b.n_params)

    # Evaluate B's head with fresh metas.
    b_env = Enum.reverse(b_metas)
    b_vals = eval_head(inst_b.head, b_env, b_ms)

    # For A's params, create RIGID variables (not metas). These cannot be
    # solved by unification, ensuring the check is asymmetric: B's metas can
    # absorb A's concrete values but not A's rigid variables.
    a_rigids = make_rigid_vars(level + 1000, inst_a.n_params)
    a_env = Enum.reverse(a_rigids)
    a_vals = eval_head(inst_a.head, a_env, b_ms)

    # Try to unify A's head with B's head.
    case unify_args(b_ms, level, a_vals, b_vals) do
      {:ok, _ms} -> true
      {:error, _} -> false
    end
  end

  # ============================================================================
  # Internal — search algorithm
  # ============================================================================

  defp do_search(_db, _classes, _ms, _level, goal, depth, max_depth) when depth >= max_depth do
    {:depth_exceeded, goal, depth}
  end

  defp do_search(db, classes, ms, level, {class_name, goal_args} = goal, depth, max_depth) do
    instances = Map.get(db, class_name, [])

    # Try each instance.
    matches =
      instances
      |> Enum.map(fn inst ->
        try_instance(db, classes, ms, level, goal_args, inst, depth, max_depth)
      end)
      |> Enum.filter(&match?({:match, _, _, _}, &1))

    case matches do
      [{:match, dict, _inst, result_ms}] ->
        {:found, dict, result_ms}

      [] ->
        # Try superclass extraction before giving up.
        case try_superclass(db, classes, ms, level, goal, depth, max_depth) do
          {:found, _, _} = found -> found
          _ -> {:not_found, goal}
        end

      multiple ->
        pick_most_specific(multiple, ms, level)
    end
  end

  defp try_instance(db, classes, ms, level, goal_args, inst, depth, max_depth) do
    # Create fresh metas for instance type parameters.
    {fresh_ms, metas} = freshen_params(ms, level, inst.n_params)

    # Evaluate instance head with fresh metas as environment.
    meta_env = Enum.reverse(metas)
    head_vals = eval_head(inst.head, meta_env, fresh_ms)

    # Try to unify instance head with goal args.
    case unify_args(fresh_ms, level, head_vals, goal_args) do
      {:ok, solved_ms} ->
        # Resolve instance constraints recursively.
        case resolve_constraints(
               db,
               classes,
               solved_ms,
               level,
               inst.constraints,
               meta_env,
               depth + 1,
               max_depth
             ) do
          {:ok, sub_dicts, final_ms} ->
            dict = build_dict(inst, sub_dicts, meta_env, final_ms)
            {:match, dict, inst, final_ms}

          {:error, _} ->
            :no_match
        end

      {:error, _} ->
        :no_match
    end
  end

  # Try to find the goal via superclass extraction.
  # If we're looking for Eq(a) and there's an Ord(a) instance available,
  # we can extract the Eq sub-dictionary from the Ord dictionary.
  defp try_superclass(db, classes, ms, level, {class_name, goal_args}, depth, max_depth) do
    # Find classes that have `class_name` as a superclass.
    super_classes =
      classes
      |> Enum.filter(fn {_name, decl} ->
        Enum.any?(decl.superclasses, fn {sc_name, _} -> sc_name == class_name end)
      end)

    Enum.find_value(super_classes, {:not_found, {class_name, goal_args}}, fn {parent_name,
                                                                              _parent_decl} ->
      # Try to find an instance of the parent class for the same args.
      case do_search(db, classes, ms, level, {parent_name, goal_args}, depth, max_depth) do
        {:found, parent_dict, result_ms} ->
          # Extract the sub-dictionary via the superclass field.
          field_name = Haruspex.TypeClass.superclass_field_name(class_name)
          sub_dict = {:record_proj, field_name, parent_dict}
          {:found, sub_dict, result_ms}

        _ ->
          nil
      end
    end)
  end

  defp resolve_constraints(_db, _classes, ms, _level, [], _env, _depth, _max_depth) do
    {:ok, [], ms}
  end

  defp resolve_constraints(db, classes, ms, level, constraints, env, depth, max_depth) do
    Enum.reduce_while(constraints, {:ok, [], ms}, fn {con_class, con_args},
                                                     {:ok, dicts, acc_ms} ->
      # Evaluate constraint args with the current meta solutions.
      con_vals = eval_head(con_args, env, acc_ms)

      case do_search(db, classes, acc_ms, level, {con_class, con_vals}, depth, max_depth) do
        {:found, dict, new_ms} ->
          {:cont, {:ok, dicts ++ [dict], new_ms}}

        {:not_found, _} = err ->
          {:halt, {:error, err}}

        {:ambiguous, _} = err ->
          {:halt, {:error, err}}

        {:depth_exceeded, _, _} = err ->
          {:halt, {:error, err}}
      end
    end)
  end

  defp pick_most_specific(matches, ms, level) do
    # For each candidate, check if it's more specific than all others.
    winner =
      Enum.find(matches, fn {:match, _, inst_a, _} ->
        Enum.all?(matches, fn {:match, _, inst_b, _} ->
          inst_a == inst_b or more_specific?(inst_a, inst_b, ms, level)
        end)
      end)

    case winner do
      {:match, dict, _inst, result_ms} -> {:found, dict, result_ms}
      nil -> {:ambiguous, Enum.map(matches, fn {:match, _, inst, _} -> inst end)}
    end
  end

  # ============================================================================
  # Internal — helpers
  # ============================================================================

  defp make_rigid_vars(_start_level, 0), do: []

  defp make_rigid_vars(start_level, n) do
    Enum.map(0..(n - 1), fn i ->
      type = {:vtype, {:llit, 0}}
      {:vneutral, type, {:nvar, start_level + i}}
    end)
  end

  defp freshen_params(ms, _level, 0), do: {ms, []}

  defp freshen_params(ms, level, n) do
    Enum.reduce(1..n, {ms, []}, fn _i, {acc_ms, acc_metas} ->
      type = {:vtype, {:llit, 0}}
      {id, new_ms} = MetaState.fresh_meta(acc_ms, type, level, :implicit)
      meta_val = {:vneutral, type, {:nmeta, id}}
      {new_ms, acc_metas ++ [meta_val]}
    end)
  end

  defp eval_head(head_terms, env, ms) do
    solved =
      ms.entries
      |> Enum.filter(fn {_, entry} -> match?({:solved, _}, entry) end)
      |> Map.new(fn {id, {:solved, val}} -> {id, {:solved, val}} end)

    eval_ctx = %{env: env, metas: solved, defs: %{}, fuel: 1000}

    Enum.map(head_terms, fn term -> Eval.eval(eval_ctx, term) end)
  end

  defp unify_args(ms, _level, [], []), do: {:ok, ms}

  defp unify_args(ms, level, [a | as], [b | bs]) do
    case Unify.unify(ms, level, a, b) do
      {:ok, new_ms} -> unify_args(new_ms, level, as, bs)
      {:error, _} = err -> err
    end
  end

  defp unify_args(_ms, _level, _, _), do: {:error, {:arity_mismatch}}

  # Build a dictionary term for a matched instance.
  # The dictionary is a constructor application: mk_ClassDict(sub_dicts..., methods...).
  defp build_dict(inst, sub_dicts, _env, _ms) do
    # The dictionary constructor takes superclass dicts then method implementations.
    dict_name = Haruspex.TypeClass.dict_name(inst.class_name)
    con_name = Haruspex.TypeClass.dict_constructor_name(inst.class_name)
    method_terms = Enum.map(inst.methods, fn {_name, body} -> body end)
    {:con, dict_name, con_name, sub_dicts ++ method_terms}
  end
end
