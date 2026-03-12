defmodule Haruspex.ExternTest do
  use ExUnit.Case, async: true

  alias Haruspex.Codegen
  alias Haruspex.Erase
  alias Haruspex.Parser

  # ============================================================================
  # Parser
  # ============================================================================

  describe "parser" do
    test "parses @extern with Elixir module" do
      source = """
      @extern Enum.map/2
      def map(xs : Int, f : Int) : Int
      """

      {:ok, [{:def, _span, {:sig, _, :map, _, _params, _ret, attrs}, nil}]} = Parser.parse(source)

      assert attrs.extern == {Enum, :map, 2}
    end

    test "parses @extern with Erlang module" do
      source = """
      @extern :math.sqrt/1
      def sqrt(x : Float) : Float
      """

      {:ok, [{:def, _span, {:sig, _, :sqrt, _, _params, _ret, attrs}, nil}]} =
        Parser.parse(source)

      assert attrs.extern == {:math, :sqrt, 1}
    end

    test "extern def has nil body" do
      source = """
      @extern :math.sqrt/1
      def sqrt(x : Float) : Float
      """

      {:ok, [{:def, _, _, body}]} = Parser.parse(source)

      assert body == nil
    end
  end

  # ============================================================================
  # Elaboration
  # ============================================================================

  describe "elaboration" do
    test "extern elaborates to {:extern, mod, fun, arity} body" do
      {name, type, body} = elaborate_extern(":math.sqrt/1", "sqrt(x : Float) : Float")

      assert name == :sqrt
      assert body == {:extern, :math, :sqrt, 1}
      # Type should be Pi(:omega, Float, Float).
      assert {:pi, :omega, {:builtin, :Float}, {:builtin, :Float}} = type
    end

    test "extern with erased type params elaborates correctly" do
      {name, type, body} =
        elaborate_extern(
          "Enum.map/2",
          "map({a : Type}, {b : Type}, xs : Int, f : Int) : Int"
        )

      assert name == :map
      assert body == {:extern, Enum, :map, 2}
      # Type: Pi(:zero, Type, Pi(:zero, Type, Pi(:omega, Int, Pi(:omega, Int, Int))))
      assert {:pi, :zero, {:type, _},
              {:pi, :zero, {:type, _}, {:pi, :omega, _, {:pi, :omega, _, _}}}} = type
    end
  end

  # ============================================================================
  # Checker
  # ============================================================================

  describe "checker" do
    test "extern with matching arity passes" do
      {name, type, body} = elaborate_extern(":math.sqrt/1", "sqrt(x : Float) : Float")

      assert {:ok, ^body, _ctx} = check_extern(name, type, body)
    end

    test "extern with erased params and matching arity passes" do
      {name, type, body} =
        elaborate_extern(
          "Enum.map/2",
          "map({a : Type}, {b : Type}, xs : Int, f : Int) : Int"
        )

      assert {:ok, ^body, _ctx} = check_extern(name, type, body)
    end

    test "extern with arity mismatch fails" do
      # Declare arity 2 but type has 3 runtime params.
      {name, type, _body} =
        elaborate_extern(
          "Enum.map/2",
          "map({a : Type}, xs : Int, f : Int, g : Int) : Int"
        )

      body = {:extern, Enum, :map, 2}

      assert {:error, {:extern_arity_mismatch, :map, Enum, :map, 2, 3}} =
               check_extern(name, type, body)
    end
  end

  # ============================================================================
  # Codegen
  # ============================================================================

  describe "codegen" do
    test "extern compiles to capture" do
      term = {:extern, :math, :sqrt, 1}
      fun = Codegen.eval_expr(term)

      assert fun.(4.0) == 2.0
    end

    test "fully-applied extern compiles to direct call" do
      term = {:app, {:extern, :math, :sqrt, 1}, {:lit, 9.0}}

      assert Codegen.eval_expr(term) == 3.0
    end

    test "extern with erased params in module compilation" do
      body = {:extern, :math, :sqrt, 1}
      type = {:pi, :omega, {:builtin, :Float}, {:builtin, :Float}}

      # Erasure passes extern through unchanged.
      erased = Erase.erase(body, type)
      assert erased == {:extern, :math, :sqrt, 1}

      # Compile a module.
      ast = Codegen.compile_module(TestExternMod, :all, [{:sqrt, type, body}])
      Code.eval_quoted(ast)

      assert TestExternMod.sqrt(4.0) == 2.0
    after
      :code.purge(TestExternMod)
      :code.delete(TestExternMod)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp elaborate_extern(extern_ref, sig_text) do
    source = "@extern #{extern_ref}\ndef #{sig_text}\n"
    {:ok, [def_ast]} = Parser.parse(source)

    ctx = Haruspex.Elaborate.new()
    {:ok, result, _ctx} = Haruspex.Elaborate.elaborate_def(ctx, def_ast)
    result
  end

  defp check_extern(name, type, body) do
    ctx = Haruspex.Check.new()
    Haruspex.Check.check_definition(ctx, name, type, body)
  end
end
