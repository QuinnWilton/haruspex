defmodule Haruspex.Context do
  @moduledoc """
  Typing context: a stack of bindings with types, multiplicities, and usage tracking.

  The context maintains a parallel value environment for NbE alongside the
  type bindings. Each binding tracks its name (for error messages), type,
  multiplicity (`:zero` for erased, `:omega` for unrestricted), computational
  usage count, and optional definition value (for let-bindings).

  Variables are addressed by de Bruijn index. The `level` field equals the
  number of bindings and serves as the current de Bruijn level for fresh
  variable generation.
  """

  alias Haruspex.Core
  alias Haruspex.Value

  @enforce_keys [:bindings, :level, :env]
  defstruct [:bindings, :level, :env]

  # ============================================================================
  # Types
  # ============================================================================

  @type t :: %__MODULE__{
          bindings: [binding()],
          level: non_neg_integer(),
          env: [Value.value()]
        }

  @type binding :: %{
          name: atom(),
          type: Value.value(),
          mult: Core.mult(),
          usage: non_neg_integer(),
          definition: Value.value() | nil
        }

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create an empty context with no bindings.
  """
  @spec empty() :: t()
  def empty do
    %__MODULE__{bindings: [], level: 0, env: []}
  end

  @doc """
  Extend the context with a new lambda/pi binding.

  Pushes a fresh variable onto the NbE environment.
  """
  @spec extend(t(), atom(), Value.value(), Core.mult()) :: t()
  def extend(%__MODULE__{} = ctx, name, type, mult) do
    binding = %{name: name, type: type, mult: mult, usage: 0, definition: nil}
    fresh = Value.fresh_var(ctx.level, type)

    %__MODULE__{
      bindings: [binding | ctx.bindings],
      level: ctx.level + 1,
      env: [fresh | ctx.env]
    }
  end

  @doc """
  Extend the context with a let-binding that has a known definition value.

  Let-bound variables are transparent: looking them up in NbE returns the
  definition value, enabling reduction through lets.
  """
  @spec extend_def(t(), atom(), Value.value(), Core.mult(), Value.value()) :: t()
  def extend_def(%__MODULE__{} = ctx, name, type, mult, definition) do
    binding = %{name: name, type: type, mult: mult, usage: 0, definition: definition}

    %__MODULE__{
      bindings: [binding | ctx.bindings],
      level: ctx.level + 1,
      env: [definition | ctx.env]
    }
  end

  # ============================================================================
  # Lookups
  # ============================================================================

  @doc """
  Look up the type of a variable by de Bruijn index.
  """
  @spec lookup_type(t(), Core.ix()) :: Value.value()
  def lookup_type(%__MODULE__{} = ctx, ix) do
    binding = binding_at(ctx, ix)
    binding.type
  end

  @doc """
  Look up the name of a variable by de Bruijn index.
  """
  @spec lookup_name(t(), Core.ix()) :: atom()
  def lookup_name(%__MODULE__{} = ctx, ix) do
    binding = binding_at(ctx, ix)
    binding.name
  end

  @doc """
  Look up the multiplicity of a variable by de Bruijn index.
  """
  @spec lookup_mult(t(), Core.ix()) :: Core.mult()
  def lookup_mult(%__MODULE__{} = ctx, ix) do
    binding = binding_at(ctx, ix)
    binding.mult
  end

  # ============================================================================
  # Usage tracking
  # ============================================================================

  @doc """
  Increment the usage counter for a variable at the given de Bruijn index.

  Called when the variable is used in a computational position.
  """
  @spec use_var(t(), Core.ix()) :: t()
  def use_var(%__MODULE__{} = ctx, ix) do
    level = ix_to_level(ctx, ix)
    bindings = List.update_at(ctx.bindings, ctx.level - level - 1, &%{&1 | usage: &1.usage + 1})
    %{ctx | bindings: bindings}
  end

  @doc """
  Check that a variable's usage matches its multiplicity annotation.

  For `:zero` bindings, usage must be 0. For `:omega`, any count is acceptable.
  Called at the end of each binder scope (lambda body, let body).
  """
  @spec check_usage(t(), Core.ix()) ::
          :ok | {:error, {:multiplicity_violation, atom(), Core.mult(), non_neg_integer()}}
  def check_usage(%__MODULE__{} = ctx, ix) do
    binding = binding_at(ctx, ix)

    case binding.mult do
      :omega ->
        :ok

      :zero ->
        if binding.usage == 0 do
          :ok
        else
          {:error, {:multiplicity_violation, binding.name, :zero, binding.usage}}
        end
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  All bound names ordered by de Bruijn level (oldest binding first).

  Useful for pretty-printing with name recovery from de Bruijn levels.
  """
  @spec names(t()) :: [atom()]
  def names(%__MODULE__{} = ctx) do
    ctx.bindings
    |> Enum.reverse()
    |> Enum.map(& &1.name)
  end

  @doc """
  The current de Bruijn level (equals the number of bindings).
  """
  @spec level(t()) :: non_neg_integer()
  def level(%__MODULE__{level: level}), do: level

  @doc """
  The parallel value environment for NbE.
  """
  @spec env(t()) :: [Value.value()]
  def env(%__MODULE__{env: env}), do: env

  # ============================================================================
  # Internal
  # ============================================================================

  # Convert a de Bruijn index to the position in the bindings list.
  # Bindings are stored most-recent-first, so index 0 is the head.
  @spec binding_at(t(), Core.ix()) :: binding()
  defp binding_at(%__MODULE__{bindings: bindings}, ix) do
    Enum.at(bindings, ix)
  end

  # Convert de Bruijn index to de Bruijn level.
  @spec ix_to_level(t(), Core.ix()) :: non_neg_integer()
  defp ix_to_level(%__MODULE__{level: level}, ix) do
    level - ix - 1
  end
end
