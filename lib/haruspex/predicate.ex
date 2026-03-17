defmodule Haruspex.Predicate do
  @moduledoc """
  Refinement type predicate translation and discharge.

  Bridges between the haruspex surface AST predicate expressions and the
  `Constrain.Predicate` tagged tuple representation. Gathers refinement
  assumptions from the typing context and delegates entailment checking to
  `Constrain.Solver.entails?/2`.
  """

  alias Haruspex.Context

  # ============================================================================
  # Translation: surface AST predicate -> Constrain.Predicate.t()
  # ============================================================================

  @doc """
  Translate a haruspex surface predicate expression into a constrain predicate.

  The `ref_var` is the refinement variable name (e.g., `:x` from `{x : Int | x > 0}`).
  Variable references matching `ref_var` in the predicate are translated to
  `{:var, ref_var}` in the constrain domain.
  """
  @spec translate(term(), atom()) :: Constrain.Predicate.t()
  def translate({:binop, _span, op, left, right}, ref_var) do
    case op do
      :gt -> {:gt, translate_expr(left, ref_var), translate_expr(right, ref_var)}
      :lt -> {:lt, translate_expr(left, ref_var), translate_expr(right, ref_var)}
      :gte -> {:gte, translate_expr(left, ref_var), translate_expr(right, ref_var)}
      :lte -> {:lte, translate_expr(left, ref_var), translate_expr(right, ref_var)}
      :eq -> {:eq, translate_expr(left, ref_var), translate_expr(right, ref_var)}
      :neq -> {:neq, translate_expr(left, ref_var), translate_expr(right, ref_var)}
      :and -> {:and, translate(left, ref_var), translate(right, ref_var)}
      :or -> {:or, translate(left, ref_var), translate(right, ref_var)}
    end
  end

  def translate({:unaryop, _span, :not, inner}, ref_var) do
    {:not, translate(inner, ref_var)}
  end

  def translate({:lit, _span, true}, _ref_var), do: true
  def translate({:lit, _span, false}, _ref_var), do: false

  def translate({:lit, _span, value}, _ref_var) do
    # A bare literal in predicate position is truthy — but this shouldn't
    # normally occur. Treat as `true` for non-boolean literals.
    if is_boolean(value), do: value, else: true
  end

  def translate({:var, _span, name}, _ref_var) do
    # A bare variable reference in predicate position — treat as bound check.
    {:bound, name}
  end

  # ============================================================================
  # Expression translation
  # ============================================================================

  @doc """
  Translate a surface AST expression into a constrain expression.
  """
  @spec translate_expr(term(), atom()) :: Constrain.Predicate.expr()
  def translate_expr({:var, _span, name}, _ref_var) do
    {:var, name}
  end

  def translate_expr({:lit, _span, value}, _ref_var) do
    {:lit, value}
  end

  def translate_expr({:binop, _span, op, left, right}, ref_var) do
    constrain_op =
      case op do
        :add -> :add
        :sub -> :sub
        :mul -> :mul
        :div -> :div
      end

    {:op, constrain_op, [translate_expr(left, ref_var), translate_expr(right, ref_var)]}
  end

  def translate_expr({:unaryop, _span, :neg, inner}, ref_var) do
    # Negation as subtraction from zero.
    {:op, :sub, [{:lit, 0}, translate_expr(inner, ref_var)]}
  end

  # ============================================================================
  # Assumption gathering
  # ============================================================================

  @doc """
  Gather refinement assumptions from a typing context.

  Walks the context bindings. For each binding whose type is a refinement
  `{:vrefine, base, ref_name, pred}`, adds the predicate with the binding's
  actual variable name substituted for the refinement variable.
  """
  @spec gather_assumptions(Context.t()) :: [Constrain.Predicate.t()]
  def gather_assumptions(%Context{} = ctx) do
    ctx.bindings
    |> Enum.flat_map(fn binding ->
      case binding.type do
        {:vrefine, _base, ref_name, pred} ->
          # Substitute the binding's name for the refinement variable.
          subst = %{ref_name => {:var, binding.name}}
          [Constrain.Predicate.subst(pred, subst)]

        _ ->
          []
      end
    end)
  end

  # ============================================================================
  # Discharge
  # ============================================================================

  @doc """
  Discharge a predicate against assumptions.

  Returns `:yes` if the assumptions entail the goal, `:no` if they entail
  its negation, or `{:unknown, reason}` if neither can be determined.

  Handles trivial cases (literal `true`/`false`) and fully concrete
  comparison predicates before delegating to the solver.
  """
  @spec discharge([Constrain.Predicate.t()], Constrain.Predicate.t()) ::
          :yes | :no | {:unknown, String.t()}
  def discharge(_assumptions, true), do: :yes
  def discharge(_assumptions, false), do: :no

  def discharge(assumptions, goal) do
    # Try to evaluate fully concrete predicates directly.
    case try_eval_concrete(goal) do
      {:ok, true} -> :yes
      {:ok, false} -> :no
      :not_concrete -> delegate_to_solver(assumptions, goal)
    end
  end

  defp delegate_to_solver(assumptions, goal) do
    case Constrain.Solver.entails?(assumptions, goal) do
      :yes -> :yes
      :no -> :no
      :unknown -> {:unknown, "could not determine entailment"}
    end
  end

  # Attempt to evaluate a predicate when all variables have been replaced
  # with literals, making the predicate fully decidable.
  @spec try_eval_concrete(Constrain.Predicate.t()) :: {:ok, boolean()} | :not_concrete
  defp try_eval_concrete({:gt, lhs, rhs}), do: eval_comparison(lhs, rhs, &Kernel.>/2)
  defp try_eval_concrete({:lt, lhs, rhs}), do: eval_comparison(lhs, rhs, &Kernel.</2)
  defp try_eval_concrete({:gte, lhs, rhs}), do: eval_comparison(lhs, rhs, &Kernel.>=/2)
  defp try_eval_concrete({:lte, lhs, rhs}), do: eval_comparison(lhs, rhs, &Kernel.<=/2)
  defp try_eval_concrete({:eq, lhs, rhs}), do: eval_comparison(lhs, rhs, &Kernel.==/2)
  defp try_eval_concrete({:neq, lhs, rhs}), do: eval_comparison(lhs, rhs, &Kernel.!=/2)

  defp try_eval_concrete({:and, p, q}) do
    with {:ok, pv} <- try_eval_concrete(p),
         {:ok, qv} <- try_eval_concrete(q) do
      {:ok, pv and qv}
    end
  end

  defp try_eval_concrete({:or, p, q}) do
    with {:ok, pv} <- try_eval_concrete(p),
         {:ok, qv} <- try_eval_concrete(q) do
      {:ok, pv or qv}
    end
  end

  defp try_eval_concrete({:not, p}) do
    with {:ok, pv} <- try_eval_concrete(p) do
      {:ok, not pv}
    end
  end

  defp try_eval_concrete(_), do: :not_concrete

  defp eval_comparison({:lit, a}, {:lit, b}, op) when is_number(a) and is_number(b) do
    {:ok, op.(a, b)}
  end

  defp eval_comparison(_, _, _), do: :not_concrete
end
