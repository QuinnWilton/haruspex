defmodule Haruspex.Core do
  @moduledoc """
  Core term representation using de Bruijn indices.

  All terms after elaboration are represented as tagged tuples with explicit
  metavariables, universe levels, and multiplicity annotations. This is the
  language that the type checker, NbE, and codegen operate on.
  """

  # ============================================================================
  # Types
  # ============================================================================

  @type ix :: non_neg_integer()
  @type meta_id :: non_neg_integer()
  @type mult :: :zero | :omega

  @type level ::
          {:lvar, non_neg_integer()}
          | {:llit, non_neg_integer()}
          | {:lmax, level(), level()}
          | {:lsucc, level()}

  @type literal :: integer() | float() | String.t() | atom() | boolean()

  @type expr ::
          {:var, ix()}
          | {:lam, mult(), expr()}
          | {:app, expr(), expr()}
          | {:pi, mult(), expr(), expr()}
          | {:sigma, expr(), expr()}
          | {:pair, expr(), expr()}
          | {:fst, expr()}
          | {:snd, expr()}
          | {:let, expr(), expr()}
          | {:type, level()}
          | {:lit, literal()}
          | {:builtin, atom()}
          | {:extern, module(), atom(), arity()}
          | {:global, module(), atom(), arity()}
          | {:meta, meta_id()}
          | {:inserted_meta, meta_id(), [boolean()]}
          | {:spanned, Pentiment.Span.Byte.t(), expr()}
          | {:data, atom(), [expr()]}
          | {:con, atom(), atom(), [expr()]}
          | {:case, expr(), [{atom(), non_neg_integer(), expr()}]}
          | :erased

  # ============================================================================
  # Constructors
  # ============================================================================

  @spec var(ix()) :: expr()
  def var(ix), do: {:var, ix}

  @spec lam(mult(), expr()) :: expr()
  def lam(mult, body), do: {:lam, mult, body}

  @spec app(expr(), expr()) :: expr()
  def app(f, a), do: {:app, f, a}

  @spec pi(mult(), expr(), expr()) :: expr()
  def pi(mult, dom, cod), do: {:pi, mult, dom, cod}

  @spec sigma(expr(), expr()) :: expr()
  def sigma(a, b), do: {:sigma, a, b}

  @spec pair(expr(), expr()) :: expr()
  def pair(a, b), do: {:pair, a, b}

  @spec fst(expr()) :: expr()
  def fst(e), do: {:fst, e}

  @spec snd(expr()) :: expr()
  def snd(e), do: {:snd, e}

  @spec let_(expr(), expr()) :: expr()
  def let_(def_val, body), do: {:let, def_val, body}

  @spec type(level()) :: expr()
  def type(level), do: {:type, level}

  @spec lit(literal()) :: expr()
  def lit(value), do: {:lit, value}

  @spec builtin(atom()) :: expr()
  def builtin(name), do: {:builtin, name}

  @spec extern(module(), atom(), arity()) :: expr()
  def extern(mod, fun, arity), do: {:extern, mod, fun, arity}

  @spec global(module(), atom(), arity()) :: expr()
  def global(mod, name, arity), do: {:global, mod, name, arity}

  @spec meta(meta_id()) :: expr()
  def meta(id), do: {:meta, id}

  @spec inserted_meta(meta_id(), [boolean()]) :: expr()
  def inserted_meta(id, mask), do: {:inserted_meta, id, mask}

  @spec spanned(Pentiment.Span.Byte.t(), expr()) :: expr()
  def spanned(span, expr), do: {:spanned, span, expr}

  # ============================================================================
  # Substitution
  # ============================================================================

  @doc """
  Substitute `replacement` for variable at de Bruijn index `target` in `term`.

  Shifts the replacement when going under binders to maintain correct indices.
  """
  @spec subst(expr(), ix(), expr()) :: expr()
  def subst(term, target, replacement)

  def subst({:var, ix}, target, replacement) do
    cond do
      ix == target -> replacement
      ix > target -> {:var, ix - 1}
      true -> {:var, ix}
    end
  end

  def subst({:lam, mult, body}, target, replacement) do
    {:lam, mult, subst(body, target + 1, shift(replacement, 1, 0))}
  end

  def subst({:app, f, a}, target, replacement) do
    {:app, subst(f, target, replacement), subst(a, target, replacement)}
  end

  def subst({:pi, mult, dom, cod}, target, replacement) do
    {:pi, mult, subst(dom, target, replacement), subst(cod, target + 1, shift(replacement, 1, 0))}
  end

  def subst({:sigma, a, b}, target, replacement) do
    {:sigma, subst(a, target, replacement), subst(b, target + 1, shift(replacement, 1, 0))}
  end

  def subst({:pair, a, b}, target, replacement) do
    {:pair, subst(a, target, replacement), subst(b, target, replacement)}
  end

  def subst({:fst, e}, target, replacement) do
    {:fst, subst(e, target, replacement)}
  end

  def subst({:snd, e}, target, replacement) do
    {:snd, subst(e, target, replacement)}
  end

  def subst({:let, def_val, body}, target, replacement) do
    {:let, subst(def_val, target, replacement), subst(body, target + 1, shift(replacement, 1, 0))}
  end

  def subst({:spanned, span, inner}, target, replacement) do
    {:spanned, span, subst(inner, target, replacement)}
  end

  def subst(:erased, _target, _replacement), do: :erased

  def subst(term, _target, _replacement)
      when elem(term, 0) in [:type, :lit, :builtin, :extern, :global, :meta, :inserted_meta] do
    term
  end

  # ============================================================================
  # Shifting
  # ============================================================================

  @doc """
  Shift free variable indices >= `cutoff` by `amount`.

  Used internally by substitution to maintain correct de Bruijn indices
  when going under binders.
  """
  @spec shift(expr(), integer(), ix()) :: expr()
  def shift(term, amount, cutoff)

  def shift({:var, ix}, amount, cutoff) do
    if ix >= cutoff, do: {:var, ix + amount}, else: {:var, ix}
  end

  def shift({:lam, mult, body}, amount, cutoff) do
    {:lam, mult, shift(body, amount, cutoff + 1)}
  end

  def shift({:app, f, a}, amount, cutoff) do
    {:app, shift(f, amount, cutoff), shift(a, amount, cutoff)}
  end

  def shift({:pi, mult, dom, cod}, amount, cutoff) do
    {:pi, mult, shift(dom, amount, cutoff), shift(cod, amount, cutoff + 1)}
  end

  def shift({:sigma, a, b}, amount, cutoff) do
    {:sigma, shift(a, amount, cutoff), shift(b, amount, cutoff + 1)}
  end

  def shift({:pair, a, b}, amount, cutoff) do
    {:pair, shift(a, amount, cutoff), shift(b, amount, cutoff)}
  end

  def shift({:fst, e}, amount, cutoff) do
    {:fst, shift(e, amount, cutoff)}
  end

  def shift({:snd, e}, amount, cutoff) do
    {:snd, shift(e, amount, cutoff)}
  end

  def shift({:let, def_val, body}, amount, cutoff) do
    {:let, shift(def_val, amount, cutoff), shift(body, amount, cutoff + 1)}
  end

  def shift({:spanned, span, inner}, amount, cutoff) do
    {:spanned, span, shift(inner, amount, cutoff)}
  end

  def shift(:erased, _amount, _cutoff), do: :erased

  def shift(term, _amount, _cutoff)
      when elem(term, 0) in [:type, :lit, :builtin, :extern, :global, :meta, :inserted_meta] do
    term
  end
end
