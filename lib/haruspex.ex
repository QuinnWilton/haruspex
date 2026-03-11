defmodule Haruspex do
  @moduledoc """
  A dependently typed language with Elixir-like syntax, targeting the BEAM.

  Haruspex implements bidirectional type checking with normalization-by-evaluation,
  implicit argument inference via pattern unification, a stratified universe
  hierarchy, and compilation to Elixir/BEAM via code generation.

  ## Pipeline

      source text → tokenize → parse → elaborate → check → optimize → codegen → eval

  Built on roux for incremental computation, pentiment for source spans,
  constrain for refinement type discharge, and quail for e-graph optimization.
  """

  @behaviour Roux.Lang
  use Roux.Query

  # ============================================================================
  # Roux.Lang behaviour
  # ============================================================================

  @impl Roux.Lang
  def file_extensions, do: [".hx"]

  @impl Roux.Lang
  def compile_query, do: :haruspex_compile

  @impl Roux.Lang
  def diagnostics_query, do: :haruspex_diagnostics

  @impl Roux.Lang
  def hover_query, do: :haruspex_hover

  @impl Roux.Lang
  def definition_query, do: :haruspex_definition

  @impl Roux.Lang
  def completions_query, do: :haruspex_completions

  @impl Roux.Lang
  def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

  @impl Roux.Lang
  def prepare(_db, _source_paths), do: :ok

  # ============================================================================
  # Roux inputs, entities, and queries
  # ============================================================================

  definput(:source_text, durability: :low)

  # Queries and entities will be defined as subsystems are implemented.
end
