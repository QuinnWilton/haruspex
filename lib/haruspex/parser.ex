defmodule Haruspex.Parser do
  @moduledoc """
  Recursive descent parser with Pratt expression parsing for Haruspex.

  Consumes a token stream from `Haruspex.Tokenizer` and produces a
  surface AST. Uses binding power precedence for operators and handles
  do/end blocks, annotations, and type syntax.
  """

  alias Haruspex.{AST, Tokenizer}

  @type parse_error :: {:parse_error, String.t(), Pentiment.Span.Byte.t()}

  # ============================================================================
  # Public API
  # ============================================================================

  @spec parse(String.t()) :: {:ok, AST.program()} | {:error, [parse_error()]}
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- tokenize(source) do
      state = new(tokens)

      try do
        case parse_program(state) do
          {:ok, program, _state} -> {:ok, program}
          {:error, errors} -> {:error, errors}
        end
      after
        Process.delete(:haruspex_parse_errors)
      end
    end
  end

  @spec parse_expr(String.t()) :: {:ok, AST.expr()} | {:error, [parse_error()]}
  def parse_expr(source) when is_binary(source) do
    with {:ok, tokens} <- tokenize(source) do
      state = new(tokens)

      try do
        case parse_expression(state, 0) do
          {:ok, expr, _state} ->
            case collected_errors() do
              [] -> {:ok, expr}
              errors -> {:error, errors}
            end

          {:error, msg, span} ->
            add_error(msg, span)
            {:error, collected_errors()}
        end
      after
        Process.delete(:haruspex_parse_errors)
      end
    end
  end

  defp tokenize(source) do
    case Tokenizer.tokenize(source) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, msg, pos} ->
        {:error, [{:parse_error, msg, %Pentiment.Span.Byte{start: pos, length: 1}}]}
    end
  end

  # ============================================================================
  # State management
  # ============================================================================

  defstruct [:tokens, :pos]

  defp new(token_list) do
    Process.put(:haruspex_parse_errors, [])
    %__MODULE__{tokens: List.to_tuple(token_list), pos: 0}
  end

  defp add_error(msg, span) do
    errors = Process.get(:haruspex_parse_errors, [])
    Process.put(:haruspex_parse_errors, [{:parse_error, msg, span} | errors])
  end

  defp collected_errors do
    Process.get(:haruspex_parse_errors, []) |> Enum.reverse()
  end

  defp peek(%{tokens: tokens, pos: pos}) do
    elem(tokens, pos)
  end

  defp peek2(%{tokens: tokens, pos: pos}) do
    elem(tokens, pos + 1)
  end

  defp advance(state) do
    %{state | pos: state.pos + 1}
  end

  defp span_of(state) do
    {_, span, _} = peek(state)
    span
  end

  defp expect(state, tag) do
    {t, span, _} = peek(state)

    if t == tag do
      {:ok, advance(state)}
    else
      {:error, "expected #{tag}, got #{t}", span}
    end
  end

  defp expect_ident(state) do
    {t, span, val} = peek(state)

    if t == :ident do
      {:ok, val, span, advance(state)}
    else
      {:error, "expected identifier, got #{t}", span}
    end
  end

  # Like expect_ident but also accepts `_` as a name.
  defp expect_ident_or_wildcard(state) do
    case peek(state) do
      {:ident, span, val} -> {:ok, val, span, advance(state)}
      {:underscore, span, _} -> {:ok, :_, span, advance(state)}
      {t, span, _} -> {:error, "expected identifier, got #{t}", span}
    end
  end

  defp skip_newlines(state) do
    case peek(state) do
      {:newline, _, _} -> skip_newlines(advance(state))
      _ -> state
    end
  end

  defp merge(s1, s2), do: Pentiment.Span.Byte.merge(s1, s2)

  # Synchronization: skip tokens until we reach a top-level keyword or EOF.
  # Always advances at least one token to avoid infinite loops when the
  # current token triggered the error.
  @toplevel_sync MapSet.new([
                   :def,
                   :type,
                   :import,
                   :mutual,
                   :class,
                   :instance,
                   :record,
                   :at,
                   :eof
                 ])

  defp sync_toplevel(state) do
    state = skip_to_next_line_or_eof(state)
    sync_toplevel_loop(state)
  end

  defp sync_toplevel_loop(state) do
    {tag, _, _} = peek(state)

    if MapSet.member?(@toplevel_sync, tag) do
      state
    else
      sync_toplevel_loop(advance(state))
    end
  end

  # Synchronization for case branches: skip to next newline boundary or `end`.
  defp sync_branch(state) do
    case peek(state) do
      {:end, _, _} -> state
      {:eof, _, _} -> state
      {:newline, _, _} -> skip_newlines(state)
      _ -> sync_branch(advance(state))
    end
  end

  # Skip tokens until we hit a newline or EOF.
  defp skip_to_next_line_or_eof(state) do
    case peek(state) do
      {:eof, _, _} -> state
      {:newline, _, _} -> skip_newlines(state)
      _ -> skip_to_next_line_or_eof(advance(state))
    end
  end

  # ============================================================================
  # Program parsing
  # ============================================================================

  defp parse_program(state) do
    state = skip_newlines(state)
    parse_toplevels(state, [])
  end

  defp parse_toplevels(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:eof, _, _} ->
        case collected_errors() do
          [] -> {:ok, Enum.reverse(acc), state}
          errors -> {:error, errors}
        end

      _ ->
        case parse_toplevel(state) do
          {:ok, decl, state} ->
            state = skip_newlines(state)
            parse_toplevels(state, [decl | acc])

          {:error, msg, span} ->
            add_error(msg, span)
            state = sync_toplevel(state)
            parse_toplevels(state, acc)
        end
    end
  end

  defp parse_toplevel(state) do
    case peek(state) do
      {:at, _, _} -> parse_at_toplevel(state)
      {:def, _, _} -> parse_def(state, %{total: false, private: false, extern: nil})
      {:type, _, _} -> parse_type_decl(state)
      {:import, _, _} -> parse_import(state)
      {:mutual, _, _} -> parse_mutual(state)
      {:class, _, _} -> parse_class_decl(state)
      {:instance, _, _} -> parse_instance_decl(state)
      {:record, _, _} -> parse_record_decl(state)
      {tag, span, _} -> {:error, "expected top-level declaration, got #{tag}", span}
    end
  end

  # ============================================================================
  # Annotations (@total, @private, @extern)
  # ============================================================================

  defp parse_at_toplevel(state) do
    # Peek past @ to see if this is @implicit, @no_prelude, @protocol, or an annotation on def.
    case peek2(state) do
      {:ident, _, :implicit} -> parse_implicit_decl(state)
      {:ident, _, :no_prelude} -> parse_no_prelude(state)
      {:ident, _, :protocol} -> parse_protocol_class(state)
      _ -> parse_annotated_def(state)
    end
  end

  defp parse_no_prelude(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)
    {_, end_span, _} = peek(state)
    state = advance(state)
    {:ok, {:no_prelude, merge(start_span, end_span)}, state}
  end

  defp parse_protocol_class(state) do
    # @protocol before a class declaration marks it for Elixir protocol generation.
    state = advance(state)
    state = advance(state)
    state = skip_newlines(state)

    case peek(state) do
      {:class, _, _} ->
        case parse_class_decl(state) do
          {:ok, {:class_decl, span, name, params, constraints, methods}, state} ->
            {:ok, {:class_decl, span, name, params, constraints, methods, :protocol}, state}

          other ->
            other
        end

      {tag, span, _} ->
        {:error, "expected class declaration after @protocol, got #{tag}", span}
    end
  end

  defp parse_annotated_def(state) do
    with {:ok, attrs, state} <- parse_annotations(state) do
      state = skip_newlines(state)
      parse_def(state, attrs)
    end
  end

  defp parse_annotations(
         state,
         attrs \\ %{total: false, private: false, extern: nil, fuel: nil}
       ) do
    case peek(state) do
      {:at, _, _} ->
        state = advance(state)
        {tag, span, val} = peek(state)

        cond do
          tag == :ident and val == :total ->
            parse_annotations(skip_newlines(advance(state)), %{attrs | total: true})

          tag == :ident and val == :fuel ->
            state = advance(state)

            case peek(state) do
              {:int, _, n} ->
                parse_annotations(skip_newlines(advance(state)), %{attrs | fuel: n})

              {_, fspan, _} ->
                {:error, "expected integer after @fuel", fspan}
            end

          tag == :ident and val == :private ->
            parse_annotations(skip_newlines(advance(state)), %{attrs | private: true})

          tag == :ident and val == :extern ->
            state = advance(state)

            with {:ok, extern, state} <- parse_extern_ref(state) do
              parse_annotations(skip_newlines(state), %{attrs | extern: extern})
            end

          true ->
            {:error, "expected total, private, fuel, or extern after @", span}
        end

      _ ->
        {:ok, attrs, state}
    end
  end

  defp parse_extern_ref(state) do
    # Parse Module.function/arity
    with {:ok, mod_parts, state} <- parse_module_path(state),
         {:ok, state} <- expect(state, :dot),
         {:ok, func, _span, state} <- expect_ident(state),
         {:ok, state} <- expect(state, :slash) do
      {tag, span, val} = peek(state)

      if tag == :int do
        mod =
          case mod_parts do
            {:erlang_mod, atom} -> atom
            parts when is_list(parts) -> Module.concat(parts)
          end

        {:ok, {mod, func, val}, advance(state)}
      else
        {:error, "expected arity (integer) after /", span}
      end
    end
  end

  defp parse_module_path(state) do
    {tag, _span, val} = peek(state)

    cond do
      tag == :upper_ident ->
        parse_module_path_rest(advance(state), [val])

      tag == :atom_lit ->
        # Erlang module: :math, :lists, etc. — use the atom directly, not Module.concat.
        {:ok, {:erlang_mod, val}, advance(state)}

      true ->
        {:error, "expected module name", span_of(state)}
    end
  end

  defp parse_module_path_rest(state, acc) do
    case peek(state) do
      {:dot, _, _} ->
        state2 = advance(state)

        case peek(state2) do
          {:upper_ident, _, val} ->
            parse_module_path_rest(advance(state2), [val | acc])

          # Not an upper_ident after dot — stop, this dot is module.function
          _ ->
            {:ok, Enum.reverse(acc), state}
        end

      _ ->
        {:ok, Enum.reverse(acc), state}
    end
  end

  # ============================================================================
  # Definitions
  # ============================================================================

  defp parse_def(state, %{extern: extern} = attrs) when extern != nil do
    # Extern defs may have an optional body. If no `do` follows, the def is bodyless.
    {_, def_span, _} = peek(state)
    state = advance(state)

    with {:ok, name, name_span, state} <- expect_ident(state),
         {:ok, params, state} <- parse_optional_params(state),
         {:ok, ret_type, state} <- parse_optional_return_type(state) do
      case peek(state) do
        {:do, _, _} ->
          with {:ok, state} <- expect(state, :do) do
            sig_span = merge(def_span, span_of(state))
            sig = {:sig, sig_span, name, name_span, params, ret_type, attrs}

            with {:ok, body, state} <- parse_block(state) do
              {_, end_span, _} = peek(state)

              with {:ok, state} <- expect(state, :end) do
                {:ok, {:def, merge(def_span, end_span), sig, body}, state}
              end
            end
          end

        _ ->
          sig_span = merge(def_span, span_of(state))
          sig = {:sig, sig_span, name, name_span, params, ret_type, attrs}
          {:ok, {:def, sig_span, sig, nil}, state}
      end
    end
  end

  defp parse_def(state, attrs) do
    {_, def_span, _} = peek(state)
    state = advance(state)

    with {:ok, name, name_span, state} <- expect_ident(state),
         {:ok, params, state} <- parse_optional_params(state),
         {:ok, ret_type, state} <- parse_optional_return_type(state),
         {:ok, state} <- expect(state, :do) do
      sig_span = merge(def_span, span_of(state))
      sig = {:sig, sig_span, name, name_span, params, ret_type, attrs}

      with {:ok, body, state} <- parse_block(state) do
        {_, end_span, _} = peek(state)

        with {:ok, state} <- expect(state, :end) do
          {:ok, {:def, merge(def_span, end_span), sig, body}, state}
        end
      end
    end
  end

  defp parse_optional_params(state) do
    case peek(state) do
      {:lparen, _, _} -> parse_params(state)
      _ -> {:ok, [], state}
    end
  end

  defp parse_optional_return_type(state) do
    case peek(state) do
      {:colon, _, _} ->
        state = advance(state)

        with {:ok, type, state} <- parse_expression(state, 0) do
          {:ok, type, state}
        end

      _ ->
        {:ok, nil, state}
    end
  end

  # ============================================================================
  # Parameters
  # ============================================================================

  defp parse_params(state) do
    with {:ok, state} <- expect(state, :lparen) do
      case peek(state) do
        {:rparen, _, _} -> {:ok, [], advance(state)}
        _ -> parse_param_list(state, [])
      end
    end
  end

  defp parse_param_list(state, acc) do
    with {:ok, param, state} <- parse_param(state) do
      case peek(state) do
        {:comma, _, _} ->
          state = advance(state)
          # Allow trailing comma.
          case peek(state) do
            {:rparen, _, _} -> {:ok, Enum.reverse([param | acc]), advance(state)}
            _ -> parse_param_list(state, [param | acc])
          end

        {:rparen, _, _} ->
          {:ok, Enum.reverse([param | acc]), advance(state)}

        {tag, span, _} ->
          {:error, "expected , or ) in parameter list, got #{tag}", span}
      end
    end
  end

  defp parse_param(state) do
    case peek(state) do
      # Implicit: {name : type} or {0 name : type}
      {:lbrace, _, _} ->
        start_span = span_of(state)
        state = advance(state)
        {mult, state} = parse_optional_mult(state)

        with {:ok, name, _name_span, state} <- expect_ident_or_wildcard(state),
             {:ok, state} <- expect(state, :colon),
             {:ok, type, state} <- parse_expression(state, 0),
             {:ok, state} <- expect(state, :rbrace) do
          span = merge(start_span, span_of(state))
          {:ok, {:param, span, {name, mult, true}, type}, state}
        end

      # Instance: [name : type]
      {:lbracket, _, _} ->
        start_span = span_of(state)
        state = advance(state)

        with {:ok, name, _name_span, state} <- expect_ident_or_wildcard(state),
             {:ok, state} <- expect(state, :colon),
             {:ok, type, state} <- parse_expression(state, 0),
             {:ok, state} <- expect(state, :rbracket) do
          # Instance params are treated as implicit for now.
          span = merge(start_span, span_of(state))
          {:ok, {:param, span, {name, :omega, true}, type}, state}
        end

      # Explicit: name : type or 0 name : type
      _ ->
        start_span = span_of(state)
        {mult, state} = parse_optional_mult(state)

        with {:ok, name, _name_span, state} <- expect_ident_or_wildcard(state),
             {:ok, state} <- expect(state, :colon),
             {:ok, type, state} <- parse_expression(state, 0) do
          span = merge(start_span, AST.span(type))
          {:ok, {:param, span, {name, mult, false}, type}, state}
        end
    end
  end

  defp parse_optional_mult(state) do
    case peek(state) do
      {:int, _, 0} -> {:zero, advance(state)}
      _ -> {:omega, state}
    end
  end

  # ============================================================================
  # Type declarations
  # ============================================================================

  defp parse_type_decl(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    {tag, span, val} = peek(state)

    unless tag == :upper_ident do
      {:error, "expected type name, got #{tag}", span}
    else
      name = val
      state = advance(state)

      with {:ok, type_params, state} <- parse_optional_type_params(state) do
        state = skip_newlines(state)

        with {:ok, state} <- expect(state, :eq) do
          state = skip_newlines(state)

          # Skip optional leading | (allows `type Nat = | zero | succ(Nat)`).
          state =
            case peek(state) do
              {:bar, _, _} ->
                state = advance(state)
                skip_newlines(state)

              _ ->
                state
            end

          with {:ok, constructors, state} <- parse_constructors(state) do
            end_span =
              case constructors do
                [_ | _] -> AST.span(List.last(constructors))
                [] -> span
              end

            {:ok, {:type_decl, merge(start_span, end_span), name, type_params, constructors},
             state}
          end
        end
      end
    end
  end

  defp parse_optional_type_params(state) do
    case peek(state) do
      {:lparen, _, _} ->
        state = advance(state)
        parse_type_param_list(state, [])

      _ ->
        {:ok, [], state}
    end
  end

  defp parse_type_param_list(state, acc) do
    {tag, _span, val} = peek(state)

    cond do
      tag == :rparen ->
        {:ok, Enum.reverse(acc), advance(state)}

      tag == :ident ->
        state = advance(state)

        # Kind annotation is required.
        case peek(state) do
          {:colon, _, _} ->
            :ok

          {t, s, _} ->
            throw({:error, "expected : after type parameter '#{val}', got #{t}", s})
        end

        state = advance(state)

        {kind, state} =
          case parse_expression(state, 0) do
            {:ok, kind_expr, state} -> {kind_expr, state}
            error -> throw(error)
          end

        tp = {val, kind}

        case peek(state) do
          {:comma, _, _} -> parse_type_param_list(advance(state), [tp | acc])
          {:rparen, _, _} -> {:ok, Enum.reverse([tp | acc]), advance(state)}
          {t, s, _} -> {:error, "expected , or ) in type params, got #{t}", s}
        end

      true ->
        {:error, "expected type parameter name, got #{tag}", span_of(state)}
    end
  catch
    {:error, _, _} = err -> err
  end

  defp parse_constructors(state, acc \\ []) do
    with {:ok, ctor, state} <- parse_single_constructor(state) do
      state = skip_newlines(state)

      case peek(state) do
        {:bar, _, _} ->
          state = skip_newlines(advance(state))
          parse_constructors(state, [ctor | acc])

        _ ->
          {:ok, Enum.reverse([ctor | acc]), state}
      end
    end
  end

  defp parse_single_constructor(state) do
    case peek(state) do
      {tag, span, val} when tag == :ident or tag == true or tag == false ->
        name = if tag in [true, false], do: tag, else: val
        state = advance(state)

        {args, state} =
          case peek(state) do
            {:lparen, _, _} ->
              state = advance(state)

              case parse_type_arg_list(state) do
                {:ok, args, state} -> {args, state}
                error -> throw(error)
              end

            _ ->
              {[], state}
          end

        {ret, state} = parse_optional_constructor_return(state)
        end_span = if ret, do: AST.span(ret), else: if(args != [], do: span_of(state), else: span)
        {:ok, {:constructor, merge(span, end_span), name, args, ret}, state}

      {tag, span, _} ->
        {:error, "expected constructor, got #{tag}", span}
    end
  catch
    {:error, _, _} = err -> err
  end

  defp parse_optional_constructor_return(state) do
    case peek(state) do
      {:colon, _, _} ->
        state = advance(state)

        case parse_expression(state, 0) do
          {:ok, type, state} -> {type, state}
          error -> throw(error)
        end

      _ ->
        {nil, state}
    end
  end

  defp parse_type_arg_list(state, acc \\ []) do
    case peek(state) do
      {:rparen, _, _} ->
        {:ok, Enum.reverse(acc), advance(state)}

      _ ->
        with {:ok, type, state} <- parse_expression(state, 0) do
          case peek(state) do
            {:comma, _, _} -> parse_type_arg_list(advance(state), [type | acc])
            {:rparen, _, _} -> {:ok, Enum.reverse([type | acc]), advance(state)}
            {t, s, _} -> {:error, "expected , or ) in constructor args, got #{t}", s}
          end
        end
    end
  end

  # ============================================================================
  # Import, variable, mutual
  # ============================================================================

  defp parse_import(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, path, state} <- parse_module_path(state) do
      {open, state} = parse_import_options(state)
      end_span = span_of(state)
      {:ok, {:import, merge(start_span, end_span), path, open}, state}
    end
  end

  defp parse_import_options(state) do
    case peek(state) do
      {:comma, _, _} ->
        state = advance(state)
        # Expect open: true or open: [:atom, ...]
        case peek(state) do
          {:ident, _, :open} ->
            state = advance(state)

            with {:ok, state} <- expect(state, :colon) do
              case peek(state) do
                {true, _, _} ->
                  {true, advance(state)}

                {:lbracket, _, _} ->
                  state = advance(state)
                  {names, state} = parse_name_list(state, [])
                  {names, state}

                {_tag, _span, _} ->
                  # Can't parse open option, return nil.
                  {nil, state}
              end
            else
              _ -> {nil, state}
            end

          _ ->
            {nil, state}
        end

      _ ->
        {nil, state}
    end
  end

  defp parse_name_list(state, acc) do
    case peek(state) do
      {:rbracket, _, _} ->
        {Enum.reverse(acc), advance(state)}

      {:ident, _, val} ->
        state = advance(state)

        case peek(state) do
          {:comma, _, _} -> parse_name_list(advance(state), [val | acc])
          {:rbracket, _, _} -> {Enum.reverse([val | acc]), advance(state)}
          _ -> {Enum.reverse([val | acc]), state}
        end

      _ ->
        {Enum.reverse(acc), state}
    end
  end

  defp parse_implicit_decl(state) do
    {_, start_span, _} = peek(state)
    # Advance past @ and implicit.
    state = advance(advance(state))
    parse_implicit_params(state, start_span, [])
  end

  defp parse_implicit_params(state, start_span, acc) do
    case peek(state) do
      {:lbrace, _, _} ->
        with {:ok, param, state} <- parse_param(state) do
          parse_implicit_params(state, start_span, [param | acc])
        end

      _ ->
        end_span =
          case acc do
            [last | _] -> AST.span(last)
            [] -> start_span
          end

        {:ok, {:implicit_decl, merge(start_span, end_span), Enum.reverse(acc)}, state}
    end
  end

  defp parse_mutual(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, state} <- expect(state, :do) do
      state = skip_newlines(state)

      with {:ok, decls, state} <- parse_mutual_body(state, []) do
        {_, end_span, _} = peek(state)

        with {:ok, state} <- expect(state, :end) do
          {:ok, {:mutual, merge(start_span, end_span), decls}, state}
        end
      end
    end
  end

  defp parse_mutual_body(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:end, _, _} ->
        {:ok, Enum.reverse(acc), state}

      _ ->
        case parse_toplevel(state) do
          {:ok, decl, state} ->
            parse_mutual_body(state, [decl | acc])

          {:error, msg, span} ->
            add_error(msg, span)
            state = sync_toplevel(state)
            parse_mutual_body(state, acc)
        end
    end
  end

  # ============================================================================
  # Class, instance, record declarations (grammar support for later tiers)
  # ============================================================================

  defp parse_class_decl(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    {tag, span, val} = peek(state)

    unless tag == :upper_ident do
      {:error, "expected class name, got #{tag}", span}
    else
      state = advance(state)

      with {:ok, params, state} <- parse_optional_params(state),
           {:ok, constraints, state} <- parse_optional_constraints(state),
           {:ok, state} <- expect(state, :do) do
        state = skip_newlines(state)

        with {:ok, methods, state} <- parse_method_sigs(state, []) do
          {_, end_span, _} = peek(state)

          with {:ok, state} <- expect(state, :end) do
            {:ok, {:class_decl, merge(start_span, end_span), val, params, constraints, methods},
             state}
          end
        end
      end
    end
  end

  defp parse_instance_decl(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    {tag, span, val} = peek(state)

    unless tag == :upper_ident do
      {:error, "expected class name, got #{tag}", span}
    else
      state = advance(state)

      with {:ok, type_args, state} <- parse_instance_type_args(state),
           {:ok, constraints, state} <- parse_optional_constraints(state),
           {:ok, state} <- expect(state, :do) do
        state = skip_newlines(state)

        with {:ok, impls, state} <- parse_method_impls(state, []) do
          {_, end_span, _} = peek(state)

          with {:ok, state} <- expect(state, :end) do
            {:ok,
             {:instance_decl, merge(start_span, end_span), val, type_args, constraints, impls},
             state}
          end
        end
      end
    end
  end

  defp parse_instance_type_args(state) do
    case peek(state) do
      {:lparen, _, _} ->
        state = advance(state)
        parse_type_arg_list(state)

      _ ->
        {:ok, [], state}
    end
  end

  defp parse_optional_constraints(state) do
    case peek(state) do
      {:lbracket, _, _} ->
        state = advance(state)
        parse_constraint_list(state, [])

      _ ->
        {:ok, [], state}
    end
  end

  defp parse_constraint_list(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:rbracket, _, _} ->
        {:ok, Enum.reverse(acc), advance(state)}

      {:upper_ident, span, name} ->
        state = advance(state)

        {args, state} =
          case peek(state) do
            {:lparen, _, _} ->
              state = advance(state)

              case parse_type_arg_list(state) do
                {:ok, args, state} -> {args, state}
                {:error, _, _} = err -> throw(err)
              end

            _ ->
              {[], state}
          end

        constraint = {:constraint, span, name, args}
        state = skip_newlines(state)

        case peek(state) do
          {:comma, _, _} ->
            parse_constraint_list(advance(state), [constraint | acc])

          _ ->
            parse_constraint_list(state, [constraint | acc])
        end

      {tag, span, _} ->
        {:error, "expected constraint or ], got #{tag}", span}
    end
  end

  defp parse_method_sigs(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:end, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:ident, span, name} ->
        state = advance(state)

        case expect(state, :colon) do
          {:ok, state} ->
            case parse_expression(state, 0) do
              {:ok, type, state} ->
                method = {:method_sig, merge(span, AST.span(type)), name, type}
                parse_method_sigs(state, [method | acc])

              {:error, msg, span} ->
                add_error(msg, span)
                state = sync_branch(state)
                parse_method_sigs(state, acc)
            end

          {:error, msg, span} ->
            add_error(msg, span)
            state = sync_branch(state)
            parse_method_sigs(state, acc)
        end

      {tag, span, _} ->
        add_error("expected method signature, got #{tag}", span)
        state = sync_branch(state)
        parse_method_sigs(state, acc)
    end
  end

  defp parse_method_impls(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:end, _, _} ->
        {:ok, Enum.reverse(acc), state}

      {:def, _, _} ->
        case parse_def(state, %{total: false, private: false, extern: nil}) do
          {:ok, def_node, state} ->
            {:def, _, {:sig, sig_span, name, _, params, _ret_type, _}, body} = def_node

            full_body =
              if params == [], do: body, else: {:fn, sig_span, params, body}

            impl = {:method_impl, AST.span(def_node), name, full_body}
            parse_method_impls(state, [impl | acc])

          {:error, msg, span} ->
            add_error(msg, span)
            state = sync_toplevel(state)
            parse_method_impls(state, acc)
        end

      {tag, span, _} ->
        add_error("expected method implementation, got #{tag}", span)
        state = sync_branch(state)
        parse_method_impls(state, acc)
    end
  end

  defp parse_record_decl(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    {tag, span, val} = peek(state)

    unless tag == :upper_ident do
      {:error, "expected record name, got #{tag}", span}
    else
      state = advance(state)

      with {:ok, params, state} <- parse_optional_params(state) do
        state = skip_newlines(state)

        with {:ok, state} <- expect(state, :colon) do
          state = skip_newlines(state)

          with {:ok, fields, state} <- parse_record_fields(state) do
            end_span =
              case fields do
                [] -> span
                _ -> AST.span(List.last(fields))
              end

            {:ok, {:record_decl, merge(start_span, end_span), val, params, fields}, state}
          end
        end
      end
    end
  end

  defp parse_record_fields(state, acc \\ []) do
    with {:ok, field, state} <- parse_single_field(state) do
      state = skip_newlines(state)

      case peek(state) do
        {:comma, _, _} ->
          state = skip_newlines(advance(state))
          parse_record_fields(state, [field | acc])

        _ ->
          {:ok, Enum.reverse([field | acc]), state}
      end
    end
  end

  defp parse_single_field(state) do
    case peek(state) do
      {:ident, span, name} ->
        state = advance(state)

        with {:ok, state} <- expect(state, :colon),
             {:ok, type, state} <- parse_expression(state, 0) do
          {:ok, {:field, merge(span, AST.span(type)), name, type}, state}
        end

      {tag, span, _} ->
        {:error, "expected field name, got #{tag}", span}
    end
  end

  # ============================================================================
  # Record expressions: %Point{x: 1.0} and %{p | x: 3.0}
  # ============================================================================

  # %Point{x: 1.0, y: 2.0}  — record construction
  # %Point{p | x: 3.0}      — typed record update
  # %{p | x: 3.0}           — untyped record update
  defp parse_record_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    case peek(state) do
      {:upper_ident, _, record_name} ->
        state = advance(state)

        with {:ok, state} <- expect(state, :lbrace) do
          state = skip_newlines(state)
          # Disambiguate: %Point{x: 1.0} (construction) vs %Point{p | x: 3.0} (typed update).
          # If next is `ident :`, it's construction. If `expr |`, it's update.
          parse_record_construct_or_update(state, start_span, record_name)
        end

      {:lbrace, _, _} ->
        # %{p | x: 3.0} — untyped record update.
        state = advance(state)
        state = skip_newlines(state)
        parse_record_update_body(state, start_span, nil)

      {tag, span, _} ->
        {:error, "expected record name or { after %, got #{tag}", span}
    end
  end

  # After seeing %Point{, disambiguate construction from typed update.
  defp parse_record_construct_or_update(state, start_span, record_name) do
    # Try to detect update: the first token is an expression followed by |.
    # Construction always starts with `ident :`. If it doesn't match that,
    # try parsing as update.
    case peek(state) do
      {:ident, _, _} ->
        # Could be `x: expr` (construction) or `x | ...` (update where target is a var).
        # Peek at second token to decide.
        case peek2(state) do
          {:colon, _, _} ->
            # Construction: %Point{x: 1.0, y: 2.0}
            with {:ok, fields, state} <- parse_field_assignments(state) do
              end_span = span_of(state)

              with {:ok, state} <- expect(state, :rbrace) do
                {:ok, {:record_construct, merge(start_span, end_span), record_name, fields},
                 state}
              end
            end

          _ ->
            # Update: %Point{p | x: 3.0}
            parse_record_update_body(state, start_span, record_name)
        end

      {:rbrace, _, _} ->
        # Empty construction: %Point{}
        end_span = span_of(state)
        {:ok, {:record_construct, merge(start_span, end_span), record_name, []}, advance(state)}

      _ ->
        # Assume update: %Point{some_expr | x: 3.0}
        parse_record_update_body(state, start_span, record_name)
    end
  end

  # Parse the body of a record update: expr | field: val, ...}
  # record_name is nil for untyped updates (%{p | ...}).
  defp parse_record_update_body(state, start_span, record_name) do
    with {:ok, target, state} <- parse_expression(state, 0) do
      state = skip_newlines(state)

      with {:ok, state} <- expect(state, :bar) do
        state = skip_newlines(state)

        with {:ok, fields, state} <- parse_field_assignments(state) do
          end_span = span_of(state)

          with {:ok, state} <- expect(state, :rbrace) do
            {:ok, {:record_update, merge(start_span, end_span), record_name, target, fields},
             state}
          end
        end
      end
    end
  end

  # Parse field: value pairs separated by commas.
  defp parse_field_assignments(state, acc \\ []) do
    case peek(state) do
      {:rbrace, _, _} ->
        {:ok, Enum.reverse(acc), state}

      _ ->
        with {:ok, name, _span, state} <- expect_ident(state),
             {:ok, state} <- expect(state, :colon) do
          state = skip_newlines(state)

          with {:ok, expr, state} <- parse_expression(state, 0) do
            state = skip_newlines(state)

            case peek(state) do
              {:comma, _, _} ->
                state = skip_newlines(advance(state))
                parse_field_assignments(state, [{name, expr} | acc])

              _ ->
                {:ok, Enum.reverse([{name, expr} | acc]), state}
            end
          end
        end
    end
  end

  # Parse %Point{x: x, y: y} pattern.
  defp parse_record_pattern(state, start_span) do
    state = advance(state)

    case peek(state) do
      {:upper_ident, _, record_name} ->
        state = advance(state)

        with {:ok, state} <- expect(state, :lbrace) do
          state = skip_newlines(state)

          with {:ok, field_pats, state} <- parse_field_patterns(state) do
            end_span = span_of(state)

            with {:ok, state} <- expect(state, :rbrace) do
              {:ok, {:pat_record, merge(start_span, end_span), record_name, field_pats}, state}
            end
          end
        end

      {tag, span, _} ->
        {:error, "expected record name after % in pattern, got #{tag}", span}
    end
  end

  # Parse field: pattern pairs separated by commas.
  defp parse_field_patterns(state, acc \\ []) do
    case peek(state) do
      {:rbrace, _, _} ->
        {:ok, Enum.reverse(acc), state}

      _ ->
        with {:ok, name, _span, state} <- expect_ident(state),
             {:ok, state} <- expect(state, :colon) do
          state = skip_newlines(state)

          with {:ok, pat, state} <- parse_pattern(state) do
            state = skip_newlines(state)

            case peek(state) do
              {:comma, _, _} ->
                state = skip_newlines(advance(state))
                parse_field_patterns(state, [{name, pat} | acc])

              _ ->
                {:ok, Enum.reverse([{name, pat} | acc]), state}
            end
          end
        end
    end
  end

  # ============================================================================
  # Block body (sequences of expressions inside do/end)
  # ============================================================================

  defp parse_block(state) do
    state = skip_newlines(state)
    parse_block_expr(state)
  end

  defp parse_block_expr(state) do
    with {:ok, expr, state} <- parse_expression(state, 0) do
      state = skip_newlines(state)

      case peek(state) do
        {tag, _, _} when tag in [:end, :else] ->
          {:ok, expr, state}

        # More expressions follow — desugar as let _ = expr in rest.
        _ ->
          case expr do
            {:let, _, _, _, _} ->
              # Let already chains — its body is the rest.
              {:ok, expr, state}

            _ ->
              with {:ok, rest, state} <- parse_block_expr(state) do
                {:ok, {:let, merge(AST.span(expr), AST.span(rest)), :_, expr, rest}, state}
              end
          end
      end
    end
  end

  # ============================================================================
  # Pratt expression parser
  # ============================================================================

  # Binding powers (higher = tighter):
  # Arrow ->         : left=2,  right=1  (right-assoc)
  # Pipe |>          : left=3,  right=4  (left-assoc)
  # Or ||            : left=5,  right=6  (left-assoc)
  # And &&           : left=7,  right=8  (left-assoc)
  # Eq ==, !=        : left=9,  right=10 (left-assoc)
  # Cmp <, >, <=, >= : left=11, right=12 (left-assoc)
  # Add +, -         : left=13, right=14 (left-assoc)
  # Mul *, /         : left=15, right=16 (left-assoc)
  # Prefix -, not    : right=17
  # App f(x)         : left=19
  # Dot .            : left=21, right=22

  defp parse_expression(state, min_bp) do
    with {:ok, lhs, state} <- parse_prefix(state) do
      parse_infix_loop(state, lhs, min_bp)
    end
  end

  defp parse_infix_loop(state, lhs, min_bp) do
    case peek(state) do
      # Dot access: expr.field
      {:dot, _, _} when 21 >= min_bp ->
        state = advance(state)
        {tag, span, val} = peek(state)

        if tag == :ident do
          dot_span = merge(AST.span(lhs), span)
          parse_infix_loop(advance(state), {:dot, dot_span, lhs, val}, min_bp)
        else
          {:error, "expected field name after .", span}
        end

      # Function application: expr(args)
      {:lparen, _, _} when 19 >= min_bp ->
        state = advance(state)

        with {:ok, args, state} <- parse_arg_list(state) do
          app_span = merge(AST.span(lhs), span_of(state))
          parse_infix_loop(state, {:app, app_span, lhs, args}, min_bp)
        end

      # Arrow (right-assoc): A -> B, or (x : A) -> B becomes Pi
      {:arrow, _, _} when 2 >= min_bp ->
        state = advance(state)

        with {:ok, rhs, state} <- parse_expression(state, 1) do
          node = make_arrow(lhs, rhs)
          parse_infix_loop(state, node, min_bp)
        end

      # Pipe (left-assoc)
      {:pipe, _, _} when 3 >= min_bp ->
        state = advance(state)

        with {:ok, rhs, state} <- parse_expression(state, 4) do
          span = merge(AST.span(lhs), AST.span(rhs))
          parse_infix_loop(state, {:pipe, span, lhs, rhs}, min_bp)
        end

      # Or (left-assoc)
      {:or_or, _, _} when 5 >= min_bp ->
        state = advance(state)

        with {:ok, rhs, state} <- parse_expression(state, 6) do
          span = merge(AST.span(lhs), AST.span(rhs))
          parse_infix_loop(state, {:binop, span, :or, lhs, rhs}, min_bp)
        end

      # And (left-assoc)
      {:and_and, _, _} when 7 >= min_bp ->
        state = advance(state)

        with {:ok, rhs, state} <- parse_expression(state, 8) do
          span = merge(AST.span(lhs), AST.span(rhs))
          parse_infix_loop(state, {:binop, span, :and, lhs, rhs}, min_bp)
        end

      # Equality (left-assoc)
      {:eq_eq, _, _} when 9 >= min_bp ->
        parse_binop(state, lhs, min_bp, :eq, 10)

      {:neq, _, _} when 9 >= min_bp ->
        parse_binop(state, lhs, min_bp, :neq, 10)

      # Comparison (left-assoc)
      {:lt, _, _} when 11 >= min_bp ->
        parse_binop(state, lhs, min_bp, :lt, 12)

      {:gt, _, _} when 11 >= min_bp ->
        parse_binop(state, lhs, min_bp, :gt, 12)

      {:lte, _, _} when 11 >= min_bp ->
        parse_binop(state, lhs, min_bp, :lte, 12)

      {:gte, _, _} when 11 >= min_bp ->
        parse_binop(state, lhs, min_bp, :gte, 12)

      # Addition (left-assoc)
      {:plus, _, _} when 13 >= min_bp ->
        parse_binop(state, lhs, min_bp, :add, 14)

      {:minus, _, _} when 13 >= min_bp ->
        parse_binop(state, lhs, min_bp, :sub, 14)

      # Multiplication (left-assoc)
      {:star, _, _} when 15 >= min_bp ->
        parse_binop(state, lhs, min_bp, :mul, 16)

      {:slash, _, _} when 15 >= min_bp ->
        parse_binop(state, lhs, min_bp, :div, 16)

      # Not an infix operator at this precedence — stop.
      _ ->
        {:ok, lhs, state}
    end
  end

  defp parse_binop(state, lhs, min_bp, op, right_bp) do
    state = advance(state)

    with {:ok, rhs, state} <- parse_expression(state, right_bp) do
      span = merge(AST.span(lhs), AST.span(rhs))
      parse_infix_loop(state, {:binop, span, op, lhs, rhs}, min_bp)
    end
  end

  defp parse_arg_list(state, acc \\ []) do
    case peek(state) do
      {:rparen, _, _} ->
        {:ok, Enum.reverse(acc), advance(state)}

      _ ->
        with {:ok, arg, state} <- parse_expression(state, 0) do
          case peek(state) do
            {:comma, _, _} ->
              state = advance(state)
              # Allow trailing comma.
              case peek(state) do
                {:rparen, _, _} -> {:ok, Enum.reverse([arg | acc]), advance(state)}
                _ -> parse_arg_list(state, [arg | acc])
              end

            {:rparen, _, _} ->
              {:ok, Enum.reverse([arg | acc]), advance(state)}

            {t, s, _} ->
              {:error, "expected , or ) in argument list, got #{t}", s}
          end
        end
    end
  end

  # Convert annotation to pi type when arrow follows.
  defp make_arrow({:ann, _, {:var, _, name}, domain}, rhs) do
    span = merge(AST.span(domain), AST.span(rhs))
    {:pi, span, {name, :omega, false}, domain, rhs}
  end

  # Erased pi: the lhs is a special erased annotation marker.
  defp make_arrow({:__erased_binder, _, name, mult, domain}, rhs) do
    span = merge(AST.span(domain), AST.span(rhs))
    {:pi, span, {name, mult, false}, domain, rhs}
  end

  # Implicit pi: lhs is an implicit binder marker.
  defp make_arrow({:__implicit_binder, _, name, mult, domain}, rhs) do
    span = merge(AST.span(domain), AST.span(rhs))
    {:pi, span, {name, mult, true}, domain, rhs}
  end

  defp make_arrow(domain, codomain) do
    span = merge(AST.span(domain), AST.span(codomain))
    {:pi, span, {:_, :omega, false}, domain, codomain}
  end

  # ============================================================================
  # Prefix expressions
  # ============================================================================

  defp parse_prefix(state) do
    case peek(state) do
      # Unary minus
      {:minus, span, _} ->
        state = advance(state)

        with {:ok, expr, state} <- parse_expression(state, 17) do
          {:ok, {:unaryop, merge(span, AST.span(expr)), :neg, expr}, state}
        end

      # Unary not
      {:not, span, _} ->
        state = advance(state)

        with {:ok, expr, state} <- parse_expression(state, 17) do
          {:ok, {:unaryop, merge(span, AST.span(expr)), :not, expr}, state}
        end

      _ ->
        parse_primary(state)
    end
  end

  # ============================================================================
  # Primary expressions
  # ============================================================================

  defp parse_primary(state) do
    case peek(state) do
      {:ident, span, val} ->
        {:ok, {:var, span, val}, advance(state)}

      {:upper_ident, span, :Type} ->
        {:ok, {:type_universe, span, nil}, advance(state)}

      {:upper_ident, span, val} ->
        {:ok, {:var, span, val}, advance(state)}

      {:int, span, val} ->
        {:ok, {:lit, span, val}, advance(state)}

      {:float, span, val} ->
        {:ok, {:lit, span, val}, advance(state)}

      {:string, span, val} ->
        {:ok, {:lit, span, val}, advance(state)}

      {:atom_lit, span, val} ->
        {:ok, {:lit, span, val}, advance(state)}

      {true, span, _} ->
        {:ok, {:lit, span, true}, advance(state)}

      {false, span, _} ->
        {:ok, {:lit, span, false}, advance(state)}

      {:underscore, span, _} ->
        {:ok, {:hole, span}, advance(state)}

      {:lparen, _, _} ->
        parse_paren_expr(state)

      {:lbrace, _, _} ->
        parse_brace_expr(state)

      {:fn, _, _} ->
        parse_fn_expr(state)

      {:case, _, _} ->
        parse_case_expr(state)

      {:with, _, _} ->
        parse_with_expr(state)

      {:let, _, _} ->
        parse_let_expr(state)

      {:if, _, _} ->
        parse_if_expr(state)

      {:percent, _, _} ->
        parse_record_expr(state)

      {tag, span, _} ->
        {:error, "expected expression, got #{tag}", span}
    end
  end

  # ============================================================================
  # Parenthesized expressions, annotations, pi types, sigma types
  # ============================================================================

  defp parse_paren_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    # Check for erased binder: (0 name : type)
    case peek(state) do
      {:int, _, 0} ->
        case peek2(state) do
          {:ident, _, _} ->
            parse_erased_paren(state, start_span)

          _ ->
            parse_paren_inner(state, start_span)
        end

      _ ->
        parse_paren_inner(state, start_span)
    end
  end

  defp parse_erased_paren(state, start_span) do
    # (0 name : type) — erased binder, may become pi if -> follows
    state = advance(state)

    with {:ok, name, _name_span, state} <- expect_ident(state),
         {:ok, state} <- expect(state, :colon),
         {:ok, type, state} <- parse_expression(state, 0),
         {:ok, state} <- expect(state, :rparen) do
      # Return a special marker that make_arrow will recognize.
      {:ok, {:__erased_binder, merge(start_span, span_of(state)), name, :zero, type}, state}
    end
  end

  defp parse_paren_inner(state, start_span) do
    with {:ok, expr, state} <- parse_expression(state, 0) do
      case peek(state) do
        # Annotation or pi binder: (expr : type ...)
        {:colon, _, _} ->
          state = advance(state)

          with {:ok, type, state} <- parse_expression(state, 0) do
            case peek(state) do
              # Sigma type: (name : type, type)
              {:comma, _, _} ->
                state = advance(state)

                with {:ok, snd_type, state} <- parse_expression(state, 0),
                     {:ok, state} <- expect(state, :rparen) do
                  name = extract_var_name(expr)
                  span = merge(start_span, span_of(state))
                  {:ok, {:sigma, span, name, type, snd_type}, state}
                end

              # (name : type) — annotation that may become pi
              {:rparen, _, _} ->
                state = advance(state)
                span = merge(start_span, span_of(state))
                {:ok, {:ann, span, expr, type}, state}

              {t, s, _} ->
                {:error, "expected , or ) after type annotation, got #{t}", s}
            end
          end

        # Product type: (A, B) or (A, B, C) — desugars to nested sigma.
        {:comma, _, _} ->
          state = advance(state)

          with {:ok, rest, state} <- parse_tuple_rest(state),
               {:ok, state} <- expect(state, :rparen) do
            span = merge(start_span, span_of(state))
            all = [expr | rest]

            # Right-fold into nested sigma: (A, B, C) → sigma(:_, A, sigma(:_, B, C))
            product =
              List.foldr(all, nil, fn
                elem, nil -> elem
                elem, acc -> {:sigma, merge(AST.span(elem), AST.span(acc)), :_, elem, acc}
              end)

            # Wrap outermost sigma with the full paren span.
            {:ok, put_elem(product, 1, span), state}
          end

        # Just a grouped expression
        {:rparen, _, _} ->
          {:ok, expr, advance(state)}

        {t, s, _} ->
          {:error, "expected ) after expression, got #{t}", s}
      end
    end
  end

  defp parse_tuple_rest(state, acc \\ []) do
    with {:ok, expr, state} <- parse_expression(state, 0) do
      case peek(state) do
        {:comma, _, _} -> parse_tuple_rest(advance(state), [expr | acc])
        _ -> {:ok, Enum.reverse([expr | acc]), state}
      end
    end
  end

  defp extract_var_name({:var, _, name}), do: name
  defp extract_var_name(_), do: :_

  # ============================================================================
  # Brace expressions: refinement types {x : T | P} and implicit binders {x : T}
  # ============================================================================

  defp parse_brace_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    # Check for optional multiplicity.
    {mult, state} = parse_optional_mult(state)

    with {:ok, name, _name_span, state} <- expect_ident(state),
         {:ok, state} <- expect(state, :colon),
         {:ok, type, state} <- parse_expression(state, 0) do
      case peek(state) do
        # Refinement: {x : T | P}
        {:bar, _, _} ->
          state = advance(state)

          with {:ok, pred, state} <- parse_expression(state, 0),
               {:ok, state} <- expect(state, :rbrace) do
            span = merge(start_span, span_of(state))
            {:ok, {:refinement, span, name, type, pred}, state}
          end

        # Implicit binder: {x : T} — may become pi if -> follows
        {:rbrace, _, _} ->
          state = advance(state)
          span = merge(start_span, span_of(state))
          {:ok, {:__implicit_binder, span, name, mult, type}, state}

        {t, s, _} ->
          {:error, "expected | or } in brace expression, got #{t}", s}
      end
    end
  end

  # ============================================================================
  # Lambda: fn(params) do body end
  # ============================================================================

  defp parse_fn_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, params, state} <- parse_params(state),
         {:ok, state} <- expect(state, :arrow) do
      state = skip_newlines(state)

      with {:ok, body, state} <- parse_block(state) do
        {_, end_span, _} = peek(state)

        with {:ok, state} <- expect(state, :end) do
          node = curry_lambda(start_span, end_span, params, body)
          {:ok, node, state}
        end
      end
    end
  end

  # Desugar multi-param lambda into nested single-param lambdas.
  defp curry_lambda(start_span, end_span, [param], body) do
    {:fn, merge(start_span, end_span), [param], body}
  end

  defp curry_lambda(start_span, end_span, [param | rest], body) do
    inner = curry_lambda(start_span, end_span, rest, body)
    {:fn, merge(start_span, end_span), [param], inner}
  end

  defp curry_lambda(start_span, end_span, [], body) do
    {:fn, merge(start_span, end_span), [], body}
  end

  # ============================================================================
  # Case expression
  # ============================================================================

  # with e1, e2 do p1 -> body1; p2 -> body2 end
  defp parse_with_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, scrutinees, state} <- parse_with_scrutinees(state, []),
         {:ok, state} <- expect(state, :do) do
      state = skip_newlines(state)

      with {:ok, branches, state} <- parse_branches(state, []) do
        {_, end_span, _} = peek(state)

        with {:ok, state} <- expect(state, :end) do
          {:ok, {:with, merge(start_span, end_span), scrutinees, branches}, state}
        end
      end
    end
  end

  defp parse_with_scrutinees(state, acc) do
    with {:ok, expr, state} <- parse_expression(state, 0) do
      state = skip_newlines(state)

      case peek(state) do
        {:comma, _, _} ->
          state = skip_newlines(advance(state))
          parse_with_scrutinees(state, [expr | acc])

        _ ->
          {:ok, Enum.reverse([expr | acc]), state}
      end
    end
  end

  defp parse_case_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, scrutinee, state} <- parse_expression(state, 0),
         {:ok, state} <- expect(state, :do) do
      state = skip_newlines(state)

      with {:ok, branches, state} <- parse_branches(state, []) do
        {_, end_span, _} = peek(state)

        with {:ok, state} <- expect(state, :end) do
          {:ok, {:case, merge(start_span, end_span), scrutinee, branches}, state}
        end
      end
    end
  end

  defp parse_branches(state, acc) do
    state = skip_newlines(state)

    case peek(state) do
      {:end, _, _} ->
        {:ok, Enum.reverse(acc), state}

      _ ->
        case parse_single_branch(state) do
          {:ok, branch, state} ->
            parse_branches(state, [branch | acc])

          {:error, msg, span} ->
            add_error(msg, span)
            state = sync_branch(state)
            parse_branches(state, acc)
        end
    end
  end

  defp parse_single_branch(state) do
    with {:ok, pattern, state} <- parse_pattern(state),
         {:ok, state} <- expect(state, :arrow) do
      state = skip_newlines(state)

      with {:ok, body, state} <- parse_expression(state, 0) do
        span = merge(AST.span(pattern), AST.span(body))
        {:ok, {:branch, span, pattern, body}, state}
      end
    end
  end

  # ============================================================================
  # Let expression
  # ============================================================================

  defp parse_let_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, name, _name_span, state} <- expect_ident(state),
         {:ok, state} <- expect(state, :eq) do
      with {:ok, value, state} <- parse_expression(state, 0) do
        state = skip_newlines(state)

        with {:ok, body, state} <- parse_expression(state, 0) do
          {:ok, {:let, merge(start_span, AST.span(body)), name, value, body}, state}
        end
      end
    end
  end

  # ============================================================================
  # If expression
  # ============================================================================

  defp parse_if_expr(state) do
    {_, start_span, _} = peek(state)
    state = advance(state)

    with {:ok, cond_expr, state} <- parse_expression(state, 0),
         {:ok, state} <- expect(state, :do) do
      with {:ok, then_expr, state} <- parse_block(state) do
        state = skip_newlines(state)

        with {:ok, state} <- expect(state, :else) do
          with {:ok, else_expr, state} <- parse_block(state) do
            {_, end_span, _} = peek(state)

            with {:ok, state} <- expect(state, :end) do
              {:ok, {:if, merge(start_span, end_span), cond_expr, then_expr, else_expr}, state}
            end
          end
        end
      end
    end
  end

  # ============================================================================
  # Patterns
  # ============================================================================

  defp parse_pattern(state) do
    case peek(state) do
      {:underscore, span, _} ->
        {:ok, {:pat_wildcard, span}, advance(state)}

      {:ident, span, val} ->
        state = advance(state)

        case peek(state) do
          # Constructor pattern: name(args)
          {:lparen, _, _} ->
            state = advance(state)

            with {:ok, args, state} <- parse_pattern_args(state) do
              end_span = span_of(state)
              {:ok, {:pat_constructor, merge(span, end_span), val, args}, state}
            end

          _ ->
            {:ok, {:pat_var, span, val}, state}
        end

      {:upper_ident, span, val} ->
        state = advance(state)

        case peek(state) do
          {:lparen, _, _} ->
            state = advance(state)

            with {:ok, args, state} <- parse_pattern_args(state) do
              end_span = span_of(state)
              {:ok, {:pat_constructor, merge(span, end_span), val, args}, state}
            end

          _ ->
            {:ok, {:pat_constructor, span, val, []}, state}
        end

      {:atom_lit, span, val} ->
        {:ok, {:pat_lit, span, val}, advance(state)}

      {:int, span, val} ->
        {:ok, {:pat_lit, span, val}, advance(state)}

      {:float, span, val} ->
        {:ok, {:pat_lit, span, val}, advance(state)}

      {:string, span, val} ->
        {:ok, {:pat_lit, span, val}, advance(state)}

      {true, span, _} ->
        {:ok, {:pat_lit, span, true}, advance(state)}

      {false, span, _} ->
        {:ok, {:pat_lit, span, false}, advance(state)}

      # Negative numeric literals in patterns.
      {:minus, span, _} ->
        state = advance(state)

        case peek(state) do
          {:int, _, val} ->
            {:ok, {:pat_lit, merge(span, span_of(state)), -val}, advance(state)}

          {:float, _, val} ->
            {:ok, {:pat_lit, merge(span, span_of(state)), -val}, advance(state)}

          {t, s, _} ->
            {:error, "expected number after - in pattern, got #{t}", s}
        end

      {:percent, span, _} ->
        parse_record_pattern(state, span)

      {tag, span, _} ->
        {:error, "expected pattern, got #{tag}", span}
    end
  end

  defp parse_pattern_args(state, acc \\ []) do
    case peek(state) do
      {:rparen, _, _} ->
        {:ok, Enum.reverse(acc), advance(state)}

      _ ->
        with {:ok, pat, state} <- parse_pattern(state) do
          case peek(state) do
            {:comma, _, _} -> parse_pattern_args(advance(state), [pat | acc])
            {:rparen, _, _} -> {:ok, Enum.reverse([pat | acc]), advance(state)}
            {t, s, _} -> {:error, "expected , or ) in pattern args, got #{t}", s}
          end
        end
    end
  end
end
