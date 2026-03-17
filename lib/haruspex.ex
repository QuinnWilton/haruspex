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
  def document_symbols_query, do: :haruspex_document_symbols

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
        {entity_ids, imports, no_prelude?, type_decls, record_decls, class_decls, instance_decls,
         mutual_groups, implicit_decls} = collect_top_level(db, uri, top_level_forms)

        # Store file-level metadata.
        Roux.Runtime.create(db, FileInfo, %{
          uri: uri,
          imports: imports,
          no_prelude?: no_prelude?,
          type_decls: type_decls,
          record_decls: record_decls,
          class_decls: class_decls,
          instance_decls: instance_decls,
          mutual_groups: mutual_groups,
          implicit_decls: implicit_decls
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
  Returns `{:ok, {adts, records, classes, instances}}` where adts/records/classes
  are maps keyed by type/class name and instances is an instance database.
  """
  defquery :haruspex_elaborate_types, key: uri do
    {:ok, _entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    {type_decls, record_decls, class_decls, instance_decls} =
      case Roux.Runtime.lookup(db, FileInfo, {uri}) do
        {:ok, file_info_id} ->
          tds = Roux.Runtime.field(db, FileInfo, file_info_id, :type_decls) || []
          rds = Roux.Runtime.field(db, FileInfo, file_info_id, :record_decls) || []
          cds = Roux.Runtime.field(db, FileInfo, file_info_id, :class_decls) || []
          inds = Roux.Runtime.field(db, FileInfo, file_info_id, :instance_decls) || []
          {tds, rds, cds, inds}

        :error ->
          {[], [], [], []}
      end

    imports = Roux.Runtime.query(db, :haruspex_file_imports, uri)
    no_prelude? = file_no_prelude?(db, uri)

    file_defs = collect_file_def_names(db, uri)

    ctx =
      Haruspex.Elaborate.new(
        db: db,
        uri: uri,
        imports: imports,
        source_roots: source_roots(),
        no_prelude?: no_prelude?,
        file_defs: file_defs
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

    # Then class declarations (which generate dictionary records).
    ctx =
      Enum.reduce(class_decls, ctx, fn cd, ctx ->
        {:ok, _decl, ctx} = Haruspex.Elaborate.elaborate_class_decl(ctx, cd)
        ctx
      end)

    # Then instance declarations.
    ctx =
      Enum.reduce(instance_decls, ctx, fn ind, ctx ->
        {:ok, _decl, ctx} = Haruspex.Elaborate.elaborate_instance_decl(ctx, ind)
        ctx
      end)

    {:ok, {ctx.adts, ctx.records, ctx.classes, ctx.instances}}
  end

  @doc """
  Elaborate a single definition's surface AST to core terms.

  This is the elaboration-only query — it does NOT type-check. Used by
  `collect_total_defs` to get @total function bodies for type-level
  reduction without triggering checking cycles.
  """
  defquery :haruspex_elaborate_core, key: {uri, name} do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    mutual_groups = file_mutual_groups(db, uri)
    group = Enum.find(mutual_groups, fn names -> name in names end)

    if group do
      {:ok, results} = Roux.Runtime.query!(db, :haruspex_elaborate_mutual, {uri, group})
      {^name, type_core, body_core} = Enum.find(results, fn {n, _, _} -> n == name end)
      {:ok, {type_core, body_core, Haruspex.Unify.MetaState.new()}}
    else
      entity_id = find_entity(db, entity_ids, name)
      def_ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)

      ctx = make_elaborate_ctx(db, uri)
      def_ast = Haruspex.Elaborate.resolve_auto_implicits(ctx, def_ast)

      case Haruspex.Elaborate.elaborate_def(ctx, def_ast) do
        {:ok, {^name, type_core, body_core}, elab_ctx} ->
          update_entity(db, entity_id, %{type: type_core, body: body_core})
          {:ok, {type_core, body_core, elab_ctx.meta_state}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Elaborate and type-check a single definition.

  Unified pass: elaborates surface AST to core terms, then immediately
  type-checks with a shared MetaState so that metas from elaboration
  (holes, auto-implicits) survive into the checker. Returns
  `{:ok, {type_core, checked_body_core}}`.
  """
  defquery :haruspex_elaborate, key: {uri, name} do
    {:ok, {type_core, body_core, elab_meta_state}} =
      Roux.Runtime.query!(db, :haruspex_elaborate_core, {uri, name})

    check_result = check_elaborated_def(db, uri, name, type_core, body_core, elab_meta_state)

    with {:ok, {type_core, checked_body}} <- check_result do
      {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)
      entity_id = find_entity(db, entity_ids, name)
      update_entity(db, entity_id, %{type: type_core, body: checked_body})
      {:ok, {type_core, checked_body}}
    end
  end

  # Type-check an elaborated definition, sharing the elaboration MetaState.
  defp check_elaborated_def(db, uri, name, type_core, body_core, elab_meta_state) do
    {:ok, {adts, records, classes, instances}} =
      Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)

    total_defs = collect_total_defs(db, uri, name)
    fuel = def_fuel(db, uri, name)

    # Share the elaboration MetaState so holes and metas survive.
    ctx = %{
      Haruspex.Check.from_meta_state(elab_meta_state)
      | db: db,
        uri: uri,
        adts: adts,
        records: records,
        classes: classes,
        instances: instances,
        total_defs: total_defs,
        fuel: fuel
    }

    mutual_groups = file_mutual_groups(db, uri)
    group = Enum.find(mutual_groups, fn names -> name in names end)

    check_result =
      if group do
        # For mutual groups, read sibling types from entity storage
        # (populated by haruspex_elaborate_mutual) to avoid query cycles.
        {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

        all_sigs =
          Enum.map(group, fn sib_name ->
            sib_id = find_entity(db, entity_ids, sib_name)
            sib_type = Roux.Runtime.field(db, Definition, sib_id, :type)
            {sib_name, sib_type}
          end)

        Haruspex.Check.check_mutual_definition(ctx, name, type_core, body_core, all_sigs)
      else
        Haruspex.Check.check_definition(ctx, name, type_core, body_core)
      end

    case check_result do
      {:ok, checked_body, _ctx} ->
        if def_total?(db, uri, name) do
          case Haruspex.Totality.check_totality(name, type_core, checked_body, adts) do
            :total -> {:ok, {type_core, checked_body}}
            {:not_total, reason} -> {:error, reason}
          end
        else
          {:ok, {type_core, checked_body}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Elaborate a mutual group of definitions together.
  Returns `{:ok, [{name, type_core, body_core}, ...]}`.
  """
  defquery :haruspex_elaborate_mutual, key: {uri, group_names} do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    ctx = make_elaborate_ctx(db, uri)

    def_asts =
      Enum.map(group_names, fn name ->
        entity_id = find_entity(db, entity_ids, name)
        ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)
        Haruspex.Elaborate.resolve_auto_implicits(ctx, ast)
      end)

    case Haruspex.Mutual.elaborate_mutual(ctx, def_asts) do
      {:ok, results, _ctx} ->
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
  Compile all definitions in a file to an Elixir module AST.
  Returns `{:ok, Macro.t()}`.
  """
  defquery :haruspex_codegen, key: uri do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    definitions =
      Enum.map(entity_ids, fn entity_id ->
        name = Roux.Runtime.field(db, Definition, entity_id, :name)
        {:ok, {type_core, body_core}} = Roux.Runtime.query!(db, :haruspex_elaborate, {uri, name})
        {name, type_core, body_core}
      end)

    {:ok, {adts, records, classes, instances}} =
      Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)

    mutual_groups = file_mutual_groups(db, uri)
    module_name = module_name_from_uri(uri, source_roots())

    ast =
      Haruspex.Codegen.compile_module(module_name, :all, definitions, %{
        adts: adts,
        records: records,
        classes: classes,
        instances: instances,
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

          case Roux.Runtime.query(db, :haruspex_elaborate, {uri, name}) do
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

  defquery :haruspex_totality, key: {uri, name} do
    {:ok, {type_core, body_core}} = Roux.Runtime.query!(db, :haruspex_elaborate, {uri, name})

    {:ok, {adts, _records, _classes, _instances}} =
      Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)

    case Haruspex.Totality.check_totality(name, type_core, body_core, adts) do
      :total -> {:ok, :total}
      {:not_total, reason} -> {:error, reason}
    end
  end

  @doc """
  Produce hover content for the node at a given position.

  The key is `{uri, {line, col}}` where line and col are 1-based.
  Returns a markdown string or nil.
  """
  defquery :haruspex_hover, key: {uri, position} do
    Haruspex.LSP.hover(db, uri, position)
  end

  @doc """
  Find the definition site for the name at a given position.

  The key is `{uri, {line, col}}` where line and col are 1-based.
  Returns `%{uri: uri, line: line, column: col}` or nil.
  """
  defquery :haruspex_definition, key: {uri, position} do
    Haruspex.LSP.definition(db, uri, position)
  end

  @doc """
  Return completion items at a given position.

  The key is `{uri, {line, col}}` where line and col are 1-based.
  Returns a list of `%{label: name, detail: type_string, kind: kind}` maps.
  """
  defquery :haruspex_completions, key: {uri, position} do
    Haruspex.LSP.completions(db, uri, position)
  end

  @doc """
  Return document symbols for a file.

  The key is the file URI. Returns a list of symbol maps with `:name`,
  `:kind`, `:range`, and `:selection_range`.
  """
  defquery :haruspex_document_symbols, key: uri do
    Haruspex.LSP.document_symbols(db, uri)
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
          {[term()], [term()], boolean(), [term()], [term()], [term()], [term()], [[atom()]],
           [term()]}
  defp collect_top_level(db, uri, forms) do
    Enum.reduce(forms, {[], [], false, [], [], [], [], [], []}, fn
      {:def, span, {:sig, _sig_span, name, name_span, _params, _ret, attrs} = _sig, _body} =
          def_ast,
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        entity_id =
          Roux.Runtime.create(db, Definition, %{
            uri: uri,
            name: name,
            surface_ast: def_ast,
            type: nil,
            body: nil,
            total?: Map.get(attrs, :total, false),
            fuel: Map.get(attrs, :fuel),
            private?: Map.get(attrs, :private, false),
            extern: Map.get(attrs, :extern),
            erased_params: nil,
            span: span,
            name_span: name_span
          })

        {ids ++ [entity_id], imports, no_prelude?, tds, rds, cds, inds, mgs, imds}

      {:import, _span, module_path, open_option},
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports ++ [%{module_path: module_path, open: open_option}], no_prelude?, tds, rds,
         cds, inds, mgs, imds}

      {:no_prelude, _span}, {ids, imports, _no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, true, tds, rds, cds, inds, mgs, imds}

      {:type_decl, _, _, _, _} = td,
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, no_prelude?, tds ++ [td], rds, cds, inds, mgs, imds}

      {:record_decl, _, _, _, _} = rd,
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, no_prelude?, tds, rds ++ [rd], cds, inds, mgs, imds}

      {:class_decl, _, _, _, _, _} = cd,
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, no_prelude?, tds, rds, cds ++ [cd], inds, mgs, imds}

      {:class_decl, _, _, _, _, _, :protocol} = cd,
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, no_prelude?, tds, rds, cds ++ [cd], inds, mgs, imds}

      {:instance_decl, _, _, _, _, _} = ind,
      {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, no_prelude?, tds, rds, cds, inds ++ [ind], mgs, imds}

      {:implicit_decl, _, _} = imd, {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
        {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds ++ [imd]}

      {:mutual, _span, defs}, {ids, imports, no_prelude?, tds, rds, cds, inds, mgs, imds} ->
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
                  fuel: Map.get(attrs, :fuel),
                  private?: Map.get(attrs, :private, false),
                  extern: Map.get(attrs, :extern),
                  erased_params: nil,
                  span: span,
                  name_span: name_span
                })

              {id_acc ++ [entity_id], name_acc ++ [name]}
          end)

        {ids ++ new_ids, imports, no_prelude?, tds, rds, cds, inds, mgs ++ [group_names], imds}

      _other, acc ->
        acc
    end)
  end

  defp make_elaborate_ctx(db, uri) do
    imports = Roux.Runtime.query(db, :haruspex_file_imports, uri)
    no_prelude? = file_no_prelude?(db, uri)

    {:ok, {adts, records, classes, instances}} =
      Roux.Runtime.query!(db, :haruspex_elaborate_types, uri)

    file_defs = collect_file_def_names(db, uri)

    ctx =
      Haruspex.Elaborate.new(
        db: db,
        uri: uri,
        imports: imports,
        source_roots: source_roots(),
        no_prelude?: no_prelude?,
        adts: adts,
        records: records,
        classes: classes,
        instances: instances,
        file_defs: file_defs
      )

    # Register @implicit declarations so auto-implicit resolution works.
    implicit_decls = file_implicit_decls(db, uri)
    Enum.reduce(implicit_decls, ctx, &Haruspex.Elaborate.register_implicits(&2, &1))
  end

  defp file_implicit_decls(db, uri) do
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        Roux.Runtime.field(db, FileInfo, file_info_id, :implicit_decls) || []

      :error ->
        []
    end
  end

  defp collect_file_def_names(db, uri) do
    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        entity_ids
        |> Enum.map(fn id -> Roux.Runtime.field(db, Definition, id, :name) end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp file_mutual_groups(db, uri) do
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        Roux.Runtime.field(db, FileInfo, file_info_id, :mutual_groups) || []

      :error ->
        []
    end
  end

  # Collect all @total definitions from a file for type-level reduction.
  # Returns %{name => {body_core, true}} for each total def with an elaborated body.
  # Collect @total definitions for type-level reduction, excluding
  # the definition currently being checked (to avoid query cycles).
  defp collect_total_defs(db, uri, exclude_name) do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    Enum.reduce(entity_ids, %{}, fn entity_id, acc ->
      total? = Roux.Runtime.field(db, Definition, entity_id, :total?) == true
      def_name = Roux.Runtime.field(db, Definition, entity_id, :name)

      if total? and def_name != exclude_name do
        # Read from the elaboration-only query (not the checking query)
        # to avoid cycles between definitions that reference each other.
        case Roux.Runtime.query(db, :haruspex_elaborate_core, {uri, def_name}) do
          {:ok, {_type, body, _ms}} ->
            body = Haruspex.Core.subst(body, 0, {:def_ref, def_name})
            Map.put(acc, def_name, {body, true})

          _ ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp def_fuel(db, uri, name) do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    case find_entity(db, entity_ids, name) do
      nil -> 1000
      entity_id -> Roux.Runtime.field(db, Definition, entity_id, :fuel) || 1000
    end
  end

  defp def_total?(db, uri, name) do
    {:ok, entity_ids} = Roux.Runtime.query!(db, :haruspex_parse, uri)

    case find_entity(db, entity_ids, name) do
      nil -> false
      entity_id -> Roux.Runtime.field(db, Definition, entity_id, :total?) == true
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
