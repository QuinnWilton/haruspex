defmodule Haruspex.MutualGroup do
  @moduledoc """
  Roux entity for a mutual definition group.

  Groups definitions that are mutually recursive and must be checked
  together. Identity is `{uri, group_id}`.
  """

  use Roux.Entity,
    identity: [:uri, :group_id],
    tracked: [:definitions]
end
