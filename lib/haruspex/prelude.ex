defmodule Haruspex.Prelude do
  @moduledoc """
  Auto-imported prelude for Haruspex source files.

  Provides the builtin type names and primitive operations that are available
  in every Haruspex source file by default. A file can opt out with the
  `@no_prelude` annotation.

  ## Provided names

  **Types**: `Int`, `Float`, `String`, `Atom`, `Bool`

  **Arithmetic**: `add`, `sub`, `mul`, `div`, `neg`

  **Float arithmetic**: `fadd`, `fsub`, `fmul`, `fdiv`

  **Comparison**: `eq`, `neq`, `lt`, `gt`, `lte`, `gte`

  **Boolean**: `not`, `and`, `or`
  """

  # Operators migrated to type classes (Num, Eq, Ord) are no longer in the
  # builtin table. They resolve through instance search at elaboration time
  # for literal operands, and through the checker's class method lookup for
  # variable operands. The binop syntax (e.g., `x + y`) still produces
  # {:builtin, :add} core terms directly without needing name resolution.
  @builtins %{
    Int: {:builtin, :Int},
    Float: {:builtin, :Float},
    String: {:builtin, :String},
    Atom: {:builtin, :Atom},
    Bool: {:builtin, :Bool},
    # add, sub, mul — resolved via Num class
    # eq — resolved via Eq class
    div: {:builtin, :div},
    neg: {:builtin, :neg},
    not: {:builtin, :not},
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
