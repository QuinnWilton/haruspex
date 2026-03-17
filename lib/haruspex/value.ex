defmodule Haruspex.Value do
  @moduledoc """
  Value domain for normalization-by-evaluation.

  Values are the semantic domain that core terms evaluate into. They represent
  terms in weak head normal form with closures for binders. Neutral values
  represent stuck computations (free variables, unsolved metas, stuck applications).

  Each `vneutral` carries its type so that readback can eta-expand at Pi and Sigma types.
  """

  alias Haruspex.Core

  # ============================================================================
  # Types
  # ============================================================================

  @type env :: [value()]
  @type lvl :: non_neg_integer()

  @type value ::
          {:vlam, Core.mult(), env(), Core.expr()}
          | {:vpi, Core.mult(), value(), env(), Core.expr()}
          | {:vsigma, value(), env(), Core.expr()}
          | {:vpair, value(), value()}
          | {:vtype, Core.level()}
          | {:vlit, Core.literal()}
          | {:vbuiltin, atom() | {atom(), [value()]}}
          | {:vextern, module(), atom(), arity()}
          | {:vneutral, value(), neutral()}
          | {:vdata, atom(), [value()]}
          | {:vcon, atom(), atom(), [value()]}

  @type neutral ::
          {:nvar, lvl()}
          | {:napp, neutral(), value()}
          | {:nfst, neutral()}
          | {:nsnd, neutral()}
          | {:nmeta, Core.meta_id()}
          | {:ndef, atom(), [value()]}
          | {:nbuiltin, atom()}
          | {:ndef_ref, atom()}
          | {:ncase, neutral(), [{atom(), non_neg_integer(), {env(), Core.expr()}}]}

  # ============================================================================
  # Constructors
  # ============================================================================

  @spec vlam(Core.mult(), env(), Core.expr()) :: value()
  def vlam(mult, env, body), do: {:vlam, mult, env, body}

  @spec vpi(Core.mult(), value(), env(), Core.expr()) :: value()
  def vpi(mult, dom, env, cod), do: {:vpi, mult, dom, env, cod}

  @spec vsigma(value(), env(), Core.expr()) :: value()
  def vsigma(a, env, b), do: {:vsigma, a, env, b}

  @spec vpair(value(), value()) :: value()
  def vpair(a, b), do: {:vpair, a, b}

  @spec vtype(Core.level()) :: value()
  def vtype(level), do: {:vtype, level}

  @spec vlit(Core.literal()) :: value()
  def vlit(value), do: {:vlit, value}

  @spec vbuiltin(atom()) :: value()
  def vbuiltin(name), do: {:vbuiltin, name}

  @spec vextern(module(), atom(), arity()) :: value()
  def vextern(mod, fun, arity), do: {:vextern, mod, fun, arity}

  @spec vneutral(value(), neutral()) :: value()
  def vneutral(type, neutral), do: {:vneutral, type, neutral}

  @spec nvar(lvl()) :: neutral()
  def nvar(level), do: {:nvar, level}

  @spec napp(neutral(), value()) :: neutral()
  def napp(neutral, arg), do: {:napp, neutral, arg}

  @spec nfst(neutral()) :: neutral()
  def nfst(neutral), do: {:nfst, neutral}

  @spec nsnd(neutral()) :: neutral()
  def nsnd(neutral), do: {:nsnd, neutral}

  @spec nmeta(Core.meta_id()) :: neutral()
  def nmeta(id), do: {:nmeta, id}

  @spec vdata(atom(), [value()]) :: value()
  def vdata(name, args), do: {:vdata, name, args}

  @spec vcon(atom(), atom(), [value()]) :: value()
  def vcon(type_name, con_name, args), do: {:vcon, type_name, con_name, args}

  # ============================================================================
  # Variable creation
  # ============================================================================

  @doc """
  Create a fresh variable at the given de Bruijn level with the given type.
  """
  @spec fresh_var(lvl(), value()) :: value()
  def fresh_var(level, type) do
    {:vneutral, type, {:nvar, level}}
  end
end
