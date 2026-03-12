defmodule Haruspex.Definition do
  @moduledoc """
  Roux entity for a top-level Haruspex definition.

  Identity is `{uri, name}` — a definition is uniquely identified by which
  file it lives in and its name. Tracked fields carry elaborated and checked
  data that may change when source changes.
  """

  use Roux.Entity,
    identity: [:uri, :name],
    tracked: [:surface_ast, :type, :body, :total?, :extern, :span, :name_span]
end
