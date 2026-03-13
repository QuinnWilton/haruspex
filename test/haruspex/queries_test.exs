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
  # File imports query
  # ============================================================================

  describe "haruspex_file_imports" do
    test "returns empty list when no imports", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")

      imports = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert imports == []
    end

    test "returns import with qualified-only access", %{db: db} do
      set_source(db, "import Math\ndef f(x : Int) : Int do x end\n")

      imports = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert [%{module_path: [:Math], open: nil}] = imports
    end

    test "returns import with open: true", %{db: db} do
      set_source(db, "import Math, open: true\ndef f(x : Int) : Int do x end\n")

      imports = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert [%{module_path: [:Math], open: true}] = imports
    end

    test "returns import with selective open", %{db: db} do
      set_source(db, "import Math, open: [add, sub]\ndef f(x : Int) : Int do x end\n")

      imports = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert [%{module_path: [:Math], open: [:add, :sub]}] = imports
    end

    test "returns multiple imports", %{db: db} do
      set_source(db, """
      import Math
      import Data.Vec, open: true
      def f(x : Int) : Int do x end
      """)

      imports = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert length(imports) == 2

      paths = Enum.map(imports, & &1.module_path)
      assert [:Math] in paths
      assert [:Data, :Vec] in paths
    end

    test "imports coexist with definitions", %{db: db} do
      set_source(db, """
      import Math, open: [add]
      def f(x : Int) : Int do x end
      def g(x : Int) : Int do x end
      """)

      {:ok, entity_ids} = Roux.Runtime.query(db, :haruspex_parse, @uri)
      assert length(entity_ids) == 2

      imports = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert [%{module_path: [:Math], open: [:add]}] = imports
    end

    test "updates when source changes", %{db: db} do
      set_source(db, "import Math\ndef f(x : Int) : Int do x end\n")
      imports1 = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert length(imports1) == 1

      set_source(db, "import Math\nimport Data.Vec\ndef f(x : Int) : Int do x end\n")
      imports2 = Roux.Runtime.query(db, :haruspex_file_imports, @uri)
      assert length(imports2) == 2
    end
  end

  # ============================================================================
  # Prelude and @no_prelude
  # ============================================================================

  describe "prelude" do
    test "builtin types are available by default", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")

      {:ok, {type_core, _body_core}} =
        Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :f})

      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = type_core
    end

    test "builtin operations are available by default", %{db: db} do
      set_source(db, "def f(x : Int, y : Int) : Int do x + y end\n")

      {:ok, {_type_core, _body_core}} =
        Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :f})
    end

    test "@no_prelude disables builtin names", %{db: db} do
      set_source(db, "@no_prelude\ndef f(x : Int) : Int do x end\n")

      result = Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :f})
      assert {:error, {:unbound_variable, :Int, _}} = result
    end

    test "@no_prelude is stored in FileInfo", %{db: db} do
      set_source(db, "@no_prelude\ndef f(x : Int) : Int do x end\n")
      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      {:ok, file_info_id} = Roux.Runtime.lookup(db, Haruspex.FileInfo, {@uri})
      assert Roux.Runtime.field(db, Haruspex.FileInfo, file_info_id, :no_prelude?) == true
    end

    test "no_prelude? defaults to false", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      {:ok, file_info_id} = Roux.Runtime.lookup(db, Haruspex.FileInfo, {@uri})
      assert Roux.Runtime.field(db, Haruspex.FileInfo, file_info_id, :no_prelude?) == false
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

    test "writes type and body back to entity", %{db: db} do
      set_source(db, "def id(x : Int) : Int do x end\n")

      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      # Before elaborate, type and body are nil.
      assert Roux.Runtime.field(db, Definition, entity_id, :type) == nil
      assert Roux.Runtime.field(db, Definition, entity_id, :body) == nil

      {:ok, {type_core, body_core}} =
        Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :id})

      # After elaborate, entity fields are populated.
      assert Roux.Runtime.field(db, Definition, entity_id, :type) == type_core
      assert Roux.Runtime.field(db, Definition, entity_id, :body) == body_core
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
  # Entity tests
  # ============================================================================

  describe "entity" do
    test "definition entity has correct identity", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      assert Roux.Runtime.field(db, Definition, entity_id, :uri) == @uri
      assert Roux.Runtime.field(db, Definition, entity_id, :name) == :f
    end

    test "erased_params initialized to nil", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      assert Roux.Runtime.field(db, Definition, entity_id, :erased_params) == nil
    end

    test "private? defaults to false", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      assert Roux.Runtime.field(db, Definition, entity_id, :private?) == false
    end

    test "private? set to true for @private definitions", %{db: db} do
      set_source(db, "@private\ndef f(x : Int) : Int do x end\n")
      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      assert Roux.Runtime.field(db, Definition, entity_id, :private?) == true
    end

    test "mixed public and private definitions", %{db: db} do
      set_source(db, """
      def public_fn(x : Int) : Int do x end
      @private
      def private_fn(x : Int) : Int do x end
      """)

      {:ok, entity_ids} = Roux.Runtime.query(db, :haruspex_parse, @uri)

      privacies =
        Enum.map(entity_ids, fn id ->
          {Roux.Runtime.field(db, Definition, id, :name),
           Roux.Runtime.field(db, Definition, id, :private?)}
        end)

      assert {:public_fn, false} in privacies
      assert {:private_fn, true} in privacies
    end
  end

  # ============================================================================
  # Module name derivation
  # ============================================================================

  describe "module_name_from_uri" do
    test "converts path segments to module name" do
      assert Haruspex.module_name_from_uri("test/math.hx") == Test.Math
    end

    test "handles nested paths" do
      assert Haruspex.module_name_from_uri("lib/data/vec.hx") == Lib.Data.Vec
    end

    test "strips source root prefix" do
      assert Haruspex.module_name_from_uri("lib/math.hx", ["lib"]) == Math
    end

    test "strips nested source root" do
      assert Haruspex.module_name_from_uri("lib/data/vec.hx", ["lib"]) == Data.Vec
    end

    test "tries multiple source roots" do
      assert Haruspex.module_name_from_uri("test/math.hx", ["lib", "test"]) == Math
    end

    test "falls through when no root matches" do
      assert Haruspex.module_name_from_uri("src/math.hx", ["lib"]) == Src.Math
    end

    test "handles trailing slash in root" do
      assert Haruspex.module_name_from_uri("lib/math.hx", ["lib/"]) == Math
    end

    test "deeply nested path with root" do
      assert Haruspex.module_name_from_uri("lib/data/vec/sort.hx", ["lib"]) == Data.Vec.Sort
    end
  end

  # ============================================================================
  # Incremental tests
  # ============================================================================

  describe "incremental behavior" do
    test "modifying source body produces correct results", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x + 1 end\n")
      {:ok, module1} = Roux.Runtime.query(db, :haruspex_compile, @uri)
      assert module1.f(10) == 11

      # Change body: x + 1 → x + 2.
      set_source(db, "def f(x : Int) : Int do x + 2 end\n")
      {:ok, module2} = Roux.Runtime.query(db, :haruspex_compile, @uri)
      assert module2.f(10) == 12
    after
      purge_test_module()
    end

    test "adding a definition produces updated parse results", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, ids1} = Roux.Runtime.query(db, :haruspex_parse, @uri)
      assert length(ids1) == 1

      set_source(db, "def f(x : Int) : Int do x end\ndef g(x : Int) : Int do x + 1 end\n")
      {:ok, ids2} = Roux.Runtime.query(db, :haruspex_parse, @uri)
      assert length(ids2) == 2

      names = Enum.map(ids2, &Roux.Runtime.field(db, Definition, &1, :name))
      assert :f in names
      assert :g in names
    end

    test "removing a definition produces updated parse results", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\ndef g(x : Int) : Int do x + 1 end\n")
      {:ok, ids1} = Roux.Runtime.query(db, :haruspex_parse, @uri)
      assert length(ids1) == 2

      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, ids2} = Roux.Runtime.query(db, :haruspex_parse, @uri)
      assert length(ids2) == 1

      assert Roux.Runtime.field(db, Definition, hd(ids2), :name) == :f
    end

    test "modifying type produces different elaborate results", %{db: db} do
      set_source(db, "def f(x : Int) : Int do x end\n")
      {:ok, {type1, _}} = Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :f})
      assert {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}} = type1

      # Change param type from Int to Float (body will fail check but elaborate succeeds).
      set_source(db, "def f(x : Float) : Float do x end\n")
      {:ok, {type2, _}} = Roux.Runtime.query(db, :haruspex_elaborate, {@uri, :f})
      assert {:pi, :omega, {:builtin, :Float}, {:builtin, :Float}} = type2
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
