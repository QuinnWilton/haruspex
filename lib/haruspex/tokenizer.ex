defmodule Haruspex.Tokenizer do
  @moduledoc """
  NimbleParsec tokenizer for Haruspex source code.

  Converts source text into a flat stream of tokens, each carrying a
  `Pentiment.Span.Byte` for precise error reporting. Keywords are reserved
  and checked after identifier recognition. Consecutive newlines collapse
  to a single `:newline` token. Newlines inside parentheses, braces, and
  brackets are suppressed.
  """

  # keywords
  @type token_tag ::
          :def
          | :do
          | :end
          | :type
          | :case
          | :fn
          | :let
          | :if
          | :else
          | :import
          | :mutual
          | :class
          | :instance
          | :record
          | :with
          | :where
          # literals
          | :int
          | :float
          | :string
          | :atom_lit
          | true
          | false
          # identifiers
          | :ident
          | :upper_ident
          # operators
          | :plus
          | :minus
          | :star
          | :slash
          | :eq
          | :eq_eq
          | :neq
          | :lt
          | :gt
          | :lte
          | :gte
          | :and_and
          | :or_or
          | :not
          | :pipe
          | :bar
          | :arrow
          | :fat_arrow
          | :colon
          | :dot
          # delimiters
          | :lparen
          | :rparen
          | :lbrace
          | :rbrace
          | :lbracket
          | :rbracket
          | :comma
          | :newline
          | :underscore
          | :at
          # special
          | :eof

  @type token :: {token_tag(), Pentiment.Span.Byte.t(), term()}

  @type error :: {:error, String.t(), non_neg_integer()}

  @keywords MapSet.new(~w[
    def do end type case fn let if else import mutual
    class instance record with where
  ]a)

  @spec tokenize(String.t()) :: {:ok, [token()]} | error()
  def tokenize(source) when is_binary(source) do
    case do_tokenize(source, 0, [], 0) do
      {:ok, tokens} ->
        eof_span = %Pentiment.Span.Byte{start: byte_size(source), length: 1}
        {:ok, Enum.reverse([{:eof, eof_span, nil} | tokens])}

      {:error, _msg, _pos} = err ->
        err
    end
  end

  # Main tokenization loop.
  defp do_tokenize(<<>>, _pos, acc, _depth), do: {:ok, acc}

  # Skip spaces and tabs (not newlines).
  defp do_tokenize(<<c, rest::binary>>, pos, acc, depth) when c in [?\s, ?\t, ?\r] do
    do_tokenize(rest, pos + 1, acc, depth)
  end

  # Comments: skip to end of line.
  defp do_tokenize(<<"#", rest::binary>>, pos, acc, depth) do
    {skipped, rest2} = skip_comment(rest, 0)
    do_tokenize(rest2, pos + 1 + skipped, acc, depth)
  end

  # Newlines: collapse consecutive, suppress inside delimiters.
  defp do_tokenize(<<"\n", rest::binary>>, pos, acc, depth) do
    {skipped, rest2} = skip_newlines(rest, 0)
    new_pos = pos + 1 + skipped

    if depth > 0 do
      do_tokenize(rest2, new_pos, acc, depth)
    else
      # Don't emit consecutive newlines.
      case acc do
        [{:newline, _, _} | _] ->
          do_tokenize(rest2, new_pos, acc, depth)

        _ ->
          span = %Pentiment.Span.Byte{start: pos, length: 1}
          do_tokenize(rest2, new_pos, [{:newline, span, nil} | acc], depth)
      end
    end
  end

  # Two-character operators (must come before single-char).
  defp do_tokenize(<<"->", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :arrow, nil, acc, depth)
  end

  defp do_tokenize(<<"=>", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :fat_arrow, nil, acc, depth)
  end

  defp do_tokenize(<<"==", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :eq_eq, nil, acc, depth)
  end

  defp do_tokenize(<<"!=", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :neq, nil, acc, depth)
  end

  defp do_tokenize(<<"<=", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :lte, nil, acc, depth)
  end

  defp do_tokenize(<<">=", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :gte, nil, acc, depth)
  end

  defp do_tokenize(<<"|>", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :pipe, nil, acc, depth)
  end

  defp do_tokenize(<<"&&", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :and_and, nil, acc, depth)
  end

  defp do_tokenize(<<"||", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 2, :or_or, nil, acc, depth)
  end

  # Bare | (after |> and || are matched above).
  defp do_tokenize(<<"|", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :bar, nil, acc, depth)
  end

  # Single-character operators and delimiters.
  defp do_tokenize(<<"+", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :plus, nil, acc, depth)
  end

  defp do_tokenize(<<"-", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :minus, nil, acc, depth)
  end

  defp do_tokenize(<<"*", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :star, nil, acc, depth)
  end

  defp do_tokenize(<<"/", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :slash, nil, acc, depth)
  end

  defp do_tokenize(<<"<", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :lt, nil, acc, depth)
  end

  defp do_tokenize(<<"=", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :eq, nil, acc, depth)
  end

  defp do_tokenize(<<">", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :gt, nil, acc, depth)
  end

  defp do_tokenize(<<":", rest::binary>>, pos, acc, depth) do
    # Check for atom literal: colon followed by identifier start.
    case rest do
      <<c, _::binary>> when c in ?a..?z or c in ?A..?Z or c == ?_ ->
        {name, len, rest2} = read_ident_chars(rest, 0, <<>>)
        total_len = 1 + len
        span = %Pentiment.Span.Byte{start: pos, length: total_len}
        atom_val = String.to_atom(name)
        do_tokenize(rest2, pos + total_len, [{:atom_lit, span, atom_val} | acc], depth)

      _ ->
        emit(rest, pos, 1, :colon, nil, acc, depth)
    end
  end

  defp do_tokenize(<<".", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :dot, nil, acc, depth)
  end

  defp do_tokenize(<<",", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :comma, nil, acc, depth)
  end

  defp do_tokenize(<<"@", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :at, nil, acc, depth)
  end

  defp do_tokenize(<<"_", rest::binary>>, pos, acc, depth) do
    # Check if this is just `_` (hole/wildcard) or an identifier starting with `_`.
    case rest do
      <<c, _::binary>> when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ ->
        {name, len, rest2} = read_ident_chars(rest, 0, <<>>)
        total_len = 1 + len
        span = %Pentiment.Span.Byte{start: pos, length: total_len}

        do_tokenize(
          rest2,
          pos + total_len,
          [{:ident, span, String.to_atom("_" <> name)} | acc],
          depth
        )

      _ ->
        emit(rest, pos, 1, :underscore, nil, acc, depth)
    end
  end

  # Delimiter nesting for newline suppression.
  defp do_tokenize(<<"(", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :lparen, nil, acc, depth + 1)
  end

  defp do_tokenize(<<")", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :rparen, nil, acc, max(depth - 1, 0))
  end

  defp do_tokenize(<<"{", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :lbrace, nil, acc, depth + 1)
  end

  defp do_tokenize(<<"}", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :rbrace, nil, acc, max(depth - 1, 0))
  end

  defp do_tokenize(<<"[", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :lbracket, nil, acc, depth + 1)
  end

  defp do_tokenize(<<"]", rest::binary>>, pos, acc, depth) do
    emit(rest, pos, 1, :rbracket, nil, acc, max(depth - 1, 0))
  end

  # String literals.
  defp do_tokenize(<<"\"", rest::binary>>, pos, acc, depth) do
    case read_string(rest, <<>>) do
      {:ok, value, len, rest2} ->
        # len includes content + closing quote.
        total_len = 1 + len
        span = %Pentiment.Span.Byte{start: pos, length: total_len}
        do_tokenize(rest2, pos + total_len, [{:string, span, value} | acc], depth)

      {:error, msg} ->
        {:error, msg, pos}
    end
  end

  # Numeric literals (integer or float).
  defp do_tokenize(<<c, _::binary>> = source, pos, acc, depth) when c in ?0..?9 do
    {int_str, int_len, rest} = read_digits(source, 0, <<>>)

    case rest do
      <<".", next, rest2::binary>> when next in ?0..?9 ->
        {frac_str, frac_len, rest3} = read_digits(<<next, rest2::binary>>, 0, <<>>)
        total_len = int_len + 1 + frac_len
        span = %Pentiment.Span.Byte{start: pos, length: total_len}
        value = String.to_float(int_str <> "." <> frac_str)
        do_tokenize(rest3, pos + total_len, [{:float, span, value} | acc], depth)

      _ ->
        span = %Pentiment.Span.Byte{start: pos, length: int_len}
        value = String.to_integer(int_str)
        do_tokenize(rest, pos + int_len, [{:int, span, value} | acc], depth)
    end
  end

  # Uppercase identifiers (type/module names).
  defp do_tokenize(<<c, _::binary>> = source, pos, acc, depth) when c in ?A..?Z do
    {name, len, rest} = read_ident_chars(source, 0, <<>>)
    span = %Pentiment.Span.Byte{start: pos, length: len}
    atom_name = String.to_atom(name)
    do_tokenize(rest, pos + len, [{:upper_ident, span, atom_name} | acc], depth)
  end

  # Lowercase identifiers and keywords.
  defp do_tokenize(<<c, _::binary>> = source, pos, acc, depth) when c in ?a..?z do
    {name, len, rest} = read_ident_chars(source, 0, <<>>)
    span = %Pentiment.Span.Byte{start: pos, length: len}
    atom_name = String.to_atom(name)

    tag =
      case atom_name do
        true -> true
        false -> false
        :not -> :not
        other -> if MapSet.member?(@keywords, other), do: other, else: :ident
      end

    value = if tag in [true, false], do: atom_name == true, else: atom_name
    do_tokenize(rest, pos + len, [{tag, span, value} | acc], depth)
  end

  # Catch-all for unexpected characters (handles multi-byte UTF-8).
  defp do_tokenize(<<c::utf8, _::binary>>, pos, _acc, _depth) do
    {:error, "unexpected character: #{<<c::utf8>>}", pos}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp emit(rest, pos, len, tag, value, acc, depth) do
    span = %Pentiment.Span.Byte{start: pos, length: len}
    do_tokenize(rest, pos + len, [{tag, span, value} | acc], depth)
  end

  defp read_ident_chars(<<c, rest::binary>>, len, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    read_ident_chars(rest, len + 1, <<acc::binary, c>>)
  end

  defp read_ident_chars(rest, len, acc), do: {acc, len, rest}

  defp read_digits(<<c, rest::binary>>, len, acc) when c in ?0..?9 do
    read_digits(rest, len + 1, <<acc::binary, c>>)
  end

  defp read_digits(rest, len, acc), do: {acc, len, rest}

  # read_string tracks source bytes consumed (not output bytes) to handle
  # escape sequences correctly (e.g., \n is 2 source bytes but 1 output byte).
  defp read_string(source, acc, source_len \\ 0)

  defp read_string(<<"\\", c, rest::binary>>, acc, source_len) do
    escaped =
      case c do
        ?n -> ?\n
        ?t -> ?\t
        ?\\ -> ?\\
        ?" -> ?"
        ?r -> ?\r
        ?0 -> 0
        _ -> :invalid
      end

    if escaped == :invalid do
      {:error, "invalid escape sequence: \\#{<<c::utf8>>}"}
    else
      read_string(rest, <<acc::binary, escaped>>, source_len + 2)
    end
  end

  defp read_string(<<"\"", rest::binary>>, acc, source_len) do
    # +1 for the closing quote.
    {:ok, acc, source_len + 1, rest}
  end

  defp read_string(<<>>, _acc, _source_len) do
    {:error, "unterminated string"}
  end

  defp read_string(<<c, rest::binary>>, acc, source_len) do
    read_string(rest, <<acc::binary, c>>, source_len + 1)
  end

  defp skip_comment(<<"\n", _::binary>> = rest, count), do: {count, rest}
  defp skip_comment(<<>>, count), do: {count, <<>>}
  defp skip_comment(<<_, rest::binary>>, count), do: skip_comment(rest, count + 1)

  defp skip_newlines(<<"\n", rest::binary>>, count), do: skip_newlines(rest, count + 1)
  defp skip_newlines(rest, count), do: {count, rest}
end
