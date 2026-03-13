defmodule Haruspex.FileInfo do
  @moduledoc """
  Roux entity for file-level metadata.

  Identity is `{uri}` — one per source file. Tracked fields carry
  import declarations and other file-level data extracted during parsing.
  """

  use Roux.Entity,
    identity: [:uri],
    tracked: [:imports]
end
