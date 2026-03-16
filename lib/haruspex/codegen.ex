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
  def compile_module(module_name, exports, definitions, options \\ %{}) do
    records = Map.get(options, :records, %{})
    adts = Map.get(options, :adts, %{})
    prelude_dict_names = prelude_dict_names()

    # Generate nested struct modules for each record (excluding prelude dicts).
    struct_modules =
      records
      |> Enum.reject(fn {name, _} -> name in prelude_dict_names end)
      |> Enum.map(fn {record_name, decl} ->
        field_names = Enum.map(decl.fields, fn {fname, _} -> fname end)
        nested_name = Module.concat(module_name, record_name)

        quote do
          defmodule unquote(nested_name) do
            defstruct unquote(field_names)
          end
        end
      end)

    # Generate constructor functions for ADTs (excluding record types and prelude dicts).
    constructor_funs =
      adts
      |> Enum.reject(fn {name, _} ->
        Map.has_key?(records, name) or name in prelude_dict_names
      end)
      |> Enum.flat_map(fn {_type_name, decl} ->
        Enum.map(decl.constructors, fn con ->
          params =
            Enum.with_index(con.fields, fn _, i ->
              Macro.var(:"arg#{i}", __MODULE__)
            end)

          body =
            if params == [] do
              con.name
            else
              {:{}, [], [con.name | params]}
            end

          quote do
            def unquote(con.name)(unquote_splicing(params)), do: unquote(body)
          end
        end)
      end)

    instances = Map.get(options, :instances, %{})
    classes = Map.get(options, :classes, %{})

    # Store records in process dictionary for compile/2 to use.
    prev = Process.get(:haruspex_codegen_records)
    Process.put(:haruspex_codegen_records, records)

    mutual_groups = Map.get(options, :mutual_groups, [])

    funs =
      Enum.map(definitions, fn {name, type, body} ->
        # Determine which names are in scope as outer bindings (self + mutual siblings).
        group = Enum.find(mutual_groups, fn names -> name in names end)
        outer_names = if group, do: Enum.reverse(group), else: [name]

        # Erasure context needs types for all outer bindings.
        outer_types =
          Enum.map(outer_names, fn n ->
            {^n, t, _} = Enum.find(definitions, fn {dn, _, _} -> dn == n end)
            t
          end)

        erased = Erase.erase(body, type, %Erase{types: outer_types})

        # Replace outer binding variables with {:self_ref, name} markers.
        erased =
          outer_names
          |> Enum.with_index()
          |> Enum.reduce(erased, fn {ref_name, ix}, term ->
            substitute_self_ref(term, ix, ref_name)
          end)

        {params, compiled_body} = compile_function(inline_dicts(erased), [])
        visibility = if exports == :all or name in exports, do: :def, else: :defp

        quote do
          unquote(visibility)(unquote(name)(unquote_splicing(params))) do
            unquote(compiled_body)
          end
        end
      end)

    # Generate __dict__ functions for each instance.
    dict_funs = compile_instance_dicts(instances, records, module_name)

    Process.put(:haruspex_codegen_records, prev)

    # Generate protocol bridges for @protocol-annotated classes.
    protocol_modules =
      Haruspex.TypeClass.Bridge.compile_bridges(classes, instances, records, module_name)

    module_def =
      quote do
        defmodule unquote(module_name) do
          (unquote_splicing(constructor_funs ++ funs ++ dict_funs))
        end
      end

    all_extra = struct_modules ++ protocol_modules

    if all_extra == [] do
      module_def
    else
      {:__block__, [], all_extra ++ [module_def]}
    end
  end

  @doc """
  Compile a single erased core expression to Elixir quoted AST.
  """
  @spec compile_expr(Core.expr()) :: Macro.t()
  def compile_expr(term) do
    compile(inline_dicts(term), [])
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
       when op in [:add, :sub, :mul, :div, :fadd, :fsub, :fmul, :fdiv, :eq, :lt, :gt, :and, :or] do
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
       when op in [
              :add,
              :sub,
              :mul,
              :div,
              :fadd,
              :fsub,
              :fmul,
              :fdiv,
              :eq,
              :lt,
              :gt,
              :and,
              :or,
              :neq,
              :lte,
              :gte
            ] do
    compiled_a = compile(a, names)
    kernel_op = builtin_kernel_op(op)
    b_var = Macro.var(:_b, __MODULE__)

    quote do
      fn unquote(b_var) ->
        unquote(kernel_op)(unquote(compiled_a), unquote(b_var))
      end
    end
  end

  # General application: extern detection, self-ref detection, then fallback.
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
        # Check for self-recursive call: app chain rooted at {:self_ref, name}.
        case collect_self_ref_app(term) do
          {:self_ref, fun_name, args} ->
            compiled_args = Enum.map(args, &compile(&1, names))
            {fun_name, [], compiled_args}

          :not_self_ref ->
            compiled_f = compile(elem(term, 1), names)
            compiled_a = compile(elem(term, 2), names)

            quote do
              unquote(compiled_f).(unquote(compiled_a))
            end
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

  # Definition reference (same-file function used in types or direct calls).
  defp compile({:def_ref, name}, _names) do
    {name, [], []}
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

  # Record projection: field access on a struct.
  # Known-constructor inlining is handled by inline_dicts/1 before compilation.
  defp compile({:record_proj, field_name, expr}, names) do
    compiled = compile(expr, names)
    {{:., [], [compiled, field_name]}, [no_parens: true], []}
  end

  # Constructor: check if it's a record for struct codegen.
  defp compile({:con, type_name, con_name, args}, names) do
    records = Process.get(:haruspex_codegen_records, %{})

    case Map.fetch(records, type_name) do
      {:ok, record_decl} when args != [] ->
        compiled_args = Enum.map(args, &compile(&1, names))
        field_names = Enum.map(record_decl.fields, fn {fname, _} -> fname end)
        pairs = Enum.zip(field_names, compiled_args)
        {:%, [], [type_name, {:%{}, [], pairs}]}

      _ ->
        if args == [] do
          con_name
        else
          compiled_args = Enum.map(args, &compile(&1, names))

          quote do
            {unquote(con_name), unquote_splicing(compiled_args)}
          end
        end
    end
  end

  # Case expression: compile to Elixir case.
  defp compile({:case, scrutinee, branches}, names) do
    compiled_scrut = compile(scrutinee, names)

    compiled_branches =
      Enum.map(branches, fn
        {:__lit, value, body} ->
          compiled_body = compile(body, names)
          pattern = Macro.escape(value)
          {:->, [], [[pattern], compiled_body]}

        {:_, 0, body} ->
          compiled_body = compile(body, names)
          {:->, [], [[{:_, [], nil}], compiled_body]}

        {:_, 1, body} ->
          var_name = fresh_name(names)
          var = Macro.var(var_name, __MODULE__)
          compiled_body = compile(body, [var_name | names])
          {:->, [], [[var], compiled_body]}

        {con_name, arity, body} ->
          # Generate variable names for constructor fields.
          {var_names, field_vars} =
            Enum.reduce(1..arity//1, {[], []}, fn _, {ns, vs} ->
              var_name = fresh_name(names ++ ns)
              var = Macro.var(var_name, __MODULE__)
              {ns ++ [var_name], vs ++ [var]}
            end)

          inner_names = Enum.reverse(var_names) ++ names
          compiled_body = compile(body, inner_names)

          # Check if this constructor belongs to a record for struct patterns.
          records = Process.get(:haruspex_codegen_records, %{})
          record_match = find_record_by_constructor(records, con_name)

          pattern =
            cond do
              arity == 0 ->
                con_name

              record_match != nil ->
                {_type_name, record_decl} = record_match
                record_field_names = Enum.map(record_decl.fields, fn {fname, _} -> fname end)
                pairs = Enum.zip(record_field_names, field_vars)
                {:%, [], [record_decl.name, {:%{}, [], pairs}]}

              true ->
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

  # Collects a chain of applications to a self_ref, returning
  # {:self_ref, name, [arg1, arg2, ...]} or :not_self_ref.
  defp collect_self_ref_app(term, args \\ [])

  defp collect_self_ref_app({:app, f, a}, args) do
    collect_self_ref_app(f, [a | args])
  end

  defp collect_self_ref_app({:self_ref, name}, args) do
    {:self_ref, name, args}
  end

  defp collect_self_ref_app(_, _args), do: :not_self_ref

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
  defp builtin_kernel_op(:fadd), do: :+
  defp builtin_kernel_op(:fsub), do: :-
  defp builtin_kernel_op(:fmul), do: :*
  defp builtin_kernel_op(:fdiv), do: :/

  defp builtin_capture(:add), do: {Kernel, :+, 2}
  defp builtin_capture(:sub), do: {Kernel, :-, 2}
  defp builtin_capture(:mul), do: {Kernel, :*, 2}
  defp builtin_capture(:div), do: {Kernel, :div, 2}
  defp builtin_capture(:fadd), do: {Kernel, :+, 2}
  defp builtin_capture(:fsub), do: {Kernel, :-, 2}
  defp builtin_capture(:fmul), do: {Kernel, :*, 2}
  defp builtin_capture(:fdiv), do: {Kernel, :/, 2}
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
  # Dictionary inlining (core-term level)
  # ============================================================================

  # Rewrite `{:record_proj, field, {:con, type, con, args}}` to the concrete
  # field value before compilation. This lets fully-applied builtin patterns
  # fire even when the builtin was extracted from a dictionary constructor.
  @doc false
  def inline_dicts({:record_proj, field_name, expr}) do
    inlined_expr = inline_dicts(expr)

    case inlined_expr do
      {:con, type_name, _con_name, args} ->
        records = Process.get(:haruspex_codegen_records, %{})

        case Map.fetch(records, type_name) do
          {:ok, record_decl} ->
            field_names = Enum.map(record_decl.fields, fn {fname, _} -> fname end)
            field_index = Enum.find_index(field_names, &(&1 == field_name))

            if field_index do
              inline_dicts(Enum.at(args, field_index))
            else
              {:record_proj, field_name, inlined_expr}
            end

          :error ->
            {:record_proj, field_name, inlined_expr}
        end

      _ ->
        {:record_proj, field_name, inlined_expr}
    end
  end

  def inline_dicts({:app, f, a}), do: {:app, inline_dicts(f), inline_dicts(a)}
  def inline_dicts({:lam, m, body}), do: {:lam, m, inline_dicts(body)}
  def inline_dicts({:let, d, b}), do: {:let, inline_dicts(d), inline_dicts(b)}
  def inline_dicts({:pair, a, b}), do: {:pair, inline_dicts(a), inline_dicts(b)}
  def inline_dicts({:fst, e}), do: {:fst, inline_dicts(e)}
  def inline_dicts({:snd, e}), do: {:snd, inline_dicts(e)}

  def inline_dicts({:con, tn, cn, args}),
    do: {:con, tn, cn, Enum.map(args, &inline_dicts/1)}

  def inline_dicts({:case, scrut, branches}) do
    {:case, inline_dicts(scrut),
     Enum.map(branches, fn
       {:__lit, v, body} -> {:__lit, v, inline_dicts(body)}
       {tag, arity, body} -> {tag, arity, inline_dicts(body)}
     end)}
  end

  def inline_dicts(term), do: term

  # ============================================================================
  # Instance dictionary compilation
  # ============================================================================

  # Generate __dict__ functions for each instance in the database.
  # For `instance Eq(Int)`, generates:
  #   def __dict_Eq_Int__(), do: %EqDict{eq: fn x, y -> ... end}
  # For `[Eq(a)] => Eq(List(a))`, generates:
  #   def __dict_Eq_List__(eq_a), do: %EqDict{eq: fn xs, ys -> ... end}
  defp compile_instance_dicts(instances, records, _module_name) do
    instances
    |> Enum.flat_map(fn {_class_name, entries} -> entries end)
    |> Enum.reject(fn entry -> entry.module == :prelude end)
    |> Enum.map(fn entry ->
      dict_name = Haruspex.TypeClass.dict_name(entry.class_name)
      fun_name = dict_function_name(entry)

      # Constraint parameters become function params (sub-dictionaries).
      constraint_params =
        Enum.with_index(entry.constraints, fn _, i ->
          Macro.var(:"_dict#{i}", __MODULE__)
        end)

      # Build the struct body.
      case Map.fetch(records, dict_name) do
        {:ok, record_decl} ->
          field_names = Enum.map(record_decl.fields, fn {fname, _} -> fname end)

          # Map constraint dicts to superclass fields, methods to method fields.
          n_supers = length(entry.constraints)
          method_terms = Enum.map(entry.methods, fn {_name, body} -> body end)
          super_indices = if n_supers > 0, do: Enum.to_list(0..(n_supers - 1)), else: []
          all_values = super_indices ++ method_terms

          field_asts =
            Enum.zip(field_names, all_values)
            |> Enum.map(fn
              {fname, idx} when is_integer(idx) ->
                {fname, Enum.at(constraint_params, idx)}

              {fname, body_term} ->
                {fname, compile(body_term, [])}
            end)

          struct_ast = {:%, [], [dict_name, {:%{}, [], field_asts}]}

          quote do
            def unquote(fun_name)(unquote_splicing(constraint_params)), do: unquote(struct_ast)
          end

        :error ->
          # No record decl — skip (shouldn't happen for well-formed programs).
          quote do
          end
      end
    end)
  end

  # Generate a deterministic function name for an instance's __dict__ function.
  # e.g., Eq(Int) → :__dict_Eq_Int__, Eq(List(a)) → :__dict_Eq_List_a__
  defp dict_function_name(entry) do
    head_suffix =
      entry.head
      |> Enum.map(&head_term_name/1)
      |> Enum.join("_")

    :"__dict_#{entry.class_name}_#{head_suffix}__"
  end

  defp head_term_name({:builtin, name}), do: Atom.to_string(name)

  defp head_term_name({:data, name, args}),
    do: "#{name}_#{Enum.map_join(args, "_", &head_term_name/1)}"

  defp head_term_name({:var, ix}), do: "v#{ix}"
  defp head_term_name(_), do: "unknown"

  # ============================================================================
  # Record helpers
  # ============================================================================

  defp find_record_by_constructor(records, con_name) do
    Enum.find(records, fn {_name, decl} -> decl.constructor_name == con_name end)
  end

  # Prelude dictionary type names that should not generate struct modules
  # or constructor functions in user modules.
  defp prelude_dict_names do
    MapSet.new([:NumDict, :EqDict, :OrdDict])
  end

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

  # ============================================================================
  # Self-recursion support
  # ============================================================================

  # Replace the self-reference variable (at de Bruijn index `self_ix` under
  # `depth` binders) with a {:self_ref, name} marker throughout the term.
  defp substitute_self_ref(term, self_ix, name) do
    subst_self(term, self_ix, name, 0)
  end

  defp subst_self({:var, ix}, self_ix, name, depth) do
    if ix == self_ix + depth, do: {:self_ref, name}, else: {:var, ix}
  end

  defp subst_self({:lam, mult, body}, self_ix, name, depth) do
    {:lam, mult, subst_self(body, self_ix, name, depth + 1)}
  end

  defp subst_self({:app, f, a}, self_ix, name, depth) do
    {:app, subst_self(f, self_ix, name, depth), subst_self(a, self_ix, name, depth)}
  end

  defp subst_self({:let, d, b}, self_ix, name, depth) do
    {:let, subst_self(d, self_ix, name, depth), subst_self(b, self_ix, name, depth + 1)}
  end

  defp subst_self({:case, scrut, branches}, self_ix, name, depth) do
    scrut2 = subst_self(scrut, self_ix, name, depth)

    branches2 =
      Enum.map(branches, fn
        {:__lit, v, body} ->
          {:__lit, v, subst_self(body, self_ix, name, depth)}

        {tag, arity, body} ->
          {tag, arity, subst_self(body, self_ix, name, depth + arity)}
      end)

    {:case, scrut2, branches2}
  end

  defp subst_self({:pair, a, b}, self_ix, name, depth) do
    {:pair, subst_self(a, self_ix, name, depth), subst_self(b, self_ix, name, depth)}
  end

  defp subst_self({:fst, e}, self_ix, name, depth) do
    {:fst, subst_self(e, self_ix, name, depth)}
  end

  defp subst_self({:snd, e}, self_ix, name, depth) do
    {:snd, subst_self(e, self_ix, name, depth)}
  end

  defp subst_self({:con, tn, cn, args}, self_ix, name, depth) do
    {:con, tn, cn, Enum.map(args, &subst_self(&1, self_ix, name, depth))}
  end

  defp subst_self({:record_proj, field, expr}, self_ix, name, depth) do
    {:record_proj, field, subst_self(expr, self_ix, name, depth)}
  end

  defp subst_self({:def_ref, _} = term, _self_ix, _name, _depth), do: term

  defp subst_self(term, _self_ix, _name, _depth), do: term
end
