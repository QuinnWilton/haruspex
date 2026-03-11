defmodule Haruspex.ASTTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.AST

  @s %Pentiment.Span.Byte{start: 0, length: 1}
  @s2 %Pentiment.Span.Byte{start: 10, length: 5}
  @attrs %{total: false, private: false, extern: nil}

  # ============================================================================
  # span/1 — expressions
  # ============================================================================

  describe "span/1 expressions" do
    test "var" do
      assert AST.span({:var, @s, :x}) == @s
    end

    test "lit" do
      assert AST.span({:lit, @s, 42}) == @s
    end

    test "app" do
      assert AST.span({:app, @s, {:var, @s2, :f}, [{:lit, @s2, 1}]}) == @s
    end

    test "fn" do
      assert AST.span({:fn, @s, [], {:lit, @s2, 1}}) == @s
    end

    test "let" do
      assert AST.span({:let, @s, :x, {:lit, @s2, 1}, {:var, @s2, :x}}) == @s
    end

    test "case" do
      assert AST.span({:case, @s, {:var, @s2, :x}, []}) == @s
    end

    test "if" do
      assert AST.span({:if, @s, {:lit, @s2, true}, {:lit, @s2, 1}, {:lit, @s2, 2}}) == @s
    end

    test "binop" do
      assert AST.span({:binop, @s, :add, {:lit, @s2, 1}, {:lit, @s2, 2}}) == @s
    end

    test "unaryop" do
      assert AST.span({:unaryop, @s, :neg, {:lit, @s2, 1}}) == @s
    end

    test "pipe" do
      assert AST.span({:pipe, @s, {:var, @s2, :x}, {:var, @s2, :f}}) == @s
    end

    test "ann" do
      assert AST.span({:ann, @s, {:var, @s2, :x}, {:var, @s2, :Int}}) == @s
    end

    test "hole" do
      assert AST.span({:hole, @s}) == @s
    end

    test "dot" do
      assert AST.span({:dot, @s, {:var, @s2, :p}, :x}) == @s
    end

    test "record_construct" do
      assert AST.span({:record_construct, @s, :Point, [x: {:lit, @s2, 1.0}]}) == @s
    end

    test "record_update" do
      assert AST.span({:record_update, @s, {:var, @s2, :p}, [x: {:lit, @s2, 2.0}]}) == @s
    end
  end

  # ============================================================================
  # span/1 — type expressions
  # ============================================================================

  describe "span/1 type expressions" do
    test "pi" do
      binder = {:a, :omega, true}
      assert AST.span({:pi, @s, binder, {:var, @s2, :Type}, {:var, @s2, :Type}}) == @s
    end

    test "sigma" do
      assert AST.span({:sigma, @s, :x, {:var, @s2, :Int}, {:var, @s2, :Int}}) == @s
    end

    test "refinement" do
      assert AST.span({:refinement, @s, :x, {:var, @s2, :Int}, {:lit, @s2, true}}) == @s
    end

    test "type_universe" do
      assert AST.span({:type_universe, @s, 0}) == @s
    end

    test "type_universe with nil level" do
      assert AST.span({:type_universe, @s, nil}) == @s
    end
  end

  # ============================================================================
  # span/1 — patterns
  # ============================================================================

  describe "span/1 patterns" do
    test "pat_var" do
      assert AST.span({:pat_var, @s, :x}) == @s
    end

    test "pat_lit" do
      assert AST.span({:pat_lit, @s, 42}) == @s
    end

    test "pat_constructor" do
      assert AST.span({:pat_constructor, @s, :Some, [{:pat_var, @s2, :x}]}) == @s
    end

    test "pat_wildcard" do
      assert AST.span({:pat_wildcard, @s}) == @s
    end

    test "pat_record" do
      assert AST.span({:pat_record, @s, :Point, [x: {:pat_var, @s2, :x}]}) == @s
    end
  end

  # ============================================================================
  # span/1 — top-level declarations
  # ============================================================================

  describe "span/1 top-level declarations" do
    test "def with signature" do
      sig = {:sig, @s2, :id, @s2, [], nil, @attrs}
      assert AST.span({:def, @s, sig, {:var, @s2, :x}}) == @s
    end

    test "type_decl" do
      assert AST.span({:type_decl, @s, :Bool, [], []}) == @s
    end

    test "type_decl with kinded params" do
      params = [{:a, {:var, @s2, :Type}}, {:n, {:var, @s2, :Nat}}]
      assert AST.span({:type_decl, @s, :Vec, params, []}) == @s
    end

    test "import" do
      assert AST.span({:import, @s, [:Data, :Vec], true}) == @s
    end

    test "import with selective open" do
      assert AST.span({:import, @s, [:Data, :Vec], [:map, :filter]}) == @s
    end

    test "import qualified only" do
      assert AST.span({:import, @s, [:Data, :Vec], nil}) == @s
    end

    test "variable_decl" do
      param = {:param, @s2, {:a, :omega, true}, {:var, @s2, :Type}}
      assert AST.span({:variable_decl, @s, [param]}) == @s
    end

    test "mutual" do
      sig = {:sig, @s2, :even, @s2, [], nil, @attrs}
      d = {:def, @s2, sig, {:lit, @s2, true}}
      assert AST.span({:mutual, @s, [d]}) == @s
    end

    test "class_decl" do
      param = {:param, @s2, {:a, :omega, false}, {:var, @s2, :Type}}
      method = {:method_sig, @s2, :eq, {:var, @s2, :Int}}
      assert AST.span({:class_decl, @s, :Eq, [param], [], [method]}) == @s
    end

    test "instance_decl" do
      impl = {:method_impl, @s2, :eq, {:var, @s2, :int_eq}}
      assert AST.span({:instance_decl, @s, :Eq, [{:var, @s2, :Int}], [], [impl]}) == @s
    end

    test "record_decl" do
      field = {:field, @s2, :x, {:var, @s2, :Float}}
      assert AST.span({:record_decl, @s, :Point, [], [field]}) == @s
    end
  end

  # ============================================================================
  # span/1 — sub-nodes
  # ============================================================================

  describe "span/1 sub-nodes" do
    test "signature" do
      sig = {:sig, @s, :id, @s2, [], nil, @attrs}
      assert AST.span(sig) == @s
    end

    test "param" do
      assert AST.span({:param, @s, {:x, :omega, false}, {:var, @s2, :Int}}) == @s
    end

    test "branch" do
      assert AST.span({:branch, @s, {:pat_wildcard, @s2}, {:lit, @s2, 1}}) == @s
    end

    test "constructor without return type" do
      assert AST.span({:constructor, @s, :None, [], nil}) == @s
    end

    test "constructor with fields and return type" do
      field = {:field, @s2, :value, {:var, @s2, :a}}
      ret = {:app, @s2, {:var, @s2, :Option}, [{:var, @s2, :a}]}
      assert AST.span({:constructor, @s, :Some, [field], ret}) == @s
    end

    test "field" do
      assert AST.span({:field, @s, :x, {:var, @s2, :Float}}) == @s
    end

    test "constraint" do
      assert AST.span({:constraint, @s, :Eq, [{:var, @s2, :a}]}) == @s
    end

    test "method_sig" do
      assert AST.span({:method_sig, @s, :eq, {:var, @s2, :Int}}) == @s
    end

    test "method_impl" do
      assert AST.span({:method_impl, @s, :eq, {:lit, @s2, 42}}) == @s
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "span/1 property" do
    property "always returns the span from position 1 of any valid node" do
      check all(
              span <- span_gen(),
              node <- node_gen(span)
            ) do
        assert AST.span(node) == span
      end
    end
  end

  # ============================================================================
  # Generators
  # ============================================================================

  defp span_gen do
    gen all(
          start <- non_negative_integer(),
          length <- positive_integer()
        ) do
      %Pentiment.Span.Byte{start: start, length: length}
    end
  end

  defp node_gen(span) do
    inner_span = %Pentiment.Span.Byte{start: 99, length: 1}

    member_of([
      # Expressions
      {:var, span, :x},
      {:lit, span, 42},
      {:hole, span},
      {:app, span, {:var, inner_span, :f}, []},
      {:fn, span, [], {:lit, inner_span, 1}},
      {:let, span, :x, {:lit, inner_span, 1}, {:var, inner_span, :x}},
      {:case, span, {:var, inner_span, :x}, []},
      {:if, span, {:lit, inner_span, true}, {:lit, inner_span, 1}, {:lit, inner_span, 2}},
      {:binop, span, :add, {:lit, inner_span, 1}, {:lit, inner_span, 2}},
      {:unaryop, span, :neg, {:lit, inner_span, 1}},
      {:pipe, span, {:var, inner_span, :x}, {:var, inner_span, :f}},
      {:ann, span, {:var, inner_span, :x}, {:var, inner_span, :Int}},
      {:dot, span, {:var, inner_span, :p}, :x},
      {:record_construct, span, :Point, []},
      {:record_update, span, {:var, inner_span, :p}, []},
      # Type expressions
      {:pi, span, {:a, :omega, true}, {:var, inner_span, :Type}, {:var, inner_span, :Type}},
      {:sigma, span, :x, {:var, inner_span, :Int}, {:var, inner_span, :Int}},
      {:refinement, span, :x, {:var, inner_span, :Int}, {:lit, inner_span, true}},
      {:type_universe, span, 0},
      {:type_universe, span, nil},
      # Patterns
      {:pat_var, span, :x},
      {:pat_lit, span, 42},
      {:pat_constructor, span, :Some, []},
      {:pat_wildcard, span},
      {:pat_record, span, :Point, []},
      # Top-level
      {:def, span,
       {:sig, inner_span, :f, inner_span, [], nil, %{total: false, private: false, extern: nil}},
       {:lit, inner_span, 1}},
      {:type_decl, span, :Bool, [], []},
      {:import, span, [:Data], true},
      {:variable_decl, span, []},
      {:mutual, span, []},
      {:class_decl, span, :Eq, [], [], []},
      {:instance_decl, span, :Eq, [], [], []},
      {:record_decl, span, :Point, [], []},
      # Sub-nodes
      {:sig, span, :f, inner_span, [], nil, %{total: false, private: false, extern: nil}},
      {:param, span, {:x, :omega, false}, {:var, inner_span, :Int}},
      {:branch, span, {:pat_wildcard, inner_span}, {:lit, inner_span, 1}},
      {:constructor, span, :None, [], nil},
      {:field, span, :x, {:var, inner_span, :Float}},
      {:constraint, span, :Eq, []},
      {:method_sig, span, :eq, {:var, inner_span, :Int}},
      {:method_impl, span, :eq, {:lit, inner_span, 42}}
    ])
  end
end
