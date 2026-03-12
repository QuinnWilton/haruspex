defmodule Haruspex.QueriesTest do
  use ExUnit.Case, async: false

  alias Haruspex.Definition

  @uri "test/math.hx"

  setup do
    db = Roux.Database.new()
    Roux.Lang.register(db, Haruspex)

    %{db: db}
  end

  # ============================================================================
  # Parse query
  # ============================================================================

  describe "haruspex_parse" do
    test "returns definition entity ids from source", %{db: db} do
      set_source(db, """
      def add(x : Int, y : Int) : Int do x + y end
      def negate(n : Int) : Int do 0 - n end
      """)

      {:ok, entity_ids} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      assert length(entity_ids) == 2

      names =
        Enum.map(entity_ids, fn id ->
          Roux.Runtime.field(db, Definition, id, :name)
        end)

      assert :add in names
      assert :negate in names
    end

    test "stores surface AST in entity", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      ast = Roux.Runtime.field(db, Definition, entity_id, :surface_ast)
      assert {:def, _, {:sig, _, :id, _, _, _, _}, _body} = ast
    end

    test "parse error returns error", %{db: db} do
      set_source(db, "def 123bad\n")

      result = Roux.Runtime.query(db, :haruspex_parse, @uri)
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Elaborate query
  # ============================================================================

  describe "haruspex_elaborate" do
    test "returns core terms for a definition", %{db: db} do
      set_source(db, "def add(x : Int, y : Int) : Int do x + y end\n")

      {:ok, {type_core, body_core}} =
        Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :add})

      assert {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}} =
               type_core

      assert {:lam, :omega, {:lam, :omega, _}} = body_core
    end

    test "propagates parse error", %{db: db} do
      set_source(db, "def 123bad\n")

      result = Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :add})
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Check query
  # ============================================================================

  describe "haruspex_check" do
    test "returns checked terms and type", %{db: db} do
      set_source(db, "def add(x : Int, y : Int) : Int do x + y end\n")

      {:ok, {type_core, checked_body}} =
        Roux.Runtime.query(db, :haruspex_check, {@uri, :add})

      assert {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}} =
               type_core

      assert {:lam, :omega, {:lam, :omega, _}} = checked_body
    end

    test "propagates elaborate error", %{db: db} do
      set_source(db, "def 123bad\n")

      result = Roux.Runtime.query(db, :haruspex_check, {@uri, :add})
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Codegen query
  # ============================================================================

  describe "haruspex_codegen" do
    test "returns Elixir AST", %{db: db} do
      set_source(db, "def add(x : Int, y : Int) : Int do x + y end\n")

      {:ok, ast} = Roux.Runtime.query(db, :haruspex_codegen, @uri)

      assert {:defmodule, _, _} = ast
    end
  end

  # ============================================================================
  # Compile query
  # ============================================================================

  describe "haruspex_compile" do
    test "full pipeline produces a callable module", %{db: db} do
      set_source(db, "def add(x : Int, y : Int) : Int do x + y end\n")

      {:ok, module} = Roux.Runtime.query(db, :haruspex_compile, @uri)

      assert module.add(3, 4) == 7
    after
      purge_test_module()
    end

    test "multi-definition file compiles all defs", %{db: db} do
      set_source(db, """
      def add(x : Int, y : Int) : Int do x + y end
      def negate(n : Int) : Int do 0 - n end
      """)

      {:ok, module} = Roux.Runtime.query(db, :haruspex_compile, @uri)

      assert module.add(1, 2) == 3
      assert module.negate(5) == -5
    after
      purge_test_module()
    end

    test "extern definition compiles through pipeline", %{db: db} do
      set_source(db, "@extern :math.sqrt/1\ndef sqrt(x : Float) : Float\n")

      {:ok, module} = Roux.Runtime.query(db, :haruspex_compile, @uri)

      assert module.sqrt(4.0) == 2.0
    after
      purge_test_module()
    end
  end

  # ============================================================================
  # Diagnostics query
  # ============================================================================

  describe "haruspex_diagnostics" do
    test "returns empty list for valid source", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)
      assert diagnostics == []
    end

    test "returns parse error diagnostics", %{db: db} do
      set_source(db, "def 123bad\n")

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)
      assert length(diagnostics) >= 1
      assert hd(diagnostics).severity == :error
    end

    test "collects errors from individual definitions", %{db: db} do
      # First def is valid, second has a missing return type.
      set_source(db, """
      def good(x : Int) : Int do x end
      def bad(x : Int) do x end
      """)

      diagnostics = Roux.Runtime.query(db, :haruspex_diagnostics, @uri)

      # The bad definition should produce a diagnostic.
      assert length(diagnostics) >= 1

      messages = Enum.map(diagnostics, & &1.message)
      assert Enum.any?(messages, &String.contains?(&1, "return type"))
    end
  end

  # ============================================================================
  # Stub queries
  # ============================================================================

  describe "stub queries" do
    test "totality returns not_implemented", %{db: db} do
      assert {:error, :not_implemented} =
               Roux.Runtime.query(db, :haruspex_totality, {@uri, :foo})
    end

    test "hover returns nil", %{db: db} do
      assert nil == Roux.Runtime.query(db, :haruspex_hover, {@uri, {1, 1}})
    end

    test "definition returns nil", %{db: db} do
      assert nil == Roux.Runtime.query(db, :haruspex_definition, {@uri, {1, 1}})
    end

    test "completions returns empty list", %{db: db} do
      assert [] == Roux.Runtime.query(db, :haruspex_completions, {@uri, {1, 1}})
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp set_source(db, source) do
    Roux.Input.set(db, :source_text, @uri, source)
  end

  defp purge_test_module do
    module = Module.concat(["Test", "Math"])
    :code.purge(module)
    :code.delete(module)
  end
end
