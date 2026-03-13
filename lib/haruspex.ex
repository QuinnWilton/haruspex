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
  alias Haruspex.FileInfo

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
  defentity(Haruspex.FileInfo)
  defentity(Haruspex.MutualGroup)

  @doc """
  Parse a source file, creating `Definition` entities for each top-level def
  and a `FileInfo` entity for file-level metadata (imports).
  Returns `{:ok, [entity_id]}`.
  """
  defquery :haruspex_parse, key: uri do
    source = Roux.Runtime.input(db, :source_text, uri)

    case Haruspex.Parser.parse(source) do
      {:ok, top_level_forms} ->
        {entity_ids, imports, no_prelude?, type_decls, record_decls, mutual_groups} =
          collect_top_level(db, uri, top_level_forms)

        # Store file-level metadata.
        Roux.Runtime.create(db, FileInfo, %{
          uri: uri,
          imports: imports,
          no_prelude?: no_prelude?,
          type_decls: type_decls,
          record_decls: record_decls,
          mutual_groups: mutual_groups
        })

        {:ok, entity_ids}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Return the import declarations for a file.
  Returns a list of `%{module_path: [atom()], open: open_option}` maps.
  Depends on `haruspex_parse` to populate the `FileInfo` entity.
  """
  defquery :haruspex_file_imports, key: uri do
    # Ensure the file has been parsed (creates the FileInfo entity).
    {:ok, _entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    # Read imports from the FileInfo entity.
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        Roux.Runtime.field(db, FileInfo, file_info_id, :imports)

      :error ->
        []
    end
  end

  @doc """
  Elaborate all type and record declarations for a file.
  Returns `{:ok, {adts, records}}` where both are maps keyed by type name.
  """
  defquery :haruspex_elaborate_types, key: uri do
    {:ok, _entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    {type_decls, record_decls} =
      case Roux.Runtime.lookup(db, FileInfo, {uri}) do
        {:ok, file_info_id} ->
          tds = Roux.Runtime.field(db, FileInfo, file_info_id, :type_decls) || []
          rds = Roux.Runtime.field(db, FileInfo, file_info_id, :record_decls) || []
          {tds, rds}

        :error ->
          {[], []}
      end

    imports = Roux.Runtime.query(db, :haruspex_file_imports, uri)
    no_prelude? = file_no_prelude?(db, uri)

    ctx =
      Haruspex.Elaborate.new(
        db: db,
        uri: uri,
        imports: imports,
        source_roots: source_roots(),
        no_prelude?: no_prelude?
      )

    # Elaborate type declarations first (order matters for mutual references).
    ctx =
      Enum.reduce(type_decls, ctx, fn td, ctx ->
        {:ok, _decl, ctx} = Haruspex.Elaborate.elaborate_type_decl(ctx, td)
        ctx
      end)

    # Then record declarations.
    ctx =
      Enum.reduce(record_decls, ctx, fn rd, ctx ->
        {:ok, _decl, ctx} = Haruspex.Elaborate.elaborate_record_decl(ctx, rd)
        ctx
      end)

    {:ok, {ctx.adts, ctx.records}}
  end

  @doc """
  Elaborate a single definition's type and body into core terms.
  Returns `{:ok, {type_core, body_core}}`.

  For definitions in a mutual group, delegates to `haruspex_elaborate_mutual`
  which elaborates all group members together.
  """
  defquery :haruspex_elaborate, key: {uri, name} do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    # Check if this def belongs to a mutual group.
    mutual_groups = file_mutual_groups(db, uri)
    group = Enum.find(mutual_groups, fn names -> name in names end)

    if group do
      # Elaborate the whole mutual group, then extract this def's result.
      {:ok, results} = Roux.Runtime.query!(db, :haruspex_elaborate_mutual, {uri, group})
      {^name, type_core, body_core} = Enum.find(results, fn {n, _, _} -> n == name end)
      {:ok, {type_core, body_core}}
    else
      entity_id = find_entity(db, entity_ids, name)
      def_ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)

      ctx = make_elaborate_ctx(db, uri)

      case Haruspex.Elaborate.elaborate_def(ctx, def_ast) do
        {:ok, {^name, type_core, body_core}, _ctx} ->
          update_entity(db, entity_id, %{type: type_core, body: body_core})
          {:ok, {type_core, body_core}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Elaborate a mutual group of definitions together.
  Returns `{:ok, [{name, type_core, body_core}, ...]}`.
  """
  defquery :haruspex_elaborate_mutual, key: {uri, group_names} do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    def_asts =
      Enum.map(group_names, fn name ->
        entity_id = find_entity(db, entity_ids, name)
        Roux.Runtime.field(db, Definition, entity_id, :surface_ast)
      end)

    ctx = make_elaborate_ctx(db, uri)

    case Haruspex.Mutual.elaborate_mutual(ctx, def_asts) do
      {:ok, results, _ctx} ->
        # Write results back to entities.
        Enum.each(results, fn {name, type_core, body_core} ->
          entity_id = find_entity(db, entity_ids, name)
          update_entity(db, entity_id, %{type: type_core, body: body_core})
        end)

        {:ok, results}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Type-check a single definition. Returns `{:ok, {type_core, body_core}}`.
  """
  defquery :haruspex_check, key: {uri, name} do
    {:ok, {type_core, body_core}} = Roux.Runtime.query!(db, :haruspex_elaborate, {uri, name})
    {:ok, {adts, records}} = Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)

    ctx = %{Haruspex.Check.new() | db: db, adts: adts, records: records}

    # Check if this def belongs to a mutual group.
    mutual_groups = file_mutual_groups(db, uri)
    group = Enum.find(mutual_groups, fn names -> name in names end)

    check_result =
      if group do
        # Get all sibling types for mutual checking.
        all_sigs =
          Enum.map(group, fn sib_name ->
            {:ok, {sib_type, _}} =
              Roux.Runtime.query!(db, :haruspex_elaborate, {uri, sib_name})

            {sib_name, sib_type}
          end)

        Haruspex.Check.check_mutual_definition(ctx, name, type_core, body_core, all_sigs)
      else
        Haruspex.Check.check_definition(ctx, name, type_core, body_core)
      end

    case check_result do
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

    {:ok, {adts, records}} = Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)
    mutual_groups = file_mutual_groups(db, uri)
    module_name = module_name_from_uri(uri, source_roots())

    ast =
      Haruspex.Codegen.compile_module(module_name, :all, definitions, %{
        adts: adts,
        records: records,
        mutual_groups: mutual_groups
      })

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
  # Configuration
  # ============================================================================

  @doc false
  @spec source_roots() :: [String.t()]
  def source_roots do
    Application.get_env(:haruspex, :source_roots, ["lib"])
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Partition top-level forms into Definition entities, import declarations,
  # type/record declarations, mutual groups, and file-level flags.
  @spec collect_top_level(term(), String.t(), [term()]) ::
          {[term()], [term()], boolean(), [term()], [term()], [[atom()]]}
  defp collect_top_level(db, uri, forms) do
    Enum.reduce(forms, {[], [], false, [], [], []}, fn
      {:def, span, {:sig, _sig_span, name, name_span, _params, _ret, attrs} = _sig, _body} =
          def_ast,
      {ids, imports, no_prelude?, tds, rds, mgs} ->
        entity_id =
          Roux.Runtime.create(db, Definition, %{
            uri: uri,
            name: name,
            surface_ast: def_ast,
            type: nil,
            body: nil,
            total?: Map.get(attrs, :total, false),
            private?: Map.get(attrs, :private, false),
            extern: Map.get(attrs, :extern),
            erased_params: nil,
            span: span,
            name_span: name_span
          })

        {ids ++ [entity_id], imports, no_prelude?, tds, rds, mgs}

      {:import, _span, module_path, open_option}, {ids, imports, no_prelude?, tds, rds, mgs} ->
        {ids, imports ++ [%{module_path: module_path, open: open_option}], no_prelude?, tds, rds,
         mgs}

      {:no_prelude, _span}, {ids, imports, _no_prelude?, tds, rds, mgs} ->
        {ids, imports, true, tds, rds, mgs}

      {:type_decl, _, _, _, _} = td, {ids, imports, no_prelude?, tds, rds, mgs} ->
        {ids, imports, no_prelude?, tds ++ [td], rds, mgs}

      {:record_decl, _, _, _, _} = rd, {ids, imports, no_prelude?, tds, rds, mgs} ->
        {ids, imports, no_prelude?, tds, rds ++ [rd], mgs}

      {:mutual, _span, defs}, {ids, imports, no_prelude?, tds, rds, mgs} ->
        # Create Definition entities for each def in the mutual block.
        {new_ids, group_names} =
          Enum.reduce(defs, {[], []}, fn
            {:def, span, {:sig, _sig_span, name, name_span, _params, _ret, attrs}, _body} =
                def_ast,
            {id_acc, name_acc} ->
              entity_id =
                Roux.Runtime.create(db, Definition, %{
                  uri: uri,
                  name: name,
                  surface_ast: def_ast,
                  type: nil,
                  body: nil,
                  total?: Map.get(attrs, :total, false),
                  private?: Map.get(attrs, :private, false),
                  extern: Map.get(attrs, :extern),
                  erased_params: nil,
                  span: span,
                  name_span: name_span
                })

              {id_acc ++ [entity_id], name_acc ++ [name]}
          end)

        {ids ++ new_ids, imports, no_prelude?, tds, rds, mgs ++ [group_names]}

      _other, acc ->
        acc
    end)
  end

  defp make_elaborate_ctx(db, uri) do
    imports = Roux.Runtime.query(db, :haruspex_file_imports, uri)
    no_prelude? = file_no_prelude?(db, uri)
    {:ok, {adts, records}} = Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)

    Haruspex.Elaborate.new(
      db: db,
      uri: uri,
      imports: imports,
      source_roots: source_roots(),
      no_prelude?: no_prelude?,
      adts: adts,
      records: records
    )
  end

  defp file_mutual_groups(db, uri) do
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        Roux.Runtime.field(db, FileInfo, file_info_id, :mutual_groups) || []

      :error ->
        []
    end
  end

  defp file_no_prelude?(db, uri) do
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        Roux.Runtime.field(db, FileInfo, file_info_id, :no_prelude?) || false

      :error ->
        false
    end
  end

  defp find_entity(db, entity_ids, name) do
    Enum.find(entity_ids, fn entity_id ->
      Roux.Runtime.field(db, Definition, entity_id, :name) == name
    end) || raise Haruspex.CompilerBug, "definition #{name} not found in parsed entities"
  end

  # Update specific tracked fields on an existing Definition entity.
  # Reads all current fields and merges the updates, then calls create
  # to trigger field-level change tracking.
  defp update_entity(db, entity_id, updates) do
    current = Roux.Runtime.read(db, Definition, entity_id)
    Roux.Runtime.create(db, Definition, Map.merge(current, updates))
  end

  @doc false
  @spec module_name_from_uri(String.t(), [String.t()]) :: module()
  def module_name_from_uri(uri, source_roots \\ []) do
    stripped = strip_source_root(uri, source_roots)

    stripped
    |> Path.rootname()
    |> Path.split()
    |> Enum.map(&Macro.camelize/1)
    |> Module.concat()
  end

  defp strip_source_root(uri, []) do
    uri
  end

  defp strip_source_root(uri, [root | rest]) do
    prefix = String.trim_trailing(root, "/") <> "/"

    if String.starts_with?(uri, prefix) do
      String.trim_leading(uri, prefix)
    else
      strip_source_root(uri, rest)
    end
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
