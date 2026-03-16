defmodule Haruspex.Erase do
  @moduledoc """
  Type and multiplicity erasure pass.

  Walks a checked core term alongside its type, removing all type-level
  and zero-multiplicity content. Produces an erased core term suitable
  for codegen.

  ## Erasure rules

  - `Lam(:zero, body)` with `Pi(:zero, ...)` type: unwrap, removing the parameter.
  - `App(f, a)` where `f` has `Pi(:zero, ...)` type: skip the argument.
  - `Pi`, `Sigma`, `Type`: replaced with `:erased`.
  - `Spanned`: stripped (span removed, inner term erased).
  - `Meta`, `InsertedMeta`: raise `CompilerBug` (must be solved before erasure).
  - `Let` with erased def: eliminated (binding removed).

  After erasure, the output contains no `:zero` lams, no type-level nodes,
  no spans, and no metas.
  """

  alias Haruspex.Core

  @type context :: %__MODULE__{
          types: [Core.expr()]
        }

  defstruct types: []

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Erase a core term given its type.

  Returns an erased core term with all type-level and zero-multiplicity
  content removed.
  """
  @spec erase(Core.expr(), Core.expr()) :: Core.expr()
  def erase(term, type) do
    check(term, type, %__MODULE__{})
  end

  @doc """
  Erase a core term given its type and an initial type context.

  The context provides types for free variables in the term.
  """
  @spec erase(Core.expr(), Core.expr(), context()) :: Core.expr()
  def erase(term, type, %__MODULE__{} = ctx) do
    check(term, type, ctx)
  end

  # ============================================================================
  # Check mode: erase with known type
  # ============================================================================

  # Zero lambda: unwrap, removing the erased parameter.
  defp check({:lam, :zero, body}, {:pi, :zero, dom, cod}, ctx) do
    erased = check(body, cod, push(ctx, dom))
    Core.subst(erased, 0, :erased)
  end

  # Omega lambda: keep the parameter.
  defp check({:lam, :omega, body}, {:pi, :omega, dom, cod}, ctx) do
    {:lam, :omega, check(body, cod, push(ctx, dom))}
  end

  # Application: synthesize function type to determine multiplicity.
  defp check({:app, _, _} = term, _type, ctx) do
    {erased, _type} = synth(term, ctx)
    erased
  end

  # Let binding: erase def, eliminate if type-level.
  defp check({:let, def_val, body}, type, ctx) do
    {erased_def, def_type} = synth(def_val, ctx)

    if type_level?(def_type) do
      erased_body = check(body, type, push(ctx, def_type))
      Core.subst(erased_body, 0, :erased)
    else
      {:let, erased_def, check(body, type, push(ctx, def_type))}
    end
  end

  # Type-level terms: erase entirely.
  defp check({:pi, _, _, _}, _, _ctx), do: :erased
  defp check({:sigma, _, _}, _, _ctx), do: :erased
  defp check({:type, _}, _, _ctx), do: :erased

  # Span wrappers: strip and recurse.
  defp check({:spanned, _span, inner}, type, ctx), do: check(inner, type, ctx)

  # Unsolved metas: compiler bug.
  defp check({:meta, id}, _, _ctx) do
    raise Haruspex.CompilerBug, "unsolved meta #{id} reached erasure"
  end

  defp check({:inserted_meta, id, _mask}, _, _ctx) do
    raise Haruspex.CompilerBug, "unsolved inserted meta #{id} reached erasure"
  end

  # Pair: erase both components with their Sigma types.
  defp check({:pair, a, b}, {:sigma, a_type, b_type}, ctx) do
    erased_a = check(a, a_type, ctx)
    {:pair, erased_a, check(b, Core.subst(b_type, 0, a), ctx)}
  end

  # Projections: synthesize the pair's type.
  defp check({:fst, e}, _type, ctx) do
    {erased, _type} = synth(e, ctx)
    {:fst, erased}
  end

  defp check({:snd, e}, _type, ctx) do
    {erased, _type} = synth(e, ctx)
    {:snd, erased}
  end

  # Data type reference: type-level, erase.
  defp check({:data, _, _}, _, _ctx), do: :erased

  # Constructor: erase type args (they're implicit/zero-mult), keep field args.
  defp check({:con, type_name, con_name, args}, _type, ctx) do
    # All constructor args at this level are runtime fields (type params were
    # already stripped during elaboration via zero-mult application).
    {:con, type_name, con_name, Enum.map(args, fn a -> synth_and_erase(a, ctx) end)}
  end

  # Case: erase scrutinee and branch bodies.
  defp check({:case, scrutinee, branches}, _type, ctx) do
    {erased_scrut, _scrut_type} = synth(scrutinee, ctx)

    {:case, erased_scrut,
     Enum.map(branches, fn
       {:__lit, value, body} ->
         {erased_body, _body_type} = synth(body, ctx)
         {:__lit, value, erased_body}

       {con_name, arity, body} ->
         inner_ctx = Enum.reduce(1..arity//1, ctx, fn _, c -> push(c, {:type, {:llit, 0}}) end)
         {erased_body, _body_type} = synth(body, inner_ctx)
         {con_name, arity, erased_body}
     end)}
  end

  # Record projection: erase inner expression structurally.
  defp check({:record_proj, field, expr}, _type, ctx) do
    {:record_proj, field, synth_and_erase(expr, ctx)}
  end

  # Structural: pass through unchanged.
  defp check({:var, ix}, _type, _ctx), do: {:var, ix}
  defp check({:lit, v}, _type, _ctx), do: {:lit, v}
  defp check({:builtin, name}, _type, _ctx), do: {:builtin, name}
  defp check({:extern, mod, fun, arity}, _type, _ctx), do: {:extern, mod, fun, arity}
  defp check({:global, mod, name, arity}, _type, _ctx), do: {:global, mod, name, arity}
  defp check({:def_ref, name}, _type, _ctx), do: {:def_ref, name}

  # ============================================================================
  # Synth mode: erase and return {erased_term, type}
  # ============================================================================

  # Variable: look up type in context.
  defp synth({:var, ix}, ctx) do
    type = Enum.at(ctx.types, ix)
    {{:var, ix}, type}
  end

  # Application: synthesize function type, determine if argument is erased.
  defp synth({:app, f, a}, ctx) do
    {erased_f, f_type} = synth(f, ctx)

    case f_type do
      {:pi, :zero, _dom, cod} ->
        result_type = Core.subst(cod, 0, a)
        {erased_f, result_type}

      {:pi, :omega, dom, cod} ->
        erased_a = check(a, dom, ctx)
        result_type = Core.subst(cod, 0, a)
        {{:app, erased_f, erased_a}, result_type}
    end
  end

  # Literals: known types.
  defp synth({:lit, v}, _ctx) when is_integer(v), do: {{:lit, v}, {:builtin, :Int}}
  defp synth({:lit, v}, _ctx) when is_float(v), do: {{:lit, v}, {:builtin, :Float}}
  defp synth({:lit, v}, _ctx) when is_binary(v), do: {{:lit, v}, {:builtin, :String}}
  defp synth({:lit, true}, _ctx), do: {{:lit, true}, {:builtin, :Atom}}
  defp synth({:lit, false}, _ctx), do: {{:lit, false}, {:builtin, :Atom}}
  defp synth({:lit, v}, _ctx) when is_atom(v), do: {{:lit, v}, {:builtin, :Atom}}

  # Builtins: known types.
  defp synth({:builtin, name}, _ctx), do: {{:builtin, name}, builtin_type(name)}

  # Extern: cannot synthesize type without external info.
  defp synth({:extern, mod, fun, arity}, _ctx) do
    raise Haruspex.CompilerBug,
          "cannot synthesize type of extern #{inspect(mod)}.#{fun}/#{arity} during erasure; " <>
            "externs should be erased in check mode with a known type"
  end

  # Definition reference: treat similarly to global — build an omega-only type from arity.
  defp synth({:def_ref, name}, _ctx) do
    # def_ref doesn't carry arity info; treat as opaque runtime value.
    {{:def_ref, name}, {:type, {:llit, 0}}}
  end

  # Global: synthesize an omega-only pi type from the arity.
  # Cross-module globals have already had erased params handled at the import boundary.
  defp synth({:global, _mod, _name, arity} = term, _ctx) do
    type = build_omega_type(arity)
    {term, type}
  end

  # Let: synthesize both parts, eliminate if type-level.
  defp synth({:let, def_val, body}, ctx) do
    {erased_def, def_type} = synth(def_val, ctx)

    if type_level?(def_type) do
      {erased_body, body_type} = synth(body, push(ctx, def_type))
      {Core.subst(erased_body, 0, :erased), body_type}
    else
      {erased_body, body_type} = synth(body, push(ctx, def_type))
      {{:let, erased_def, erased_body}, body_type}
    end
  end

  # Pair: synthesize first element, derive Sigma for second.
  defp synth({:pair, a, b}, ctx) do
    {erased_a, a_type} = synth(a, ctx)
    {erased_b, b_type} = synth(b, ctx)
    sigma_type = {:sigma, a_type, Core.shift(b_type, 1, 0)}
    {{:pair, erased_a, erased_b}, sigma_type}
  end

  # Projections: synthesize the pair, extract component types.
  defp synth({:fst, e}, ctx) do
    {erased_e, e_type} = synth(e, ctx)

    case e_type do
      {:sigma, a_type, _b_type} -> {{:fst, erased_e}, a_type}
    end
  end

  defp synth({:snd, e}, ctx) do
    {erased_e, e_type} = synth(e, ctx)

    case e_type do
      {:sigma, _a_type, b_type} ->
        {{:snd, erased_e}, Core.subst(b_type, 0, {:fst, e})}
    end
  end

  # Span: strip and recurse.
  defp synth({:spanned, _span, inner}, ctx), do: synth(inner, ctx)

  # Type-level terms in synth mode.
  defp synth({:pi, _, _, _}, _ctx), do: {:erased, {:type, {:llit, 0}}}
  defp synth({:sigma, _, _}, _ctx), do: {:erased, {:type, {:llit, 0}}}
  defp synth({:type, l}, _ctx), do: {:erased, {:type, {:lsucc, l}}}

  # Data type: type-level.
  defp synth({:data, _, _}, _ctx), do: {:erased, {:type, {:llit, 0}}}

  # Record projection: erase inner, return a runtime type placeholder.
  defp synth({:record_proj, field, expr}, ctx) do
    erased_expr = synth_and_erase(expr, ctx)
    # We don't track exact field types through erasure. Use a placeholder.
    {{:record_proj, field, erased_expr}, {:type, {:llit, 0}}}
  end

  # Constructor: keep field args, return the data type.
  defp synth({:con, type_name, con_name, args}, ctx) do
    erased_args = Enum.map(args, fn a -> synth_and_erase(a, ctx) end)
    # The return type is the data type (we don't track exact applied type in erasure).
    {{:con, type_name, con_name, erased_args}, {:data, type_name, []}}
  end

  # Case: erase scrutinee and branches.
  defp synth({:case, scrutinee, branches}, ctx) do
    {erased_scrut, _scrut_type} = synth(scrutinee, ctx)

    erased_branches =
      Enum.map(branches, fn
        {:__lit, value, body} ->
          {erased_body, _body_type} = synth(body, ctx)
          {:__lit, value, erased_body}

        {con_name, arity, body} ->
          inner_ctx = Enum.reduce(1..arity//1, ctx, fn _, c -> push(c, {:type, {:llit, 0}}) end)
          {erased_body, _body_type} = synth(body, inner_ctx)
          {con_name, arity, erased_body}
      end)

    # Use the type of the first branch body as the result type.
    result_type =
      case branches do
        [{:__lit, _value, body} | _] ->
          {_erased, body_type} = synth(body, ctx)
          body_type

        [{_cn, arity, body} | _] ->
          inner_ctx = Enum.reduce(1..arity//1, ctx, fn _, c -> push(c, {:type, {:llit, 0}}) end)
          {_erased, body_type} = synth(body, inner_ctx)
          body_type

        [] ->
          {:type, {:llit, 0}}
      end

    {{:case, erased_scrut, erased_branches}, result_type}
  end

  # Unsolved metas in synth mode.
  defp synth({:meta, id}, _ctx) do
    raise Haruspex.CompilerBug, "unsolved meta #{id} reached erasure"
  end

  defp synth({:inserted_meta, id, _mask}, _ctx) do
    raise Haruspex.CompilerBug, "unsolved inserted meta #{id} reached erasure"
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Synth a term and return just the erased form.
  defp synth_and_erase(term, ctx) do
    {erased, _type} = synth(term, ctx)
    erased
  end

  defp push(%__MODULE__{types: types} = ctx, type) do
    %{ctx | types: [type | types]}
  end

  # A type is type-level if it inhabits a universe.
  defp type_level?({:type, _}), do: true
  defp type_level?(_), do: false

  # Builtin type builtins are types themselves (Type -> Type).
  defp builtin_type(:Int), do: {:type, {:llit, 0}}
  defp builtin_type(:Float), do: {:type, {:llit, 0}}
  defp builtin_type(:String), do: {:type, {:llit, 0}}
  defp builtin_type(:Bool), do: {:type, {:llit, 0}}
  defp builtin_type(:Atom), do: {:type, {:llit, 0}}

  # Arithmetic: Int -> Int -> Int.
  defp builtin_type(name) when name in [:add, :sub, :mul, :div] do
    int = {:builtin, :Int}
    {:pi, :omega, int, {:pi, :omega, int, int}}
  end

  # Float arithmetic: Float -> Float -> Float.
  defp builtin_type(name) when name in [:fadd, :fsub, :fmul, :fdiv] do
    flt = {:builtin, :Float}
    {:pi, :omega, flt, {:pi, :omega, flt, flt}}
  end

  # Negation: Int -> Int.
  defp builtin_type(:neg), do: {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}

  # Boolean not: Atom -> Atom.
  defp builtin_type(:not), do: {:pi, :omega, {:builtin, :Atom}, {:builtin, :Atom}}

  # Comparison: Int -> Int -> Atom.
  defp builtin_type(name) when name in [:eq, :neq, :lt, :gt, :lte, :gte] do
    int = {:builtin, :Int}
    {:pi, :omega, int, {:pi, :omega, int, {:builtin, :Atom}}}
  end

  # Boolean ops: Atom -> Atom -> Atom.
  defp builtin_type(name) when name in [:and, :or] do
    atom = {:builtin, :Atom}
    {:pi, :omega, atom, {:pi, :omega, atom, atom}}
  end

  # Fallback for unknown builtins: treat as type.
  defp builtin_type(_name), do: {:type, {:llit, 0}}

  # Build a type with N omega pi params. The exact domain/codomain types don't
  # matter for erasure — we only need the multiplicity structure.
  defp build_omega_type(0), do: {:type, {:llit, 0}}

  defp build_omega_type(n) when n > 0 do
    {:pi, :omega, {:type, {:llit, 0}}, build_omega_type(n - 1)}
  end
end
