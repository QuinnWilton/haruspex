defmodule Haruspex.Unify.MetaState do
  @moduledoc """
  Persistent map of metavariable entries, threaded explicitly through all operations.

  Each meta is either unsolved (awaiting unification) or solved (bound to a value).
  The state also accumulates universe level constraints discovered during unification.
  """

  alias Haruspex.Core
  alias Haruspex.Value

  @enforce_keys [:next_id, :entries, :level_constraints]
  defstruct [:next_id, :entries, :level_constraints]

  # ============================================================================
  # Types
  # ============================================================================

  @type meta_entry ::
          {:unsolved, type :: Value.value(), ctx_level :: non_neg_integer(),
           kind :: :implicit | :hole | :gadt}
          | {:solved, Value.value()}

  @type t :: %__MODULE__{
          next_id: Core.meta_id(),
          entries: %{Core.meta_id() => meta_entry()},
          level_constraints: [level_constraint()]
        }

  @type level_constraint :: {:eq, Core.level(), Core.level()} | {:leq, Core.level(), Core.level()}

  @max_force_depth 100

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create an empty meta state with no entries.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{next_id: 0, entries: %{}, level_constraints: []}
  end

  # ============================================================================
  # Meta creation and solving
  # ============================================================================

  @doc """
  Create a fresh unsolved metavariable with the given type, context level, and kind.

  Returns the new meta ID and the updated state.
  """
  @spec fresh_meta(t(), Value.value(), non_neg_integer(), :implicit | :hole | :gadt) ::
          {Core.meta_id(), t()}
  def fresh_meta(%__MODULE__{} = state, type, level, kind) do
    id = state.next_id
    entry = {:unsolved, type, level, kind}

    updated = %{state | next_id: id + 1, entries: Map.put(state.entries, id, entry)}

    {id, updated}
  end

  @doc """
  Solve a metavariable by binding it to a value.

  Returns `{:ok, updated_state}` if the meta was unsolved or already solved with
  the same value. Returns `{:error, :already_solved}` if already solved with a
  different value.
  """
  @spec solve(t(), Core.meta_id(), Value.value()) :: {:ok, t()} | {:error, :already_solved}
  def solve(%__MODULE__{} = state, id, value) do
    case Map.fetch!(state.entries, id) do
      {:unsolved, _type, _level, _kind} ->
        {:ok, %{state | entries: Map.put(state.entries, id, {:solved, value})}}

      {:solved, existing} ->
        if existing == value do
          {:ok, state}
        else
          {:error, :already_solved}
        end
    end
  end

  @doc """
  Look up the entry for a metavariable.
  """
  @spec lookup(t(), Core.meta_id()) :: meta_entry()
  def lookup(%__MODULE__{} = state, id) do
    Map.fetch!(state.entries, id)
  end

  # ============================================================================
  # Forcing
  # ============================================================================

  @doc """
  Follow solved meta chains, resolving indirections.

  If a value is a neutral wrapping a solved meta, replace it with the solution
  and recurse. Stops on cycle detection (solution equals input) or after
  #{@max_force_depth} steps.
  """
  @spec force(t(), Value.value()) :: Value.value()
  def force(state, value), do: do_force(state, value, 0)

  defp do_force(_state, value, depth) when depth >= @max_force_depth, do: value

  defp do_force(state, {:vneutral, _type, {:nmeta, id}} = original, depth) do
    case Map.get(state.entries, id) do
      {:solved, solution} ->
        # Cycle detection: if the solution is the same as the input, stop.
        if solution == original do
          original
        else
          do_force(state, solution, depth + 1)
        end

      _ ->
        original
    end
  end

  defp do_force(_state, value, _depth), do: value

  # ============================================================================
  # Level constraints
  # ============================================================================

  @doc "Return only the solved entries as a map of {id => {:solved, value}}."
  @spec solved_entries(t()) :: %{Core.meta_id() => {:solved, Value.value()}}
  def solved_entries(%__MODULE__{} = state) do
    Map.filter(state.entries, fn {_, entry} -> match?({:solved, _}, entry) end)
  end

  @doc """
  Add a level constraint to the state.
  """
  @spec add_constraint(t(), level_constraint()) :: t()
  def add_constraint(%__MODULE__{} = state, constraint) do
    %{state | level_constraints: [constraint | state.level_constraints]}
  end
end
