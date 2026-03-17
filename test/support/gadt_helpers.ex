defmodule Haruspex.Test.GADTHelpers do
  @moduledoc false

  alias Haruspex.Check
  alias Haruspex.Context
  alias Haruspex.Unify.MetaState

  # ============================================================================
  # ADT declarations
  # ============================================================================

  def nat_decl do
    %{
      name: :Nat,
      params: [],
      constructors: [
        %{name: :zero, fields: [], return_type: {:data, :Nat, []}, span: nil},
        %{name: :succ, fields: [{:data, :Nat, []}], return_type: {:data, :Nat, []}, span: nil}
      ],
      universe_level: {:llit, 0},
      span: nil
    }
  end

  def vec_decl do
    %{
      name: :Vec,
      params: [{:a, {:type, {:llit, 0}}}, {:n, {:data, :Nat, []}}],
      constructors: [
        %{
          name: :vnil,
          fields: [],
          return_type: {:data, :Vec, [{:var, 1}, {:con, :Nat, :zero, []}]},
          span: nil
        },
        %{
          name: :vcons,
          fields: [{:var, 1}, {:data, :Vec, [{:var, 1}, {:var, 0}]}],
          return_type: {:data, :Vec, [{:var, 1}, {:con, :Nat, :succ, [{:var, 0}]}]},
          span: nil
        }
      ],
      universe_level: {:llit, 0},
      span: nil
    }
  end

  def adts, do: %{Nat: nat_decl(), Vec: vec_decl()}

  # ============================================================================
  # Check context
  # ============================================================================

  def check_ctx(extra_adts \\ %{}) do
    %{Check.new() | adts: Map.merge(adts(), extra_adts)}
  end

  def extend(ctx, name, type, mult \\ :omega) do
    %{ctx | context: Context.extend(ctx.context, name, type, mult), names: ctx.names ++ [name]}
  end

  # ============================================================================
  # Value constructors
  # ============================================================================

  def vzero, do: {:vcon, :Nat, :zero, []}
  def vsucc(n), do: {:vcon, :Nat, :succ, [n]}
  def vec_type(elem_type, nat_index), do: {:vdata, :Vec, [elem_type, nat_index]}

  # Core-level constructors.
  def czero, do: {:con, :Nat, :zero, []}
  def csucc(n), do: {:con, :Nat, :succ, [n]}
  def cvnil, do: {:con, :Vec, :vnil, []}
  def cvcons(x, rest), do: {:con, :Vec, :vcons, [x, rest]}

  # ============================================================================
  # Eval context
  # ============================================================================

  def make_eval_ctx(ctx) do
    %{
      env: Context.env(ctx.context),
      metas: MetaState.solved_entries(ctx.meta_state),
      defs: ctx.total_defs,
      fuel: ctx.fuel
    }
  end
end
