defmodule Haruspex.Optimizer.Rules do
  @moduledoc """
  Rewrite rules for the quail e-graph optimizer.

  Defines algebraic simplification rules that preserve semantics while reducing
  term size. Rules are organized by category: arithmetic identities, boolean
  simplifications, and pair projection elimination.

  All rules use the curried application form matching how haruspex represents
  binary operations: `{:ir_app, {:ir_app, {:ir_builtin, :op}, lhs}, rhs}`.
  """

  import Quail, only: [v: 1]

  alias Quail.Rewrite

  @doc """
  Returns the full set of rewrite rules for optimization.
  """
  @spec rules() :: [Rewrite.t()]
  def rules do
    arithmetic_rules() ++ boolean_rules() ++ pair_rules()
  end

  # Arithmetic identity rules.
  #
  # Binary builtins are curried: x + y is {:ir_app, {:ir_app, {:ir_builtin, :add}, x}, y}.
  @spec arithmetic_rules() :: [Rewrite.t()]
  defp arithmetic_rules do
    [
      # x + 0 -> x
      Rewrite.rewrite(
        :add_zero_right,
        {:ir_app, {:ir_app, {:ir_builtin, :add}, v(:x)}, {:ir_lit, 0}},
        v(:x)
      ),
      # 0 + x -> x
      Rewrite.rewrite(
        :add_zero_left,
        {:ir_app, {:ir_app, {:ir_builtin, :add}, {:ir_lit, 0}}, v(:x)},
        v(:x)
      ),
      # x * 1 -> x
      Rewrite.rewrite(
        :mul_one_right,
        {:ir_app, {:ir_app, {:ir_builtin, :mul}, v(:x)}, {:ir_lit, 1}},
        v(:x)
      ),
      # 1 * x -> x
      Rewrite.rewrite(
        :mul_one_left,
        {:ir_app, {:ir_app, {:ir_builtin, :mul}, {:ir_lit, 1}}, v(:x)},
        v(:x)
      ),
      # x * 0 -> 0
      Rewrite.rewrite(
        :mul_zero_right,
        {:ir_app, {:ir_app, {:ir_builtin, :mul}, v(:x)}, {:ir_lit, 0}},
        {:ir_lit, 0}
      ),
      # 0 * x -> 0
      Rewrite.rewrite(
        :mul_zero_left,
        {:ir_app, {:ir_app, {:ir_builtin, :mul}, {:ir_lit, 0}}, v(:x)},
        {:ir_lit, 0}
      ),
      # x - 0 -> x
      Rewrite.rewrite(
        :sub_zero,
        {:ir_app, {:ir_app, {:ir_builtin, :sub}, v(:x)}, {:ir_lit, 0}},
        v(:x)
      ),
      # x - x -> 0
      Rewrite.rewrite(
        :sub_self,
        {:ir_app, {:ir_app, {:ir_builtin, :sub}, v(:x)}, v(:x)},
        {:ir_lit, 0}
      )
    ]
  end

  # Boolean simplification rules.
  @spec boolean_rules() :: [Rewrite.t()]
  defp boolean_rules do
    [
      # not(not(x)) -> x
      Rewrite.rewrite(
        :double_not,
        {:ir_app, {:ir_builtin, :not}, {:ir_app, {:ir_builtin, :not}, v(:x)}},
        v(:x)
      ),
      # true and x -> x
      Rewrite.rewrite(
        :and_true_left,
        {:ir_app, {:ir_app, {:ir_builtin, :and}, {:ir_lit, true}}, v(:x)},
        v(:x)
      ),
      # x and true -> x
      Rewrite.rewrite(
        :and_true_right,
        {:ir_app, {:ir_app, {:ir_builtin, :and}, v(:x)}, {:ir_lit, true}},
        v(:x)
      ),
      # false or x -> x
      Rewrite.rewrite(
        :or_false_left,
        {:ir_app, {:ir_app, {:ir_builtin, :or}, {:ir_lit, false}}, v(:x)},
        v(:x)
      ),
      # x or false -> x
      Rewrite.rewrite(
        :or_false_right,
        {:ir_app, {:ir_app, {:ir_builtin, :or}, v(:x)}, {:ir_lit, false}},
        v(:x)
      )
    ]
  end

  # Pair projection elimination rules.
  @spec pair_rules() :: [Rewrite.t()]
  defp pair_rules do
    [
      # fst(pair(a, b)) -> a
      Rewrite.rewrite(
        :fst_pair,
        {:ir_fst, {:ir_pair, v(:a), v(:b)}},
        v(:a)
      ),
      # snd(pair(a, b)) -> b
      Rewrite.rewrite(
        :snd_pair,
        {:ir_snd, {:ir_pair, v(:a), v(:b)}},
        v(:b)
      )
    ]
  end
end
