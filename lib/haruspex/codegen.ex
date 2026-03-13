defmodule Haruspex.Codegen do
  @moduledoc """
  Core terms to Elixir quoted AST compilation.

  Operates on erased core terms (output of `Haruspex.Erase`). All type-level
  and zero-multiplicity content has already been removed, so codegen is a
  straightforward structural translation.

  ## Fully-applied optimization

  When a builtin or extern is fully applied, the call is inlined rather than
  emitting a chain of single-argument applications. For example,
  `App(App(Builtin(:add), a), b)` compiles to `a + b` rather than
  `(&Kernel.+/2).(a).(b)`.
  """

  alias Haruspex.Core
  alias Haruspex.Erase

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Compile a module from a list of definitions.

  Each definition is a `{name, type, body}` triple. The type is used for
  erasure; the body is erased then compiled. Functions appear as `def` if
  their name is in `exports` (or exports is `:all`), otherwise `defp`.
  """
  @spec compile_module(atom(), :all | [atom()], [{atom(), Core.expr(), Core.expr()}], map()) ::
          Macro.t()
  def compile_module(module_name, exports, definitions, _options \\ %{}) do
    funs =
      Enum.map(definitions, fn {name, type, body} ->
        erased = Erase.erase(body, type)
        {params, compiled_body} = compile_function(erased, [])
        visibility = if exports == :all or name in exports, do: :def, else: :defp

        quote do
          unquote(visibility)(unquote(name)(unquote_splicing(params))) do
            unquote(compiled_body)
          end
        end
      end)

    quote do
      defmodule unquote(module_name) do
        (unquote_splicing(funs))
      end
    end
  end

  @doc """
  Compile a single erased core expression to Elixir quoted AST.
  """
  @spec compile_expr(Core.expr()) :: Macro.t()
  def compile_expr(term) do
    compile(term, [])
  end

  @doc """
  Compile and evaluate a single erased core expression.

  Returns the resulting Elixir value.
  """
  @spec eval_expr(Core.expr()) :: term()
  def eval_expr(term) do
    ast = compile_expr(term)
    {result, _bindings} = Code.eval_quoted(ast)
    result
  end

  # ============================================================================
  # Compilation
  # ============================================================================

  # Fully-applied binary builtin: App(App(Builtin(op), a), b).
  defp compile({:app, {:app, {:builtin, op}, a}, b}, names)
       when op in [:add, :sub, :mul, :div, :eq, :lt, :gt, :and, :or] do
    compiled_a = compile(a, names)
    compiled_b = compile(b, names)
    kernel_op = builtin_kernel_op(op)

    quote do
      unquote(kernel_op)(unquote(compiled_a), unquote(compiled_b))
    end
  end

  # Fully-applied comparison with neq, lte, gte.
  defp compile({:app, {:app, {:builtin, op}, a}, b}, names)
       when op in [:neq, :lte, :gte] do
    compiled_a = compile(a, names)
    compiled_b = compile(b, names)
    kernel_op = builtin_kernel_op(op)

    quote do
      unquote(kernel_op)(unquote(compiled_a), unquote(compiled_b))
    end
  end

  # Fully-applied unary builtin: App(Builtin(op), a).
  defp compile({:app, {:builtin, op}, a}, names) when op in [:neg, :not] do
    compiled_a = compile(a, names)
    kernel_op = builtin_kernel_op(op)

    quote do
      unquote(kernel_op)(unquote(compiled_a))
    end
  end

  # Partially-applied binary builtin: App(Builtin(op), a) for binary ops.
  defp compile({:app, {:builtin, op}, a}, names)
       when op in [:add, :sub, :mul, :div, :eq, :lt, :gt, :and, :or, :neq, :lte, :gte] do
    compiled_a = compile(a, names)
    kernel_op = builtin_kernel_op(op)
    b_var = Macro.var(:_b, __MODULE__)

    quote do
      fn unquote(b_var) ->
        unquote(kernel_op)(unquote(compiled_a), unquote(b_var))
      end
    end
  end

  # General application: extern detection, then fallback to regular apply.
  defp compile({:app, _, _} = term, names) do
    case collect_extern_app(term) do
      {:extern, mod, fun, arity, args} when length(args) == arity ->
        compiled_args = Enum.map(args, &compile(&1, names))

        quote do
          unquote(mod).unquote(fun)(unquote_splicing(compiled_args))
        end

      {:extern, mod, fun, arity, args} ->
        compiled_args = Enum.map(args, &compile(&1, names))
        remaining = arity - length(args)
        param_names = Enum.map(0..(remaining - 1), &Macro.var(:"_p#{&1}", __MODULE__))

        quote do
          fn unquote_splicing(param_names) ->
            unquote(mod).unquote(fun)(unquote_splicing(compiled_args ++ param_names))
          end
        end

      :not_extern ->
        compiled_f = compile(elem(term, 1), names)
        compiled_a = compile(elem(term, 2), names)

        quote do
          unquote(compiled_f).(unquote(compiled_a))
        end
    end
  end

  # Variable.
  defp compile({:var, ix}, names) do
    name = Enum.at(names, ix) || :"_v#{ix}"
    Macro.var(name, __MODULE__)
  end

  # Lambda.
  defp compile({:lam, :omega, body}, names) do
    var_name = fresh_name(names)
    var = Macro.var(var_name, __MODULE__)
    compiled_body = compile(body, [var_name | names])

    quote do
      fn unquote(var) -> unquote(compiled_body) end
    end
  end

  # Let.
  defp compile({:let, def_val, body}, names) do
    var_name = fresh_name(names)
    var = Macro.var(var_name, __MODULE__)
    compiled_def = compile(def_val, names)
    compiled_body = compile(body, [var_name | names])

    quote do
      (fn unquote(var) -> unquote(compiled_body) end).(unquote(compiled_def))
    end
  end

  # Literal.
  defp compile({:lit, v}, _names), do: Macro.escape(v)

  # Unapplied builtin.
  defp compile({:builtin, name}, _names) do
    {kernel_mod, kernel_fun, arity} = builtin_capture(name)

    quote do
      &(unquote(kernel_mod).unquote(kernel_fun) / unquote(arity))
    end
  end

  # Unapplied extern.
  defp compile({:extern, mod, fun, arity}, _names) do
    quote do
      &(unquote(mod).unquote(fun) / unquote(arity))
    end
  end

  # Unapplied global (cross-module reference).
  defp compile({:global, mod, fun, arity}, _names) do
    quote do
      &(unquote(mod).unquote(fun) / unquote(arity))
    end
  end

  # Pair.
  defp compile({:pair, a, b}, names) do
    compiled_a = compile(a, names)
    compiled_b = compile(b, names)

    quote do
      {unquote(compiled_a), unquote(compiled_b)}
    end
  end

  # Projections.
  defp compile({:fst, e}, names) do
    compiled = compile(e, names)

    quote do
      elem(unquote(compiled), 0)
    end
  end

  defp compile({:snd, e}, names) do
    compiled = compile(e, names)

    quote do
      elem(unquote(compiled), 1)
    end
  end

  # Constructor with no fields: compile to atom.
  defp compile({:con, _type_name, con_name, []}, _names) do
    con_name
  end

  # Constructor with fields: compile to tagged tuple.
  defp compile({:con, _type_name, con_name, args}, names) do
    compiled_args = Enum.map(args, &compile(&1, names))

    quote do
      {unquote(con_name), unquote_splicing(compiled_args)}
    end
  end

  # Case expression: compile to Elixir case.
  defp compile({:case, scrutinee, branches}, names) do
    compiled_scrut = compile(scrutinee, names)

    compiled_branches =
      Enum.map(branches, fn {con_name, arity, body} ->
        # Generate variable names for constructor fields.
        {field_names, field_vars} =
          Enum.reduce(1..arity//1, {[], []}, fn _, {ns, vs} ->
            var_name = fresh_name(names ++ ns)
            var = Macro.var(var_name, __MODULE__)
            {ns ++ [var_name], vs ++ [var]}
          end)

        inner_names = Enum.reverse(field_names) ++ names
        compiled_body = compile(body, inner_names)

        # Build pattern: atom for zero-arity, tagged tuple otherwise.
        pattern =
          if arity == 0 do
            con_name
          else
            quote do
              {unquote(con_name), unquote_splicing(field_vars)}
            end
          end

        {:->, [], [[pattern], compiled_body]}
      end)

    {:case, [], [compiled_scrut, [do: compiled_branches]]}
  end

  # Erased: should not appear in output positions. Emit nil as a safe default.
  defp compile(:erased, _names), do: nil

  # ============================================================================
  # Function compilation
  # ============================================================================

  # Extracts parameters from nested lambdas, returning {params, body_ast}.
  defp compile_function({:lam, :omega, body}, names) do
    var_name = fresh_name(names)
    var = Macro.var(var_name, __MODULE__)
    {params, compiled_body} = compile_function(body, [var_name | names])
    {[var | params], compiled_body}
  end

  defp compile_function({:extern, mod, fun, arity}, names) do
    # Generate params for each arity position and compile to a direct call.
    {params, param_vars} =
      Enum.reduce(1..arity//1, {[], []}, fn _, {ps, vs} ->
        var_name = fresh_name(names ++ Enum.map(ps, fn {name, _, _} -> name end))
        var = Macro.var(var_name, __MODULE__)
        {ps ++ [var], vs ++ [var]}
      end)

    body_ast =
      quote do
        unquote(mod).unquote(fun)(unquote_splicing(param_vars))
      end

    {params, body_ast}
  end

  defp compile_function({:global, mod, fun, arity}, names) do
    # Same as extern: generate params and compile to a direct call.
    {params, param_vars} =
      Enum.reduce(1..arity//1, {[], []}, fn _, {ps, vs} ->
        var_name = fresh_name(names ++ Enum.map(ps, fn {name, _, _} -> name end))
        var = Macro.var(var_name, __MODULE__)
        {ps ++ [var], vs ++ [var]}
      end)

    body_ast =
      quote do
        unquote(mod).unquote(fun)(unquote_splicing(param_vars))
      end

    {params, body_ast}
  end

  defp compile_function(body, names) do
    {[], compile(body, names)}
  end

  # ============================================================================
  # Extern application collection
  # ============================================================================

  # Collects a chain of applications to an extern, returning
  # {:extern, mod, fun, arity, [arg1, arg2, ...]} or :not_extern.
  defp collect_extern_app(term, args \\ [])

  defp collect_extern_app({:app, f, a}, args) do
    collect_extern_app(f, [a | args])
  end

  defp collect_extern_app({:extern, mod, fun, arity}, args) do
    {:extern, mod, fun, arity, args}
  end

  defp collect_extern_app({:global, mod, fun, arity}, args) do
    {:extern, mod, fun, arity, args}
  end

  defp collect_extern_app(_, _args), do: :not_extern

  # ============================================================================
  # Builtin mapping
  # ============================================================================

  defp builtin_kernel_op(:add), do: :+
  defp builtin_kernel_op(:sub), do: :-
  defp builtin_kernel_op(:mul), do: :*
  defp builtin_kernel_op(:div), do: :div
  defp builtin_kernel_op(:eq), do: :==
  defp builtin_kernel_op(:neq), do: :!=
  defp builtin_kernel_op(:lt), do: :<
  defp builtin_kernel_op(:gt), do: :>
  defp builtin_kernel_op(:lte), do: :<=
  defp builtin_kernel_op(:gte), do: :>=
  defp builtin_kernel_op(:neg), do: :-
  defp builtin_kernel_op(:not), do: :not
  defp builtin_kernel_op(:and), do: :and
  defp builtin_kernel_op(:or), do: :or

  defp builtin_capture(:add), do: {Kernel, :+, 2}
  defp builtin_capture(:sub), do: {Kernel, :-, 2}
  defp builtin_capture(:mul), do: {Kernel, :*, 2}
  defp builtin_capture(:div), do: {Kernel, :div, 2}
  defp builtin_capture(:eq), do: {Kernel, :==, 2}
  defp builtin_capture(:neq), do: {Kernel, :!=, 2}
  defp builtin_capture(:lt), do: {Kernel, :<, 2}
  defp builtin_capture(:gt), do: {Kernel, :>, 2}
  defp builtin_capture(:lte), do: {Kernel, :<=, 2}
  defp builtin_capture(:gte), do: {Kernel, :>=, 2}
  defp builtin_capture(:neg), do: {Kernel, :-, 1}
  defp builtin_capture(:not), do: {Kernel, :not, 1}
  defp builtin_capture(:and), do: {Kernel, :and, 2}
  defp builtin_capture(:or), do: {Kernel, :or, 2}

  # ============================================================================
  # Name generation
  # ============================================================================

  defp fresh_name(names) do
    name = :"_v#{length(names)}"

    if name in names do
      fresh_name_loop(name, 1, names)
    else
      name
    end
  end

  defp fresh_name_loop(base, n, names) do
    candidate = :"#{base}_#{n}"

    if candidate in names do
      fresh_name_loop(base, n + 1, names)
    else
      candidate
    end
  end
end
