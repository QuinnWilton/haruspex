defmodule Haruspex.PrettyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Pretty

  # ============================================================================
  # Builtin types
  # ============================================================================

  describe "builtin types" do
    test "Int" do
      assert Pretty.pretty({:vbuiltin, :Int}) == "Int"
    end

    test "Float" do
      assert Pretty.pretty({:vbuiltin, :Float}) == "Float"
    end

    test "String" do
      assert Pretty.pretty({:vbuiltin, :String}) == "String"
    end

    test "Atom" do
      assert Pretty.pretty({:vbuiltin, :Atom}) == "Atom"
    end
  end

  # ============================================================================
  # Literals
  # ============================================================================

  describe "literals" do
    test "integer" do
      assert Pretty.pretty({:vlit, 42}) == "42"
    end

    test "negative integer" do
      assert Pretty.pretty({:vlit, -7}) == "-7"
    end

    test "float" do
      assert Pretty.pretty({:vlit, 3.14}) == "3.14"
    end

    test "string" do
      assert Pretty.pretty({:vlit, "hello"}) == "\"hello\""
    end

    test "boolean true" do
      assert Pretty.pretty({:vlit, true}) == "true"
    end

    test "boolean false" do
      assert Pretty.pretty({:vlit, false}) == "false"
    end

    test "atom" do
      assert Pretty.pretty({:vlit, :foo}) == ":foo"
    end
  end

  # ============================================================================
  # Universe types
  # ============================================================================

  describe "universe types" do
    test "Type 0 prints as Type" do
      assert Pretty.pretty({:vtype, {:llit, 0}}) == "Type"
    end

    test "Type 1" do
      assert Pretty.pretty({:vtype, {:llit, 1}}) == "Type 1"
    end

    test "Type 2" do
      assert Pretty.pretty({:vtype, {:llit, 2}}) == "Type 2"
    end

    test "level variable" do
      assert Pretty.pretty({:vtype, {:lvar, 3}}) == "Type ?l3"
    end

    test "level succ" do
      assert Pretty.pretty({:vtype, {:lsucc, {:llit, 1}}}) == "Type (succ 1)"
    end

    test "level max" do
      assert Pretty.pretty({:vtype, {:lmax, {:llit, 1}, {:llit, 2}}}) == "Type (max 1 2)"
    end
  end

  # ============================================================================
  # Arrow types (non-dependent Pi)
  # ============================================================================

  describe "arrow types" do
    test "simple arrow Int -> Int" do
      # Codomain body is {:builtin, :Int} which doesn't reference {:var, 0}.
      val = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      assert Pretty.pretty(val) == "Int -> Int"
    end

    test "nested arrows are right-associative" do
      # Int -> Int -> Int
      # Construct: Int -> Int -> Int
      # As core: pi(:omega, Int, pi(:omega, Int, Int))
      # Neither codomain references var 0.
      outer =
        {:vpi, :omega, {:vbuiltin, :Int}, [], {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}}

      assert Pretty.pretty(outer) == "Int -> Int -> Int"
    end

    test "arrow in domain position gets parenthesized" do
      # (Int -> Int) -> Int
      inner_pi = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      outer = {:vpi, :omega, inner_pi, [], {:builtin, :Int}}
      assert Pretty.pretty(outer) == "(Int -> Int) -> Int"
    end
  end

  # ============================================================================
  # Dependent Pi
  # ============================================================================

  describe "dependent Pi" do
    test "codomain uses bound variable" do
      # (x : Type) -> x
      # Codomain is {:var, 0} which uses the bound variable.
      val = {:vpi, :omega, {:vtype, {:llit, 0}}, [], {:var, 0}}
      result = Pretty.pretty(val)
      assert result == "(x : Type) -> x"
    end

    test "dependent Pi with existing names" do
      # With name list [:a], level 1: the fresh var for the Pi binder gets level 1.
      val = {:vpi, :omega, {:vtype, {:llit, 0}}, [], {:var, 0}}
      result = Pretty.pretty(val, [:a], 1)
      assert result == "(y : Type) -> y"
    end
  end

  # ============================================================================
  # Implicit Pi
  # ============================================================================

  describe "implicit Pi" do
    test "implicit non-dependent" do
      val = {:vpi, :zero, {:vtype, {:llit, 0}}, [], {:builtin, :Int}}
      result = Pretty.pretty(val)
      assert result =~ ~r/\{.+ : Type\} -> Int/
    end

    test "implicit dependent" do
      val = {:vpi, :zero, {:vtype, {:llit, 0}}, [], {:var, 0}}
      result = Pretty.pretty(val)
      assert result == "{x : Type} -> x"
    end
  end

  # ============================================================================
  # Sigma types
  # ============================================================================

  describe "sigma types" do
    test "non-dependent product" do
      val = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Float}}
      assert Pretty.pretty(val) == "Int * Float"
    end

    test "dependent sigma" do
      # (x : Type, x)
      val = {:vsigma, {:vtype, {:llit, 0}}, [], {:var, 0}}
      result = Pretty.pretty(val)
      assert result == "(x : Type, x)"
    end
  end

  # ============================================================================
  # Pairs
  # ============================================================================

  describe "pairs" do
    test "simple pair" do
      assert Pretty.pretty({:vpair, {:vlit, 1}, {:vlit, 2}}) == "(1, 2)"
    end

    test "nested pair" do
      inner = {:vpair, {:vlit, 2}, {:vlit, 3}}
      assert Pretty.pretty({:vpair, {:vlit, 1}, inner}) == "(1, (2, 3))"
    end
  end

  # ============================================================================
  # Lambda
  # ============================================================================

  describe "lambda" do
    test "identity lambda" do
      # fn(x) do x end
      val = {:vlam, :omega, [], {:var, 0}}
      result = Pretty.pretty(val)
      assert result == "fn(x) do x end"
    end

    test "constant lambda" do
      # fn(x) do 42 end
      val = {:vlam, :omega, [], {:lit, 42}}
      result = Pretty.pretty(val)
      assert result == "fn(x) do 42 end"
    end

    test "nested lambda" do
      # fn(x) do fn(y) do x end end
      val = {:vlam, :omega, [], {:lam, :omega, {:var, 1}}}
      result = Pretty.pretty(val)
      assert result == "fn(x) do fn(y) do x end end"
    end
  end

  # ============================================================================
  # Variables with name recovery
  # ============================================================================

  describe "name recovery" do
    test "variable looks up name by level" do
      val = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 0}}
      assert Pretty.pretty(val, [:x], 1) == "x"
    end

    test "variable at level 1" do
      val = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 1}}
      assert Pretty.pretty(val, [:x, :y], 2) == "y"
    end

    test "fallback for unknown level" do
      val = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 5}}
      assert Pretty.pretty(val, [:x], 1) == "_v5"
    end
  end

  # ============================================================================
  # Shadowing
  # ============================================================================

  describe "shadowing" do
    test "same name at multiple levels gets primes" do
      # Two bindings both named :x.
      names = [:x, :x]
      val0 = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 0}}
      val1 = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 1}}

      assert Pretty.pretty(val0, names, 2) == "x"
      assert Pretty.pretty(val1, names, 2) == "x'"
    end

    test "triple shadowing" do
      names = [:x, :x, :x]
      val2 = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 2}}
      assert Pretty.pretty(val2, names, 3) == "x''"
    end
  end

  # ============================================================================
  # Neutral terms
  # ============================================================================

  describe "neutral terms" do
    test "meta" do
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, {:nmeta, 5}}) == "?5"
    end

    test "application" do
      ne = {:napp, {:nvar, 0}, {:vlit, 42}}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}, [:f], 1) == "f(42)"
    end

    test "first projection" do
      ne = {:nfst, {:nvar, 0}}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}, [:p], 1) == "p.1"
    end

    test "second projection" do
      ne = {:nsnd, {:nvar, 0}}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}, [:p], 1) == "p.2"
    end

    test "nested application" do
      ne = {:napp, {:napp, {:nvar, 0}, {:vlit, 1}}, {:vlit, 2}}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}, [:f], 1) == "f(1)(2)"
    end

    test "builtin neutral" do
      ne = {:nbuiltin, :add}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}) == "add"
    end
  end

  # ============================================================================
  # Extern
  # ============================================================================

  describe "extern" do
    test "module function" do
      assert Pretty.pretty({:vextern, Enum, :map, 2}) == "Enum.map/2"
    end
  end

  # ============================================================================
  # Core term pretty-printing
  # ============================================================================

  describe "pretty_term/2" do
    test "variable" do
      assert Pretty.pretty_term({:var, 0}, [:x]) == "x"
    end

    test "literal" do
      assert Pretty.pretty_term({:lit, 42}, []) == "42"
    end

    test "builtin" do
      assert Pretty.pretty_term({:builtin, :Int}, []) == "Int"
    end

    test "meta" do
      assert Pretty.pretty_term({:meta, 3}, []) == "?3"
    end

    test "application" do
      assert Pretty.pretty_term({:app, {:var, 0}, {:lit, 1}}, [:f]) == "f(1)"
    end

    test "lambda" do
      result = Pretty.pretty_term({:lam, :omega, {:var, 0}}, [])
      assert result == "fn(x) do x end"
    end

    test "non-dependent pi" do
      result = Pretty.pretty_term({:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}, [])
      assert result == "Int -> Int"
    end

    test "dependent pi" do
      result = Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:var, 0}}, [])
      assert result == "(x : Type) -> x"
    end

    test "pair" do
      assert Pretty.pretty_term({:pair, {:lit, 1}, {:lit, 2}}, []) == "(1, 2)"
    end

    test "fst" do
      assert Pretty.pretty_term({:fst, {:var, 0}}, [:p]) == "p.1"
    end

    test "snd" do
      assert Pretty.pretty_term({:snd, {:var, 0}}, [:p]) == "p.2"
    end

    test "let" do
      result = Pretty.pretty_term({:let, {:lit, 42}, {:var, 0}}, [])
      assert result == "let x = 42 in x"
    end

    test "type" do
      assert Pretty.pretty_term({:type, {:llit, 0}}, []) == "Type"
    end

    test "extern" do
      assert Pretty.pretty_term({:extern, Enum, :map, 2}, []) == "Enum.map/2"
    end

    test "spanned is transparent" do
      span = Pentiment.Span.Byte.new(0, 5)
      assert Pretty.pretty_term({:spanned, span, {:lit, 42}}, []) == "42"
    end

    test "non-dependent sigma" do
      result = Pretty.pretty_term({:sigma, {:builtin, :Int}, {:builtin, :Float}}, [])
      assert result == "Int * Float"
    end

    test "dependent sigma" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:var, 0}}, [])
      assert result == "(x : Type, x)"
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    # Generator for well-formed values (simple subset to avoid explosion).
    defp gen_value(depth) do
      if depth <= 0 do
        gen_leaf_value()
      else
        StreamData.one_of([
          gen_leaf_value(),
          gen_pair(depth - 1),
          gen_neutral(depth - 1)
        ])
      end
    end

    defp gen_leaf_value do
      StreamData.one_of([
        StreamData.map(StreamData.integer(), &{:vlit, &1}),
        StreamData.map(StreamData.float(), &{:vlit, &1}),
        StreamData.map(
          StreamData.string(:alphanumeric, min_length: 0, max_length: 10),
          &{:vlit, &1}
        ),
        StreamData.constant({:vlit, true}),
        StreamData.constant({:vlit, false}),
        StreamData.member_of([
          {:vbuiltin, :Int},
          {:vbuiltin, :Float},
          {:vbuiltin, :String},
          {:vbuiltin, :Atom}
        ]),
        StreamData.constant({:vtype, {:llit, 0}}),
        StreamData.constant({:vtype, {:llit, 1}})
      ])
    end

    defp gen_pair(depth) do
      StreamData.bind(gen_value(depth), fn a ->
        StreamData.map(gen_value(depth), fn b ->
          {:vpair, a, b}
        end)
      end)
    end

    defp gen_neutral(depth) do
      gen_neutral_inner(depth)
      |> StreamData.map(fn ne ->
        {:vneutral, {:vtype, {:llit, 0}}, ne}
      end)
    end

    defp gen_neutral_inner(depth) do
      base = [
        StreamData.map(StreamData.integer(0..10), &{:nvar, &1}),
        StreamData.map(StreamData.integer(0..20), &{:nmeta, &1}),
        StreamData.member_of([{:nbuiltin, :add}, {:nbuiltin, :Int}])
      ]

      if depth <= 0 do
        StreamData.one_of(base)
      else
        StreamData.one_of(
          base ++
            [
              StreamData.bind(gen_neutral_inner(depth - 1), fn ne ->
                StreamData.map(gen_value(depth - 1), fn arg ->
                  {:napp, ne, arg}
                end)
              end),
              StreamData.map(gen_neutral_inner(depth - 1), &{:nfst, &1}),
              StreamData.map(gen_neutral_inner(depth - 1), &{:nsnd, &1})
            ]
        )
      end
    end

    property "never crashes on well-formed values" do
      check all(val <- gen_value(2)) do
        result = Pretty.pretty(val, [:x, :y, :z], 3)
        assert is_binary(result)
      end
    end

    property "always produces non-empty output" do
      check all(val <- gen_value(2)) do
        result = Pretty.pretty(val, [:a, :b], 2)
        assert byte_size(result) > 0
      end
    end

    property "integer literals round-trip through pretty" do
      check all(n <- StreamData.integer()) do
        assert Pretty.pretty({:vlit, n}) == Integer.to_string(n)
      end
    end
  end
end
