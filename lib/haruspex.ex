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

  alias Haruspex.Definition

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

  defentity(Haruspex.Definition)
  defentity(Haruspex.MutualGroup)

  @doc """
  Parse a source file, creating `Definition` entities for each top-level def.
  Returns `{:ok, [entity_id]}`.
  """
  defquery :haruspex_parse, key: uri do
    source = Roux.Runtime.input(db, :source_text, uri)

    case Haruspex.Parser.parse(source) do
      {:ok, defs} ->
        entity_ids =
          Enum.flat_map(defs, fn
            {:def, span, {:sig, _sig_span, name, name_span, _params, _ret, attrs} = _sig, _body} =
                def_ast ->
              entity_id =
                Roux.Runtime.create(db, Definition, %{
                  uri: uri,
                  name: name,
                  surface_ast: def_ast,
                  type: nil,
                  body: nil,
                  total?: Map.get(attrs, :total, false),
                  extern: Map.get(attrs, :extern),
                  span: span,
                  name_span: name_span
                })

              [entity_id]

            # Skip non-def top-level forms for now.
            _ ->
              []
          end)

        {:ok, entity_ids}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Elaborate a single definition's type and body into core terms.
  Returns `{:ok, {type_core, body_core}}`.
  """
  defquery :haruspex_elaborate, key: {uri, name} do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    entity_id = find_entity(db, entity_ids, name)
    def_ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)

    ctx = Haruspex.Elaborate.new()

    case Haruspex.Elaborate.elaborate_def(ctx, def_ast) do
      {:ok, {^name, type_core, body_core}, _ctx} ->
        {:ok, {type_core, body_core}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Type-check a single definition. Returns `{:ok, {type_core, body_core}}`.
  """
  defquery :haruspex_check, key: {uri, name} do
    {:ok, {type_core, body_core}} = Roux.Runtime.query!(db, :haruspex_elaborate, {uri, name})

    ctx = Haruspex.Check.new()

    case Haruspex.Check.check_definition(ctx, name, type_core, body_core) do
      {:ok, checked_body, _ctx} ->
        {:ok, {type_core, checked_body}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Compile all definitions in a file to an Elixir module AST.
  Returns `{:ok, Macro.t()}`.
  """
  defquery :haruspex_codegen, key: uri do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    definitions =
      Enum.map(entity_ids, fn entity_id ->
        name = Roux.Runtime.field(db, Definition, entity_id, :name)
        {:ok, {type_core, body_core}} = Roux.Runtime.query!(db, :haruspex_check, {uri, name})
        {name, type_core, body_core}
      end)

    module_name = module_name_from_uri(uri)
    ast = Haruspex.Codegen.compile_module(module_name, :all, definitions)
    {:ok, ast}
  end

  @doc """
  Full compilation: parse → elaborate → check → codegen → eval.
  Returns `{:ok, module_name}`.
  """
  defquery :haruspex_compile, key: uri do
    {:ok, ast} = Roux.Runtime.query!(db, :haruspex_codegen, uri)
    {{:module, module, _, _}, _} = Code.eval_quoted(ast)
    {:ok, module}
  end

  @doc """
  Collect diagnostics for all definitions in a file.
  Returns a list of diagnostic maps.
  """
  defquery :haruspex_diagnostics, key: uri do
    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        Enum.flat_map(entity_ids, fn entity_id ->
          name = Roux.Runtime.field(db, Definition, entity_id, :name)

          case Roux.Runtime.query(db, :haruspex_check, {uri, name}) do
            {:ok, _} -> []
            {:error, reason} -> [error_to_diagnostic(reason)]
          end
        end)

      {:error, reasons} when is_list(reasons) ->
        Enum.map(reasons, &error_to_diagnostic/1)

      {:error, reason} ->
        [error_to_diagnostic(reason)]
    end
  end

  # ============================================================================
  # Stubs for later tiers
  # ============================================================================

  defquery :haruspex_totality, key: key do
    _ = {db, key}
    {:error, :not_implemented}
  end

  defquery :haruspex_hover, key: key do
    _ = {db, key}
    nil
  end

  defquery :haruspex_definition, key: key do
    _ = {db, key}
    nil
  end

  defquery :haruspex_completions, key: key do
    _ = {db, key}
    []
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp find_entity(db, entity_ids, name) do
    Enum.find(entity_ids, fn entity_id ->
      Roux.Runtime.field(db, Definition, entity_id, :name) == name
    end) || raise Haruspex.CompilerBug, "definition #{name} not found in parsed entities"
  end

  defp module_name_from_uri(uri) do
    uri
    |> Path.rootname()
    |> Path.split()
    |> Enum.map(&Macro.camelize/1)
    |> Module.concat()
  end

  @spec error_to_diagnostic(term()) :: map()
  defp error_to_diagnostic({:parse_error, message, span}) do
    %{severity: :error, message: message, span: span}
  end

  defp error_to_diagnostic({:unbound_variable, name, span}) do
    %{severity: :error, message: "unbound variable: #{name}", span: span}
  end

  defp error_to_diagnostic({:missing_return_type, name, span}) do
    %{severity: :error, message: "missing return type for #{name}", span: span}
  end

  defp error_to_diagnostic({:extern_arity_mismatch, name, mod, fun, expected, actual}) do
    %{
      severity: :error,
      message:
        "extern arity mismatch for #{name}: #{inspect(mod)}.#{fun} expects #{expected} args but type has #{actual}",
      span: nil
    }
  end

  defp error_to_diagnostic({:type_mismatch, _details} = reason) do
    %{severity: :error, message: "type mismatch: #{inspect(reason)}", span: nil}
  end

  defp error_to_diagnostic(reason) do
    %{severity: :error, message: inspect(reason), span: nil}
  end
end
