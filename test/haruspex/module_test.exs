defmodule Haruspex.ModuleTest do
  use ExUnit.Case, async: false

  alias Haruspex.Definition

  # ============================================================================
  # Helpers
  # ============================================================================

  defp new_db do
    db = Roux.Database.new()
    Roux.Lang.register(db, Haruspex)
    db
  end

  defp set_source(db, uri, source) do
    Roux.Input.set(db, :source_text, uri, source)
  end

  defp purge_module(module_name) do
    :code.purge(module_name)
    :code.delete(module_name)
  end

  # ============================================================================
  # Import resolution — unqualified (open: true)
  # ============================================================================

  describe "cross-module unqualified access" do
    test "imported name resolves via open: true" do
      db = new_db()

      # Module A: defines add.
      set_source(db, "lib/math_a.hx", """
      def add(x : Int, y : Int) : Int do x + y end
      """)

      # Module B: imports A with open: true, uses add.
      set_source(db, "lib/math_b.hx", """
      import MathA, open: true
      def double(x : Int) : Int do add(x, x) end
      """)

      # Compile both modules.
      {:ok, _mod_a} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_a.hx")
      {:ok, mod_b} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_b.hx")

      assert mod_b.double(5) == 10
    after
      purge_module(MathA)
      purge_module(MathB)
    end

    test "imported name resolves via open: [name]" do
      db = new_db()

      set_source(db, "lib/math_a.hx", """
      def add(x : Int, y : Int) : Int do x + y end
      def sub(x : Int, y : Int) : Int do x - y end
      """)

      set_source(db, "lib/math_b.hx", """
      import MathA, open: [add]
      def double(x : Int) : Int do add(x, x) end
      """)

      {:ok, _mod_a} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_a.hx")
      {:ok, mod_b} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_b.hx")

      assert mod_b.double(3) == 6
    after
      purge_module(MathA)
      purge_module(MathB)
    end

    test "non-open import does not expose unqualified names" do
      db = new_db()

      set_source(db, "lib/math_a.hx", "def inc(x : Int) : Int do x + 1 end\n")

      set_source(db, "lib/math_b.hx", """
      import MathA
      def double_inc(x : Int) : Int do inc(x) end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_a.hx")
      result = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/math_b.hx", :double_inc})

      assert {:error, {:unbound_variable, :inc, _}} = result
    after
      purge_module(MathA)
    end
  end

  # ============================================================================
  # Import resolution — qualified (Module.name)
  # ============================================================================

  describe "cross-module qualified access" do
    test "qualified name resolves after import" do
      db = new_db()

      set_source(db, "lib/math_a.hx", """
      def add(x : Int, y : Int) : Int do x + y end
      """)

      set_source(db, "lib/math_b.hx", """
      import MathA
      def double(x : Int) : Int do MathA.add(x, x) end
      """)

      {:ok, _mod_a} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_a.hx")
      {:ok, mod_b} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_b.hx")

      assert mod_b.double(7) == 14
    after
      purge_module(MathA)
      purge_module(MathB)
    end
  end

  # ============================================================================
  # Visibility (@private)
  # ============================================================================

  describe "visibility" do
    test "private definitions are not accessible from other modules" do
      db = new_db()

      set_source(db, "lib/math_a.hx", """
      @private
      def secret(x : Int) : Int do x end
      """)

      set_source(db, "lib/math_b.hx", """
      import MathA, open: true
      def use_secret(x : Int) : Int do secret(x) end
      """)

      # Parse A so its entities exist.
      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/math_a.hx")
      result = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/math_b.hx", :use_secret})

      assert {:error, {:unbound_variable, :secret, _}} = result
    end

    test "public definitions are accessible" do
      db = new_db()

      set_source(db, "lib/math_a.hx", """
      def public_fn(x : Int) : Int do x end
      @private
      def private_fn(x : Int) : Int do x end
      """)

      set_source(db, "lib/math_b.hx", """
      import MathA, open: true
      def use_public(x : Int) : Int do public_fn(x) end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_a.hx")
      {:ok, mod_b} = Roux.Runtime.query(db, :haruspex_compile, "lib/math_b.hx")

      assert mod_b.use_public(42) == 42
    after
      purge_module(MathA)
      purge_module(MathB)
    end
  end

  # ============================================================================
  # Entity type population for cross-module resolution
  # ============================================================================

  describe "cross-module type resolution" do
    test "imported function type is available for elaboration" do
      db = new_db()

      set_source(db, "lib/math_a.hx", """
      def add(x : Int, y : Int) : Int do x + y end
      """)

      # Elaborate A first to populate type fields.
      {:ok, _} = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/math_a.hx", :add})

      # Check that the entity has a type.
      {:ok, [entity_id]} = Roux.Runtime.query(db, :haruspex_parse, "lib/math_a.hx")
      type = Roux.Runtime.field(db, Definition, entity_id, :type)

      assert {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}} =
               type
    end
  end

  # ============================================================================
  # Multi-module compilation
  # ============================================================================

  describe "multi-module compilation" do
    test "three-module chain compiles correctly" do
      db = new_db()

      set_source(db, "lib/arith.hx", """
      def inc(x : Int) : Int do x + 1 end
      """)

      set_source(db, "lib/middle.hx", """
      import Arith, open: true
      def inc2(x : Int) : Int do inc(inc(x)) end
      """)

      set_source(db, "lib/top.hx", """
      import Middle, open: true
      def inc4(x : Int) : Int do inc2(inc2(x)) end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_compile, "lib/arith.hx")
      {:ok, _} = Roux.Runtime.query(db, :haruspex_compile, "lib/middle.hx")
      {:ok, mod} = Roux.Runtime.query(db, :haruspex_compile, "lib/top.hx")

      assert mod.inc4(0) == 4
    after
      purge_module(Arith)
      purge_module(Middle)
      purge_module(Top)
    end
  end

  # ============================================================================
  # Diagnostics
  # ============================================================================

  describe "cross-module diagnostics" do
    test "unknown module in qualified access produces error" do
      db = new_db()

      set_source(db, "lib/orphan.hx", """
      import Unknown
      def f(x : Int) : Int do Unknown.add(x, x) end
      """)

      result = Roux.Runtime.query(db, :haruspex_elaborate, {"lib/orphan.hx", :f})
      assert {:error, _} = result
    end
  end
end
