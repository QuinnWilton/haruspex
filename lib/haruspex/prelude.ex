defmodule Haruspex.Prelude do
  @moduledoc """
  Auto-imported prelude for Haruspex source files.

  Provides the builtin type names and primitive operations that are available
  in every Haruspex source file by default. A file can opt out with the
  `@no_prelude` annotation.

  ## Provided names

  **Types**: `Int`, `Float`, `String`, `Atom`

  **Arithmetic**: `add`, `sub`, `mul`, `div`, `neg`

  **Float arithmetic**: `fadd`, `fsub`, `fmul`, `fdiv`

  **Comparison**: `eq`, `neq`, `lt`, `gt`, `lte`, `gte`

  **Boolean**: `not`, `and`, `or`
  """

  @builtins %{
    Int: {:builtin, :Int},
    Float: {:builtin, :Float},
    String: {:builtin, :String},
    Atom: {:builtin, :Atom},
    add: {:builtin, :add},
    sub: {:builtin, :sub},
    mul: {:builtin, :mul},
    div: {:builtin, :div},
    neg: {:builtin, :neg},
    not: {:builtin, :not},
    eq: {:builtin, :eq},
    neq: {:builtin, :neq},
    lt: {:builtin, :lt},
    gt: {:builtin, :gt},
    lte: {:builtin, :lte},
    gte: {:builtin, :gte},
    and: {:builtin, :and},
    or: {:builtin, :or},
    fadd: {:builtin, :fadd},
    fsub: {:builtin, :fsub},
    fmul: {:builtin, :fmul},
    fdiv: {:builtin, :fdiv}
  }

  @doc """
  Return the prelude name→core mapping.
  """
  @spec builtins() :: %{atom() => {:builtin, atom()}}
  def builtins, do: @builtins

  @doc """
  Return the list of prelude names.
  """
  @spec names() :: [atom()]
  def names, do: Map.keys(@builtins)
end
