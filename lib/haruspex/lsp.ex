defmodule Haruspex.LSP do
  @moduledoc """
  LSP query delegation for Haruspex.

  Translates between Roux query results and the formats expected by the
  LSP adapter (`Roux.Lang.LSP`). Each public function implements the logic
  for one LSP feature, delegated to from the corresponding `defquery` in
  `Haruspex`.

  Position mapping: LSP positions arrive as 1-based `{line, col}` tuples
  (converted from 0-based by the adapter). Haruspex AST spans are
  `Pentiment.Span.Byte` (byte offset + length). This module handles the
  conversion using the source text.
  """

  alias Haruspex.{Definition, FileInfo, Pretty}

  # ============================================================================
  # Hover
  # ============================================================================

  @doc """
  Produce hover content for the node at `{line, col}` in the given file.

  Returns a markdown string with the type, or nil if nothing is found.
  """
  @spec hover(Roux.Database.t(), String.t(), {pos_integer(), pos_integer()}) :: String.t() | nil
  def hover(db, uri, {line, col}) do
    source = Roux.Runtime.input(db, :source_text, uri)
    byte_offset = position_to_byte(source, line, col)

    if is_nil(byte_offset) do
      nil
    else
      hover_at_byte(db, uri, source, byte_offset)
    end
  end

  defp hover_at_byte(db, uri, _source, byte_offset) do
    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        hover_from_definitions(db, uri, entity_ids, byte_offset)

      {:error, _} ->
        nil
    end
  end

  # Check if the cursor is on a definition name or inside a definition body.
  defp hover_from_definitions(db, uri, entity_ids, byte_offset) do
    Enum.find_value(entity_ids, fn entity_id ->
      name = Roux.Runtime.field(db, Definition, entity_id, :name)
      name_span = Roux.Runtime.field(db, Definition, entity_id, :name_span)
      def_span = Roux.Runtime.field(db, Definition, entity_id, :span)

      cond do
        span_contains?(name_span, byte_offset) ->
          hover_for_definition(db, uri, name)

        span_contains?(def_span, byte_offset) ->
          hover_inside_definition(db, uri, name, entity_id, byte_offset)

        true ->
          nil
      end
    end)
  end

  # Hover on a definition name: show the type signature.
  defp hover_for_definition(db, uri, name) do
    case Roux.Runtime.query(db, :haruspex_elaborate, {uri, name}) do
      {:ok, {type_core, _body}} ->
        type_str = Pretty.pretty_term(type_core)
        "```haruspex\n#{name} : #{type_str}\n```"

      {:error, _} ->
        nil
    end
  end

  # Hover inside a definition body: walk the surface AST to find the node.
  defp hover_inside_definition(db, uri, name, entity_id, byte_offset) do
    surface_ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)

    case find_node_at(surface_ast, byte_offset) do
      {:var, _span, var_name} ->
        hover_for_var(db, uri, name, var_name)

      {:lit, _span, value} ->
        hover_for_literal(value)

      {:hole, _span} ->
        hover_for_hole(db, uri, name)

      _ ->
        # Fall back to showing the definition's type.
        hover_for_definition(db, uri, name)
    end
  end

  # Hover on a variable reference: show its type from elaboration context.
  # Since we don't have full scope resolution in the LSP layer, show the
  # definition type when the variable matches the definition name, otherwise
  # extract parameter types from the surface AST signature.
  defp hover_for_var(db, uri, def_name, var_name) do
    case Roux.Runtime.query(db, :haruspex_elaborate, {uri, def_name}) do
      {:ok, {type_core, _body}} ->
        if var_name == def_name do
          type_str = Pretty.pretty_term(type_core)
          "```haruspex\n#{var_name} : #{type_str}\n```"
        else
          # For local variables, try to extract the parameter type from the signature.
          hover_for_param(db, uri, def_name, var_name, type_core)
        end

      {:error, _} ->
        nil
    end
  end

  # Try to extract a parameter type from the definition's surface AST.
  defp hover_for_param(db, uri, def_name, var_name, type_core) do
    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        param_type = extract_param_type(db, entity_ids, def_name, var_name)

        if param_type do
          "```haruspex\n#{var_name} : #{param_type}\n```"
        else
          type_str = Pretty.pretty_term(type_core)
          "```haruspex\n#{var_name} (in #{def_name} : #{type_str})\n```"
        end

      {:error, _} ->
        nil
    end
  end

  # Extract a parameter's type name from the surface AST signature.
  defp extract_param_type(db, entity_ids, def_name, var_name) do
    Enum.find_value(entity_ids, fn entity_id ->
      if Roux.Runtime.field(db, Definition, entity_id, :name) == def_name do
        surface_ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)
        extract_param_type_from_ast(surface_ast, var_name)
      end
    end)
  end

  # Walk the signature to find a parameter with the given name.
  defp extract_param_type_from_ast(
         {:def, _span, {:sig, _sig_span, _name, _name_span, params, _ret, _attrs}, _body},
         var_name
       ) do
    Enum.find_value(params, fn
      {:param, _span, {^var_name, _mult, _implicit}, type_expr} ->
        type_expr_to_string(type_expr)

      _ ->
        nil
    end)
  end

  defp extract_param_type_from_ast(_, _), do: nil

  # Simple type expression to string for parameter types.
  defp type_expr_to_string({:var, _span, name}), do: Atom.to_string(name)
  defp type_expr_to_string(_), do: nil

  defp hover_for_literal(value) when is_integer(value), do: "```haruspex\nInt\n```"
  defp hover_for_literal(value) when is_float(value), do: "```haruspex\nFloat\n```"
  defp hover_for_literal(value) when is_binary(value), do: "```haruspex\nString\n```"
  defp hover_for_literal(value) when is_boolean(value), do: "```haruspex\nBool\n```"
  defp hover_for_literal(_), do: nil

  defp hover_for_hole(db, uri, name) do
    case Roux.Runtime.query(db, :haruspex_elaborate, {uri, name}) do
      {:ok, {type_core, _body}} ->
        type_str = Pretty.pretty_term(type_core)
        "```haruspex\n_ : #{type_str}\n```\n\nTyped hole in `#{name}`"

      {:error, _} ->
        "```haruspex\n_ : ?\n```\n\nTyped hole (type unknown)"
    end
  end

  # ============================================================================
  # Go-to-definition
  # ============================================================================

  @doc """
  Find the definition site for the name at `{line, col}`.

  Returns `%{uri: uri, line: line, column: col}` or nil.
  """
  @spec definition(Roux.Database.t(), String.t(), {pos_integer(), pos_integer()}) ::
          %{uri: String.t(), line: pos_integer(), column: pos_integer()} | nil
  def definition(db, uri, {line, col}) do
    source = Roux.Runtime.input(db, :source_text, uri)
    byte_offset = position_to_byte(source, line, col)

    if is_nil(byte_offset) do
      nil
    else
      definition_at_byte(db, uri, source, byte_offset)
    end
  end

  defp definition_at_byte(db, uri, source, byte_offset) do
    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        find_definition_target(db, uri, source, entity_ids, byte_offset)

      {:error, _} ->
        nil
    end
  end

  defp find_definition_target(db, uri, source, entity_ids, byte_offset) do
    # First check: is the cursor on a variable reference inside a definition?
    Enum.find_value(entity_ids, fn entity_id ->
      def_span = Roux.Runtime.field(db, Definition, entity_id, :span)

      if span_contains?(def_span, byte_offset) do
        surface_ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)

        case find_node_at(surface_ast, byte_offset) do
          {:var, _span, var_name} ->
            # Look for a top-level definition with this name.
            find_def_location(db, uri, source, entity_ids, var_name)

          _ ->
            nil
        end
      end
    end)
  end

  # Find the location of a top-level definition by name.
  defp find_def_location(db, uri, source, entity_ids, target_name) do
    Enum.find_value(entity_ids, fn entity_id ->
      name = Roux.Runtime.field(db, Definition, entity_id, :name)

      if name == target_name do
        name_span = Roux.Runtime.field(db, Definition, entity_id, :name_span)
        span_to_location(uri, source, name_span)
      end
    end)
  end

  # ============================================================================
  # Completions
  # ============================================================================

  @doc """
  Return completion items for the position `{line, col}` in the given file.

  Returns a list of `%{label: name, detail: type_string}` maps.
  """
  @spec completions(Roux.Database.t(), String.t(), {pos_integer(), pos_integer()}) :: [map()]
  def completions(db, uri, {_line, _col}) do
    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        def_completions(db, entity_ids) ++ type_completions(db, uri)

      {:error, _} ->
        []
    end
  end

  # Completions from top-level definitions.
  defp def_completions(db, entity_ids) do
    Enum.map(entity_ids, fn entity_id ->
      name = Roux.Runtime.field(db, Definition, entity_id, :name)
      %{label: Atom.to_string(name), detail: nil, kind: :function}
    end)
  end

  # Completions from type declarations.
  defp type_completions(db, uri) do
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        type_decls = Roux.Runtime.field(db, FileInfo, file_info_id, :type_decls) || []

        Enum.map(type_decls, fn {:type_decl, _span, name, _params, _ctors} ->
          %{label: Atom.to_string(name), detail: nil, kind: :type}
        end)

      :error ->
        []
    end
  end

  # ============================================================================
  # Document symbols
  # ============================================================================

  @doc """
  Return document symbols for the given file.

  Each symbol is a map with `:name`, `:kind`, `:range`, and `:selection_range`.
  Ranges are `{start_line, start_col, end_line, end_col}` tuples (1-based).
  """
  @spec document_symbols(Roux.Database.t(), String.t()) :: [map()]
  def document_symbols(db, uri) do
    source = Roux.Runtime.input(db, :source_text, uri)

    case Roux.Runtime.query(db, :haruspex_parse, uri) do
      {:ok, entity_ids} ->
        def_symbols(db, source, entity_ids) ++ type_decl_symbols(db, uri, source)

      {:error, _} ->
        []
    end
  end

  defp def_symbols(db, source, entity_ids) do
    Enum.map(entity_ids, fn entity_id ->
      name = Roux.Runtime.field(db, Definition, entity_id, :name)
      def_span = Roux.Runtime.field(db, Definition, entity_id, :span)
      name_span = Roux.Runtime.field(db, Definition, entity_id, :name_span)

      %{
        name: Atom.to_string(name),
        kind: :function,
        range: span_to_range(source, def_span),
        selection_range: span_to_range(source, name_span)
      }
    end)
  end

  defp type_decl_symbols(db, uri, source) do
    case Roux.Runtime.lookup(db, FileInfo, {uri}) do
      {:ok, file_info_id} ->
        type_decls = Roux.Runtime.field(db, FileInfo, file_info_id, :type_decls) || []

        Enum.map(type_decls, fn {:type_decl, span, name, _params, _ctors} ->
          %{
            name: Atom.to_string(name),
            kind: :class,
            range: span_to_range(source, span),
            selection_range: span_to_range(source, span)
          }
        end)

      :error ->
        []
    end
  end

  # ============================================================================
  # Position mapping
  # ============================================================================

  @doc """
  Convert a 1-based `{line, col}` position to a byte offset.

  Returns nil if the position is out of bounds.
  """
  @spec position_to_byte(String.t(), pos_integer(), pos_integer()) :: non_neg_integer() | nil
  def position_to_byte(source, target_line, target_col)
      when is_binary(source) and is_integer(target_line) and target_line >= 1 and
             is_integer(target_col) and target_col >= 1 do
    do_position_to_byte(source, target_line, target_col, 1, 1, 0)
  end

  def position_to_byte(_, _, _), do: nil

  defp do_position_to_byte(_source, target_line, target_col, target_line, target_col, offset) do
    offset
  end

  defp do_position_to_byte(<<>>, _target_line, _target_col, _line, _col, _offset) do
    nil
  end

  defp do_position_to_byte(
         <<?\n, rest::binary>>,
         target_line,
         target_col,
         current_line,
         _col,
         offset
       ) do
    do_position_to_byte(rest, target_line, target_col, current_line + 1, 1, offset + 1)
  end

  defp do_position_to_byte(
         <<char::utf8, rest::binary>>,
         target_line,
         target_col,
         current_line,
         current_col,
         offset
       ) do
    char_bytes = byte_size(<<char::utf8>>)

    do_position_to_byte(
      rest,
      target_line,
      target_col,
      current_line,
      current_col + 1,
      offset + char_bytes
    )
  end

  # ============================================================================
  # AST traversal
  # ============================================================================

  # Find the innermost AST node whose span contains the byte offset.
  @spec find_node_at(term(), non_neg_integer()) :: term() | nil
  defp find_node_at(node, byte_offset) do
    case node do
      {:def, _span, _sig, body} ->
        find_node_at(body, byte_offset)

      {:var, span, _name} = var ->
        if span_contains?(span, byte_offset), do: var

      {:lit, span, _value} = lit ->
        if span_contains?(span, byte_offset), do: lit

      {:hole, span} = hole ->
        if span_contains?(span, byte_offset), do: hole

      {:app, span, func, args} ->
        if span_contains?(span, byte_offset) do
          find_node_at(func, byte_offset) ||
            find_in_list(args, byte_offset) ||
            node
        end

      {:fn, span, _params, body} ->
        if span_contains?(span, byte_offset) do
          find_node_at(body, byte_offset) || node
        end

      {:let, span, _name, value, body} ->
        if span_contains?(span, byte_offset) do
          find_node_at(value, byte_offset) ||
            find_node_at(body, byte_offset) ||
            node
        end

      {:case, span, scrutinee, branches} ->
        if span_contains?(span, byte_offset) do
          find_node_at(scrutinee, byte_offset) ||
            find_in_branches(branches, byte_offset) ||
            node
        end

      {:if, span, cond_expr, then_expr, else_expr} ->
        if span_contains?(span, byte_offset) do
          find_node_at(cond_expr, byte_offset) ||
            find_node_at(then_expr, byte_offset) ||
            find_node_at(else_expr, byte_offset) ||
            node
        end

      {:binop, span, _op, left, right} ->
        if span_contains?(span, byte_offset) do
          find_node_at(left, byte_offset) ||
            find_node_at(right, byte_offset) ||
            node
        end

      {:unaryop, span, _op, expr} ->
        if span_contains?(span, byte_offset) do
          find_node_at(expr, byte_offset) || node
        end

      {:pipe, span, left, right} ->
        if span_contains?(span, byte_offset) do
          find_node_at(left, byte_offset) ||
            find_node_at(right, byte_offset) ||
            node
        end

      {:ann, span, expr, type_expr} ->
        if span_contains?(span, byte_offset) do
          find_node_at(expr, byte_offset) ||
            find_node_at(type_expr, byte_offset) ||
            node
        end

      {:dot, span, expr, _field} ->
        if span_contains?(span, byte_offset) do
          find_node_at(expr, byte_offset) || node
        end

      _ ->
        nil
    end
  end

  defp find_in_list(nodes, byte_offset) do
    Enum.find_value(nodes, fn node -> find_node_at(node, byte_offset) end)
  end

  defp find_in_branches(branches, byte_offset) do
    Enum.find_value(branches, fn
      {:branch, _span, _pat, body} -> find_node_at(body, byte_offset)
      _ -> nil
    end)
  end

  # ============================================================================
  # Span helpers
  # ============================================================================

  @spec span_contains?(Pentiment.Span.Byte.t() | nil, non_neg_integer()) :: boolean()
  defp span_contains?(nil, _offset), do: false

  defp span_contains?(%Pentiment.Span.Byte{start: start, length: length}, offset) do
    offset >= start and offset < start + length
  end

  # Convert a byte span to a 1-based `{start_line, start_col, end_line, end_col}` range.
  @spec span_to_range(String.t(), Pentiment.Span.Byte.t() | nil) ::
          {pos_integer(), pos_integer(), pos_integer(), pos_integer()}
  defp span_to_range(_source, nil), do: {1, 1, 1, 1}

  defp span_to_range(source, %Pentiment.Span.Byte{} = span) do
    pent_source = Pentiment.Source.from_string("<lsp>", source)
    pos_span = Pentiment.Span.Byte.resolve(span, pent_source)

    {
      pos_span.start_line,
      pos_span.start_column,
      pos_span.end_line || pos_span.start_line,
      pos_span.end_column || pos_span.start_column
    }
  end

  # Convert a byte span to a location map for go-to-definition.
  @spec span_to_location(String.t(), String.t(), Pentiment.Span.Byte.t() | nil) ::
          %{uri: String.t(), line: pos_integer(), column: pos_integer()} | nil
  defp span_to_location(_uri, _source, nil), do: nil

  defp span_to_location(uri, source, %Pentiment.Span.Byte{} = span) do
    pent_source = Pentiment.Source.from_string("<lsp>", source)
    pos_span = Pentiment.Span.Byte.resolve(span, pent_source)

    %{uri: uri, line: pos_span.start_line, column: pos_span.start_column}
  end
end
