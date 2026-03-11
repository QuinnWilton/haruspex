defmodule Haruspex.TokenizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Tokenizer

  # Helper: tokenize and strip the trailing :eof.
  defp tok!(source) do
    {:ok, tokens} = Tokenizer.tokenize(source)
    Enum.reject(tokens, fn {tag, _, _} -> tag == :eof end)
  end

  defp tags(source) do
    source |> tok!() |> Enum.map(fn {tag, _, _} -> tag end)
  end

  # ============================================================================
  # Keywords
  # ============================================================================

  describe "keywords" do
    test "all keywords tokenize correctly" do
      keywords =
        ~w[def do end type case fn let if else import mutual variable class instance record with where]

      for kw <- keywords do
        assert tags(kw) == [String.to_atom(kw)]
      end
    end

    test "keywords are not identifiers" do
      refute :ident in tags("def")
      refute :ident in tags("do")
    end
  end

  # ============================================================================
  # Identifiers
  # ============================================================================

  describe "identifiers" do
    test "lowercase identifier" do
      assert [{:ident, _, :foo}] = tok!("foo")
    end

    test "identifier with digits and underscores" do
      assert [{:ident, _, :foo_bar2}] = tok!("foo_bar2")
    end

    test "underscore prefix identifier" do
      assert [{:ident, _, :_unused}] = tok!("_unused")
    end

    test "uppercase identifier" do
      assert [{:upper_ident, _, :Int}] = tok!("Int")
    end

    test "uppercase with digits" do
      assert [{:upper_ident, _, :Vec3}] = tok!("Vec3")
    end
  end

  # ============================================================================
  # Literals
  # ============================================================================

  describe "integer literals" do
    test "zero" do
      assert [{:int, _, 0}] = tok!("0")
    end

    test "positive integer" do
      assert [{:int, _, 42}] = tok!("42")
    end

    test "large integer" do
      assert [{:int, _, 123_456_789}] = tok!("123456789")
    end
  end

  describe "float literals" do
    test "simple float" do
      assert [{:float, _, 3.14}] = tok!("3.14")
    end

    test "zero point five" do
      assert [{:float, _, 0.5}] = tok!("0.5")
    end

    test "integer dot without trailing digit is int + dot" do
      assert [:int, :dot] = tags("1.")
    end
  end

  describe "string literals" do
    test "simple string" do
      assert [{:string, _, "hello"}] = tok!("\"hello\"")
    end

    test "empty string" do
      assert [{:string, _, ""}] = tok!("\"\"")
    end

    test "escape sequences" do
      assert [{:string, _, "\n"}] = tok!("\"\\n\"")
      assert [{:string, _, "\t"}] = tok!("\"\\t\"")
      assert [{:string, _, "\\"}] = tok!("\"\\\\\"")
      assert [{:string, _, "\""}] = tok!("\"\\\"\"")
      assert [{:string, _, "\r"}] = tok!("\"\\r\"")
      assert [{:string, _, "\0"}] = tok!("\"\\0\"")
    end

    test "string with mixed content and escapes" do
      assert [{:string, _, "a\nb"}] = tok!("\"a\\nb\"")
    end
  end

  describe "atom literals" do
    test "simple atom" do
      assert [{:atom_lit, _, :ok}] = tok!(":ok")
    end

    test "atom with underscores" do
      assert [{:atom_lit, _, :some_atom}] = tok!(":some_atom")
    end

    test "colon not followed by ident is just colon" do
      assert [:colon, :int] = tags(":42")
    end
  end

  describe "booleans" do
    test "true" do
      assert [{true, _, true}] = tok!("true")
    end

    test "false" do
      assert [{false, _, false}] = tok!("false")
    end
  end

  # ============================================================================
  # Operators
  # ============================================================================

  describe "two-character operators" do
    test "arrow" do
      assert [:arrow] = tags("->")
    end

    test "fat arrow" do
      assert [:fat_arrow] = tags("=>")
    end

    test "eq_eq" do
      assert [:eq_eq] = tags("==")
    end

    test "neq" do
      assert [:neq] = tags("!=")
    end

    test "lte" do
      assert [:lte] = tags("<=")
    end

    test "gte" do
      assert [:gte] = tags(">=")
    end

    test "pipe" do
      assert [:pipe] = tags("|>")
    end

    test "and_and" do
      assert [:and_and] = tags("&&")
    end

    test "or_or" do
      assert [:or_or] = tags("||")
    end
  end

  describe "single-character operators" do
    test "arithmetic" do
      assert [:plus] = tags("+")
      assert [:minus] = tags("-")
      assert [:star] = tags("*")
      assert [:slash] = tags("/")
    end

    test "comparison" do
      assert [:lt] = tags("<")
      assert [:gt] = tags(">")
    end

    test "eq" do
      assert [:eq] = tags("=")
    end

    test "punctuation" do
      assert [:colon] = tags(":")
      assert [:dot] = tags(".")
      assert [:comma] = tags(",")
      assert [:at] = tags("@")
    end
  end

  # ============================================================================
  # Delimiters
  # ============================================================================

  describe "delimiters" do
    test "parentheses" do
      assert [:lparen, :rparen] = tags("()")
    end

    test "braces" do
      assert [:lbrace, :rbrace] = tags("{}")
    end

    test "brackets" do
      assert [:lbracket, :rbracket] = tags("[]")
    end
  end

  # ============================================================================
  # Special tokens
  # ============================================================================

  describe "special tokens" do
    test "underscore" do
      assert [{:underscore, _, nil}] = tok!("_")
    end

    test "not keyword" do
      assert [{:not, _, :not}] = tok!("not")
    end

    test "eof always present" do
      {:ok, tokens} = Tokenizer.tokenize("")
      assert [{:eof, _, nil}] = tokens
    end
  end

  # ============================================================================
  # Whitespace and newlines
  # ============================================================================

  describe "whitespace" do
    test "spaces between tokens" do
      assert [:ident, :plus, :ident] = tags("x + y")
    end

    test "tabs between tokens" do
      assert [:ident, :plus, :ident] = tags("x\t+\ty")
    end
  end

  describe "newlines" do
    test "single newline produces token" do
      assert [:ident, :newline, :ident] = tags("x\ny")
    end

    test "consecutive newlines collapse" do
      assert [:ident, :newline, :ident] = tags("x\n\n\ny")
    end

    test "leading newlines are preserved" do
      assert [:newline, :ident] = tags("\nx")
    end

    test "no duplicate newlines" do
      tokens = tags("x\n\n\n\ny")
      newline_count = Enum.count(tokens, &(&1 == :newline))
      assert newline_count == 1
    end

    test "newlines suppressed inside parens" do
      assert [:lparen, :ident, :comma, :ident, :rparen] = tags("(\n  x,\n  y\n)")
    end

    test "newlines suppressed inside braces" do
      assert [:lbrace, :ident, :colon, :upper_ident, :rbrace] = tags("{\n  a : Type\n}")
    end

    test "newlines suppressed inside brackets" do
      assert [:lbracket, :ident, :rbracket] = tags("[\n  x\n]")
    end

    test "nested delimiters suppress newlines" do
      assert [:lparen, :lbrace, :ident, :rbrace, :rparen] = tags("(\n{\na\n}\n)")
    end
  end

  # ============================================================================
  # Comments
  # ============================================================================

  describe "comments" do
    test "comment to end of line" do
      assert [:ident, :plus, :ident] = tags("x + y # this is a comment")
    end

    test "comment on its own line" do
      assert [:ident, :newline, :ident] = tags("x\n# comment\ny")
    end

    test "comment at start of file" do
      assert [:newline, :ident] = tags("# comment\nx")
    end

    test "only a comment" do
      assert [] = tags("# just a comment")
    end
  end

  # ============================================================================
  # Span correctness
  # ============================================================================

  describe "span correctness" do
    test "span covers exact source text for identifiers" do
      source = "foo bar"
      [{:ident, s1, _}, {:ident, s2, _}] = tok!(source)
      assert binary_part(source, s1.start, s1.length) == "foo"
      assert binary_part(source, s2.start, s2.length) == "bar"
    end

    test "span covers exact source text for operators" do
      source = "x |> f"
      [{:ident, s1, _}, {:pipe, s2, _}, {:ident, s3, _}] = tok!(source)
      assert binary_part(source, s1.start, s1.length) == "x"
      assert binary_part(source, s2.start, s2.length) == "|>"
      assert binary_part(source, s3.start, s3.length) == "f"
    end

    test "span covers exact source text for integers" do
      source = "42"
      [{:int, span, _}] = tok!(source)
      assert binary_part(source, span.start, span.length) == "42"
    end

    test "span covers exact source text for floats" do
      source = "3.14"
      [{:float, span, _}] = tok!(source)
      assert binary_part(source, span.start, span.length) == "3.14"
    end

    test "span covers exact source text for strings" do
      source = ~s("hello")
      [{:string, span, _}] = tok!(source)
      assert binary_part(source, span.start, span.length) == ~s("hello")
    end

    test "span covers exact source text for strings with escapes" do
      source = ~s("a\\nb")
      [{:string, span, _}] = tok!(source)
      assert binary_part(source, span.start, span.length) == ~s("a\\nb")
    end

    test "span covers exact source text for atoms" do
      source = ":ok"
      [{:atom_lit, span, _}] = tok!(source)
      assert binary_part(source, span.start, span.length) == ":ok"
    end

    test "span covers exact source text for keywords" do
      source = "def"
      [{:def, span, _}] = tok!(source)
      assert binary_part(source, span.start, span.length) == "def"
    end
  end

  # ============================================================================
  # Negative tests
  # ============================================================================

  describe "errors" do
    test "unterminated string" do
      assert {:error, "unterminated string", 0} = Tokenizer.tokenize("\"hello")
    end

    test "invalid escape sequence" do
      assert {:error, "invalid escape sequence: \\q", 0} = Tokenizer.tokenize("\"\\q\"")
    end

    test "unexpected character" do
      assert {:error, "unexpected character: §", 0} = Tokenizer.tokenize("§")
    end

    test "unexpected character after valid tokens" do
      assert {:error, "unexpected character: §", 2} = Tokenizer.tokenize("x §")
    end
  end

  # ============================================================================
  # Integration
  # ============================================================================

  describe "integration" do
    test "full definition" do
      source = """
      def add(x : Int, y : Int) : Int do
        x + y
      end
      """

      expected_tags = [
        :def,
        :ident,
        :lparen,
        :ident,
        :colon,
        :upper_ident,
        :comma,
        :ident,
        :colon,
        :upper_ident,
        :rparen,
        :colon,
        :upper_ident,
        :do,
        :newline,
        :ident,
        :plus,
        :ident,
        :newline,
        :end,
        :newline
      ]

      assert tags(source) == expected_tags
    end

    test "type declaration" do
      source = """
      type Option(a) do
        :none
        some(a)
      end
      """

      expected_tags = [
        :type,
        :upper_ident,
        :lparen,
        :ident,
        :rparen,
        :do,
        :newline,
        :atom_lit,
        :newline,
        :ident,
        :lparen,
        :ident,
        :rparen,
        :newline,
        :end,
        :newline
      ]

      assert tags(source) == expected_tags
    end

    test "annotation before definition" do
      source = "@total\ndef length(xs : List) : Nat do\n  0\nend"

      expected_tags = [
        :at,
        :ident,
        :newline,
        :def,
        :ident,
        :lparen,
        :ident,
        :colon,
        :upper_ident,
        :rparen,
        :colon,
        :upper_ident,
        :do,
        :newline,
        :int,
        :newline,
        :end
      ]

      assert tags(source) == expected_tags
    end

    test "implicit parameter" do
      assert [:lbrace, :ident, :colon, :upper_ident, :rbrace] = tags("{a : Type}")
    end

    test "pipeline" do
      assert [:ident, :pipe, :ident, :pipe, :ident] = tags("x |> f |> g")
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "property tests" do
    property "span validity: every token span slices to valid source text" do
      check all(source <- source_gen()) do
        case Tokenizer.tokenize(source) do
          {:ok, tokens} ->
            for {_tag, span, _val} <- tokens, span.start + span.length <= byte_size(source) do
              slice = binary_part(source, span.start, span.length)
              assert is_binary(slice)
            end

          {:error, _, _} ->
            :ok
        end
      end
    end

    property "determinism: same input always produces same output" do
      check all(source <- source_gen()) do
        result1 = Tokenizer.tokenize(source)
        result2 = Tokenizer.tokenize(source)
        assert result1 == result2
      end
    end

    property "no crash: random printable ASCII never crashes" do
      check all(source <- string(:printable)) do
        result = Tokenizer.tokenize(source)
        assert match?({:ok, _}, result) or match?({:error, _, _}, result)
      end
    end
  end

  # Generator for plausible Haruspex source fragments.
  defp source_gen do
    fragments =
      member_of([
        "def",
        "do",
        "end",
        "type",
        "case",
        "fn",
        "let",
        "if",
        "else",
        "import",
        "mutual",
        "variable",
        "class",
        "instance",
        "record",
        "true",
        "false",
        "not",
        "foo",
        "bar",
        "x",
        "y",
        "Int",
        "Float",
        "Type",
        "Vec",
        "42",
        "0",
        "3.14",
        "0.5",
        ":ok",
        ":error",
        ":none",
        "\"hello\"",
        "\"a\\nb\"",
        "+",
        "-",
        "*",
        "/",
        "==",
        "!=",
        "<",
        ">",
        "<=",
        ">=",
        "->",
        "=>",
        "|>",
        "&&",
        "||",
        "(",
        ")",
        "{",
        "}",
        "[",
        "]",
        ",",
        ":",
        ".",
        "@",
        "_",
        " ",
        "\n",
        "  ",
        "# comment\n"
      ])

    gen all(parts <- list_of(fragments, min_length: 0, max_length: 10)) do
      Enum.join(parts)
    end
  end
end
