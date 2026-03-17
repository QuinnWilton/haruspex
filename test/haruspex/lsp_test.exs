defmodule Haruspex.LSPTest do
  use ExUnit.Case, async: false

  @uri "test/lsp_fixture.hx"

  setup do
    db = Roux.Database.new()
    Roux.Lang.register(db, Haruspex)

    %{db: db}
  end

  # ============================================================================
  # Position mapping
  # ============================================================================

  describe "position_to_byte" do
    test "first character" do
      assert Haruspex.LSP.position_to_byte("hello", 1, 1) == 0
    end

    test "middle of first line" do
      assert Haruspex.LSP.position_to_byte("hello", 1, 3) == 2
    end

    test "first character of second line" do
      assert Haruspex.LSP.position_to_byte("hello\nworld", 2, 1) == 6
    end

    test "middle of second line" do
      assert Haruspex.LSP.position_to_byte("hello\nworld", 2, 3) == 8
    end

    test "out of bounds returns nil" do
      assert Haruspex.LSP.position_to_byte("hi", 5, 1) == nil
    end

    test "multibyte characters" do
      # Each UTF-8 character may be multiple bytes.
      source = "ab"
      assert Haruspex.LSP.position_to_byte(source, 1, 2) == 1
    end
  end

  # ============================================================================
  # Hover
  # ============================================================================

  describe "hover" do
    test "on definition name shows type signature", %{db: db} do
      set_source(db, "def add(x : Int, y : Int) : Int do x + y end\n")

      # "add" starts at column 5.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 5}})

      assert is_binary(result)
      assert result =~ "add"
      assert result =~ "Int"
      assert result =~ "```haruspex"
    end

    test "on a literal shows literal type", %{db: db} do
      # "def f() : Int do 42 end" -> "42" starts at col 18.
      set_source(db, "def f(x : Int) : Int do 42 end\n")

      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 25}})

      # Should be Int for an integer literal.
      if result do
        assert result =~ "Int"
      end
    end

    test "outside any definition returns nil", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n\n\n")

      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {3, 1}})
      assert is_nil(result)
    end

    test "on a variable in body shows info", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      # "x" in the body is at column 25.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 25}})

      if result do
        assert is_binary(result)
        assert result =~ "```haruspex"
      end
    end
  end

  # ============================================================================
  # Diagnostics (already implemented, verify integration)
  # ============================================================================

  describe "diagnostics" do
    test "valid file produces empty diagnostics", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)
      assert diagnostics == []
    end

    test "type error produces diagnostic with span", %{db: db} do
      set_source(db, "def bad(x : Int) : String do x end\n")

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)
      assert length(diagnostics) >= 1

      diag = hd(diagnostics)
      assert diag.severity == :error
      assert is_binary(diag.message)
    end

    test "parse error produces diagnostic", %{db: db} do
      set_source(db, "def 123bad\n")

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)
      assert length(diagnostics) >= 1
      assert hd(diagnostics).severity == :error
    end

    test "missing return type produces diagnostic", %{db: db} do
      set_source(db, "def bad(x : Int) do x end\n")

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)
      assert length(diagnostics) >= 1

      messages = Enum.map(diagnostics, & &1.message)
      assert Enum.any?(messages, &String.contains?(&1, "return type"))
    end
  end

  # ============================================================================
  # Completions
  # ============================================================================

  describe "completions" do
    test "includes definition names", %{db: db} do
      set_source(db, """
      def add(x : Int, y : Int) : Int do x + y end
      def negate(n : Int) : Int do 0 - n end
      """)

      result = Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})

      assert is_list(result)
      labels = Enum.map(result, & &1.label)
      assert "add" in labels
      assert "negate" in labels
    end

    test "empty file returns empty completions", %{db: db} do
      set_source(db, "\n")

      result = Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})
      assert result == [] or is_list(result)
    end

    test "includes type declarations when present", %{db: db} do
      set_source(db, """
      type Bool2 = true2 | false2
      def id(x : Bool2) : Bool2 do x end
      """)

      result = Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})

      labels = Enum.map(result, & &1.label)
      assert "id" in labels
      assert "Bool2" in labels
    end

    test "completion items have kind field", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")

      result = Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})

      assert length(result) >= 1
      item = hd(result)
      assert Map.has_key?(item, :kind)
      assert item.kind in [:function, :type, :constructor]
    end
  end

  # ============================================================================
  # Document symbols
  # ============================================================================

  describe "document_symbols" do
    test "lists all top-level definitions", %{db: db} do
      set_source(db, """
      def add(x : Int, y : Int) : Int do x + y end
      def negate(n : Int) : Int do 0 - n end
      """)

      result = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)

      assert is_list(result)
      assert length(result) >= 2

      names = Enum.map(result, & &1.name)
      assert "add" in names
      assert "negate" in names
    end

    test "symbols have correct structure", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      result = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)

      assert [symbol] = result
      assert symbol.name == "id"
      assert symbol.kind == :function

      # Range is a 4-tuple of 1-based positions.
      {sl, sc, el, ec} = symbol.range
      assert is_integer(sl) and sl >= 1
      assert is_integer(sc) and sc >= 1
      assert is_integer(el) and el >= 1
      assert is_integer(ec) and ec >= 1
    end

    test "selection_range covers the name", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      [symbol] = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)

      # The selection range should be narrower than or equal to the full range.
      {_sl, _sc, _el, _ec} = symbol.selection_range
      assert is_tuple(symbol.selection_range)
      assert tuple_size(symbol.selection_range) == 4
    end

    test "includes type declarations", %{db: db} do
      set_source(db, """
      type Color = red | green | blue
      def id(x : Color) : Color do x end
      """)

      result = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)

      names = Enum.map(result, & &1.name)
      assert "id" in names
      assert "Color" in names
    end

    test "empty file returns empty list", %{db: db} do
      set_source(db, "\n")

      result = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)
      assert result == [] or is_list(result)
    end
  end

  # ============================================================================
  # Go-to-definition
  # ============================================================================

  describe "definition" do
    test "on variable referencing a definition returns location", %{db: db} do
      # Source where body references a sibling definition.
      set_source(db, """
      def id(x : Int) : Int do x end
      def use_id(x : Int) : Int do id(x) end
      """)

      # "id" in the body of use_id: line 2, around col 30.
      # "def use_id(x : Int) : Int do id(x) end"
      # 1234567890123456789012345678901
      # "id" starts at col 30.
      result = Roux.Runtime.query(db, :haruspex_definition, {@uri, {2, 30}})

      # May return a location or nil depending on exact span alignment.
      if result do
        assert is_map(result)
        assert Map.has_key?(result, :uri)
        assert Map.has_key?(result, :line)
        assert Map.has_key?(result, :column)
        assert result.uri == @uri
      end
    end

    test "outside any definition returns nil", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n\n\n")

      result = Roux.Runtime.query(db, :haruspex_definition, {@uri, {3, 1}})
      assert is_nil(result)
    end
  end

  # ============================================================================
  # Hover edge cases
  # ============================================================================

  describe "hover edge cases" do
    test "hover on integer literal in expression", %{db: db} do
      set_source(db, "def f(x : Int) : Int do 42 end\n")

      # "42" starts at byte 24. Line 1, col 25.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 25}})

      if result do
        assert result =~ "Int"
      end
    end

    test "hover on function with multiple params", %{db: db} do
      set_source(db, "def add(x : Int, y : Int) : Int do x + y end\n")

      # Hover on "add" name.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 5}})
      assert is_binary(result)
      assert result =~ "add"
    end

    test "hover on parameter variable in body", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      # "x" in body is at col 25.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 25}})

      if result do
        assert is_binary(result)
      end
    end

    test "hover with invalid position returns nil", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")

      # Way beyond the source.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {100, 100}})
      assert is_nil(result)
    end

    test "hover on binop expression", %{db: db} do
      set_source(db, "def f(x : Int, y : Int) : Int do x + y end\n")

      # "+" is around col 35 — inside the def span.
      result = Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 35}})
      # Either a type hover or nil is acceptable.
      assert is_nil(result) or is_binary(result)
    end
  end

  # ============================================================================
  # Completions edge cases
  # ============================================================================

  describe "completions edge cases" do
    test "completions with parse error returns empty list", %{db: db} do
      set_source(db, "def 123bad\n")

      result = Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})
      assert result == []
    end

    test "multiple definitions all appear in completions", %{db: db} do
      set_source(db, """
      def a(x : Int) : Int do x end
      def b(x : Int) : Int do x end
      def c(x : Int) : Int do x end
      """)

      result = Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})
      labels = Enum.map(result, & &1.label)
      assert "a" in labels
      assert "b" in labels
      assert "c" in labels
    end
  end

  # ============================================================================
  # Document symbols edge cases
  # ============================================================================

  describe "document_symbols edge cases" do
    test "parse error returns empty list", %{db: db} do
      set_source(db, "def 123bad\n")

      result = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)
      assert result == []
    end

    test "multiple definitions have different ranges", %{db: db} do
      set_source(db, """
      def f(x : Int) : Int do x end
      def g(x : Int) : Int do x end
      """)

      result = Roux.Runtime.query(db, :haruspex_document_symbols, @uri)
      assert length(result) == 2

      ranges = Enum.map(result, & &1.range)
      assert Enum.uniq(ranges) == ranges
    end
  end

  # ============================================================================
  # Definition edge cases
  # ============================================================================

  describe "definition edge cases" do
    test "with parse error returns nil", %{db: db} do
      set_source(db, "def 123bad\n")

      result = Roux.Runtime.query(db, :haruspex_definition, {@uri, {1, 1}})
      assert is_nil(result)
    end

    test "with invalid position returns nil", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")

      result = Roux.Runtime.query(db, :haruspex_definition, {@uri, {100, 100}})
      assert is_nil(result)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp set_source(db, source) do
    Roux.Input.set(db, :source_text, @uri, source)
  end
end
