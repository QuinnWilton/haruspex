defmodule Haruspex.CompilerBug do
  @moduledoc """
  Raised when an internal invariant is violated.

  These errors indicate a bug in the compiler, not in user code.
  """

  defexception [:message]

  @impl Exception
  def exception(message) when is_binary(message) do
    %__MODULE__{message: "compiler bug: " <> message}
  end
end
