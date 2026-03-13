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
  # Ndef neutral
  # ============================================================================

  describe "ndef neutral" do
    test "ndef with no args" do
      ne = {:ndef, :foo, []}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}) == ":foo"
    end

    test "ndef with args" do
      ne = {:ndef, :foo, [{:vlit, 1}, {:vlit, 2}]}
      assert Pretty.pretty({:vneutral, {:vtype, {:llit, 0}}, ne}) == ":foo(1)(2)"
    end
  end

  # ============================================================================
  # Builtin with applied args
  # ============================================================================

  describe "builtin with args" do
    test "applied builtin" do
      val = {:vbuiltin, {:add, [{:vlit, 1}]}}
      assert Pretty.pretty(val) == "add(1)"
    end

    test "multi-applied builtin" do
      val = {:vbuiltin, {:add, [{:vlit, 1}, {:vlit, 2}]}}
      assert Pretty.pretty(val) == "add(1)(2)"
    end
  end

  # ============================================================================
  # Universe level variants
  # ============================================================================

  describe "universe level variants" do
    test "lvar level" do
      assert Pretty.pretty({:vtype, {:lvar, 5}}) == "Type ?l5"
    end

    test "lsucc level" do
      assert Pretty.pretty({:vtype, {:lsucc, {:llit, 0}}}) == "Type (succ 0)"
    end

    test "lmax level" do
      assert Pretty.pretty({:vtype, {:lmax, {:lvar, 0}, {:llit, 1}}}) == "Type (max ?l0 1)"
    end

    test "nested lsucc" do
      assert Pretty.pretty({:vtype, {:lsucc, {:lsucc, {:llit, 0}}}}) == "Type (succ (succ 0))"
    end

    test "nested lmax" do
      assert Pretty.pretty(
               {:vtype, {:lmax, {:lsucc, {:llit, 0}}, {:lmax, {:llit, 1}, {:llit, 2}}}}
             ) ==
               "Type (max (succ 0) (max 1 2))"
    end
  end

  # ============================================================================
  # Core term pretty-printing — additional cases
  # ============================================================================

  describe "pretty_term/2 — additional" do
    test "inserted_meta" do
      assert Pretty.pretty_term({:inserted_meta, 7, [true, false]}, []) == "?7"
    end

    test "data" do
      assert Pretty.pretty_term({:data, :Nat, []}, []) == "data Nat"
    end

    test "constructor with no args" do
      assert Pretty.pretty_term({:con, :Nat, :Zero, []}, []) == "Zero"
    end

    test "constructor with args" do
      assert Pretty.pretty_term({:con, :Nat, :Succ, [{:var, 0}]}, [:n]) == "Succ(n)"
    end

    test "case expression" do
      term = {:case, {:var, 0}, [{:Zero, 0, {:lit, 0}}, {:Succ, 1, {:var, 0}}]}
      assert Pretty.pretty_term(term, [:n]) == "case n { ... }"
    end

    test "implicit pi term (zero mult, non-dependent)" do
      result = Pretty.pretty_term({:pi, :zero, {:builtin, :Int}, {:builtin, :Int}}, [])
      assert result =~ ~r/\{.+ : Int\} -> Int/
    end

    test "implicit pi term (zero mult, dependent)" do
      result = Pretty.pretty_term({:pi, :zero, {:type, {:llit, 0}}, {:var, 0}}, [])
      assert result == "{x : Type} -> x"
    end

    test "variable not in names" do
      # depth = 0, ix = 0 => level = 0-0-1 = -1, no names => "_v-1"
      assert Pretty.pretty_term({:var, 0}, []) == "_v-1"
    end

    test "nested let" do
      term = {:let, {:lit, 1}, {:let, {:lit, 2}, {:var, 1}}}
      result = Pretty.pretty_term(term, [])
      assert result == "let x = 1 in let y = 2 in x"
    end

    test "fst and snd of term" do
      assert Pretty.pretty_term({:fst, {:var, 0}}, [:p]) == "p.1"
      assert Pretty.pretty_term({:snd, {:var, 0}}, [:p]) == "p.2"
    end
  end

  # ============================================================================
  # Value pretty-printing — additional coverage
  # ============================================================================

  describe "value pretty-printing — coverage" do
    test "variable with no name in disambig" do
      val = {:vneutral, {:vtype, {:llit, 0}}, {:nvar, 99}}
      assert Pretty.pretty(val) == "_v99"
    end

    test "extern value" do
      assert Pretty.pretty({:vextern, Kernel, :+, 2}) == "Kernel.+/2"
    end

    test "dependent pi with implicit (zero) multiplicity" do
      val = {:vpi, :zero, {:vtype, {:llit, 0}}, [], {:var, 0}}
      assert Pretty.pretty(val) == "{x : Type} -> x"
    end

    test "non-dependent pi with implicit (zero) multiplicity" do
      val = {:vpi, :zero, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      result = Pretty.pretty(val)
      assert result =~ ~r/\{.+ : Int\} -> Int/
    end

    test "dependent sigma" do
      val = {:vsigma, {:vtype, {:llit, 0}}, [], {:var, 0}}
      assert Pretty.pretty(val) == "(x : Type, x)"
    end

    test "non-dependent sigma" do
      val = {:vsigma, {:vbuiltin, :Int}, [], {:builtin, :Float}}
      assert Pretty.pretty(val) == "Int * Float"
    end

    test "lambda with names" do
      val = {:vlam, :omega, [], {:var, 0}}
      assert Pretty.pretty(val, [:a], 1) == "fn(y) do y end"
    end

    test "arrow in domain is parenthesized" do
      inner = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      outer = {:vpi, :omega, inner, [], {:builtin, :Int}}
      assert Pretty.pretty(outer) == "(Int -> Int) -> Int"
    end

    test "non-arrow in domain is not parenthesized" do
      outer = {:vpi, :omega, {:vbuiltin, :Int}, [], {:builtin, :Int}}
      assert Pretty.pretty(outer) == "Int -> Int"
    end

    test "pick_name cycles through names" do
      # Level 8 wraps around to :x (8 mod 8 = 0).
      val = {:vlam, :omega, [], {:var, 0}}
      result = Pretty.pretty(val, [:a, :b, :c, :d, :e, :f, :g, :h], 8)
      assert result == "fn(x) do x end"
    end
  end

  # ============================================================================
  # uses_var_zero? coverage via pretty_term (avoids eval issues with case/con/data)
  # ============================================================================

  describe "uses_var_zero? — dependent detection via pretty_term" do
    test "pi with lam body referencing var 0" do
      # {:lam, :omega, {:var, 1}} uses var 0 (shifted by 1 under lam).
      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:lam, :omega, {:var, 1}}}, [])

      assert result =~ "(x : Type)"
    end

    test "pi with app body referencing var 0" do
      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:app, {:var, 0}, {:lit, 1}}}, [])

      assert result =~ "(x : Type)"
    end

    test "pi with pair body referencing var 0" do
      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:pair, {:var, 0}, {:lit, 1}}}, [])

      assert result =~ "(x : Type)"
    end

    test "pi with fst body referencing var 0" do
      result = Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:fst, {:var, 0}}}, [])
      assert result =~ "(x : Type)"
    end

    test "pi with snd body referencing var 0" do
      result = Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:snd, {:var, 0}}}, [])
      assert result =~ "(x : Type)"
    end

    test "pi with let body referencing var 0" do
      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:let, {:var, 0}, {:lit, 1}}}, [])

      assert result =~ "(x : Type)"
    end

    test "pi with spanned body referencing var 0" do
      span = Pentiment.Span.Byte.new(0, 1)

      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:spanned, span, {:var, 0}}}, [])

      assert result =~ "(x : Type)"
    end

    test "pi with case body referencing var 0" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:case, {:var, 0}, [{:Z, 0, {:lit, 0}}]}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi with con body referencing var 0" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:con, :Nat, :Succ, [{:var, 0}]}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi with data body referencing var 0" do
      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:data, :Nat, [{:var, 0}]}}, [])

      assert result =~ "(x : Type)"
    end

    test "pi with var 1 in body is non-dependent" do
      result = Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:var, 1}}, [])
      # Non-dependent: arrow sugar.
      assert result =~ "->"
      refute result =~ "(x :"
    end

    test "sigma with lam body referencing var 0" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:lam, :omega, {:var, 1}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma with app referencing var 0" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:app, {:var, 0}, {:lit, 1}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma with pair referencing var 0" do
      result =
        Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:pair, {:var, 0}, {:lit, 1}}}, [])

      assert result =~ "(x : Type,"
    end

    test "sigma with fst referencing var 0" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:fst, {:var, 0}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma with snd referencing var 0" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:snd, {:var, 0}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma with let referencing var 0" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:let, {:var, 0}, {:lit, 1}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma with spanned referencing var 0" do
      span = Pentiment.Span.Byte.new(0, 1)
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:spanned, span, {:var, 0}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma with case referencing var 0" do
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:case, {:var, 0}, [{:Z, 0, {:lit, 0}}]}},
          []
        )

      assert result =~ "(x : Type,"
    end

    test "sigma with case not referencing var 0 (but branch body does under shift)" do
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:case, {:lit, 0}, [{:Succ, 1, {:var, 1}}]}},
          []
        )

      assert result =~ "(x : Type,"
    end
  end

  # ============================================================================
  # uses_var_zero_shifted? coverage
  # ============================================================================

  describe "uses_var_zero_shifted? coverage" do
    test "pi codomain with pi inside referencing var 0 at shifted position" do
      # Pi(omega, Type, Pi(omega, Type, var(1)))
      # var(1) at depth 2 is var 0 shifted by 1.
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:pi, :omega, {:type, {:llit, 0}}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "sigma codomain with sigma inside" do
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:sigma, {:type, {:llit, 0}}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type,"
    end

    test "sigma codomain with pair inside referencing shifted var" do
      result =
        Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:pair, {:var, 0}, {:lit, 1}}}, [])

      assert result =~ "(x : Type,"
    end

    test "sigma codomain with fst inside referencing shifted var" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:fst, {:var, 0}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma codomain with snd inside referencing shifted var" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:snd, {:var, 0}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma codomain with let inside referencing shifted var" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:let, {:var, 0}, {:lit, 1}}}, [])
      assert result =~ "(x : Type,"
    end

    test "sigma codomain with spanned inside referencing shifted var" do
      span = Pentiment.Span.Byte.new(0, 1)
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:spanned, span, {:var, 0}}}, [])
      assert result =~ "(x : Type,"
    end

    test "non-dependent pi with complex codomain not using var 0" do
      # Codomain: {:lam, :omega, {:lit, 42}} — doesn't reference var 0.
      result = Pretty.pretty_term({:pi, :omega, {:builtin, :Int}, {:lam, :omega, {:lit, 42}}}, [])
      assert result =~ "->"
    end

    # These tests exercise uses_var_zero_shifted? at deeper nesting levels.
    # The Pi codomain body contains a binder (lam/pi/sigma/let) whose inner body
    # references var 0 at a further shifted position.

    test "pi codomain with lam whose body refs var 0 at shift 2" do
      # Pi(omega, Type, lam(omega, var(2))) — var(2) at depth 2 is shifted var 0.
      # But uses_var_zero_shifted? is called with the Pi codomain body.
      # The codomain is {:lam, :omega, {:var, 2}}. uses_var_zero? sees lam, calls shifted(body, 1).
      # shifted({:var, 2}, 1) => 2 == 1? No. Not dependent.
      # For it to be dependent: codomain must ref var 0. Let's use:
      # {:lam, :omega, {:app, {:var, 1}, {:var, 0}}} — var(1) IS var 0 shifted.
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with app of shifted var" do
      # {:app, {:var, 0}, {:var, 0}} — var(0) IS var 0.
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:app, {:var, 0}, {:var, 0}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with pi whose codomain refs shifted var" do
      # {:pi, :omega, {:type, {:llit, 0}}, {:var, 1}} — var(1) at shift+1 is shifted var 0.
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:pi, :omega, {:type, {:llit, 0}}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with sigma whose b refs shifted var" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:sigma, {:type, {:llit, 0}}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with pair of shifted vars" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:pair, {:var, 0}, {:var, 0}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with fst of shifted var" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:fst, {:var, 0}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with snd of shifted var" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:snd, {:var, 0}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with let whose def refs shifted var" do
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:let, {:var, 0}, {:lit, 1}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "pi codomain with spanned shifted var" do
      span = Pentiment.Span.Byte.new(0, 1)

      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:spanned, span, {:var, 0}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    # Now test uses_var_zero_shifted? being called from within a Sigma codomain,
    # where the body itself has nested binders that shift further.

    test "sigma codomain with nested lam referencing shifted var" do
      # Sigma(Type, lam(omega, var(1))) — lam body uses var(1) which is shifted var(0).
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:lam, :omega, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type,"
    end

    test "sigma codomain with nested pi referencing shifted var" do
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:pi, :omega, {:type, {:llit, 0}}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type,"
    end

    test "sigma codomain with nested sigma referencing shifted var" do
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:sigma, {:type, {:llit, 0}}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type,"
    end

    test "sigma codomain with nested let referencing shifted var" do
      result =
        Pretty.pretty_term(
          {:sigma, {:type, {:llit, 0}}, {:let, {:var, 0}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type,"
    end
  end

  # ============================================================================
  # pretty_term for coverage of shifted uses
  # ============================================================================

  describe "pretty_term — shifted var coverage" do
    test "dependent pi with lam in codomain" do
      # Pi(omega, Type, lam(omega, var(1))) — var(1) at depth 2 IS var 0 shifted.
      result =
        Pretty.pretty_term({:pi, :omega, {:type, {:llit, 0}}, {:lam, :omega, {:var, 1}}}, [])

      assert result =~ "(x : Type)"
    end

    test "dependent sigma with app in body" do
      result = Pretty.pretty_term({:sigma, {:type, {:llit, 0}}, {:app, {:var, 0}, {:lit, 1}}}, [])
      assert result =~ "(x : Type,"
    end

    test "non-dependent sigma with no var 0 reference" do
      result = Pretty.pretty_term({:sigma, {:builtin, :Int}, {:lit, 42}}, [])
      assert result =~ "Int * "
    end
  end

  # ============================================================================
  # Coverage: pretty_term/2 entry point
  # ============================================================================

  describe "pretty_term/2 — entry point with defaults" do
    test "pretty_term with no names argument uses empty list" do
      result = Pretty.pretty_term({:lit, 42})
      assert result == "42"
    end

    test "pretty_term with a core term and explicit names" do
      result = Pretty.pretty_term({:var, 0}, [:x])
      assert result == "x"
    end
  end

  # ============================================================================
  # Coverage: do_pretty_term for :global
  # ============================================================================

  describe "pretty_term — global reference" do
    test "global term is pretty-printed as Mod.name/arity" do
      result = Pretty.pretty_term({:global, MyMod, :my_fun, 2}, [])
      assert result == "MyMod.my_fun/2"
    end

    test "global term with Elixir-style module" do
      result = Pretty.pretty_term({:global, Elixir.Foo.Bar, :baz, 1}, [])
      assert result == "Foo.Bar.baz/1"
    end
  end

  # ============================================================================
  # Coverage: do_pretty for :vglobal value
  # ============================================================================

  describe "value pretty — vglobal" do
    test "vglobal is pretty-printed as Mod.name/arity" do
      result = Pretty.pretty({:vglobal, MyMod, :my_fun, 2})
      assert result == "MyMod.my_fun/2"
    end
  end

  # ============================================================================
  # Coverage: uses_var_zero_shifted? for ann (not present) and deeper nesting
  # ============================================================================

  describe "uses_var_zero_shifted? — deeper coverage via pretty_term" do
    test "pi codomain with let whose body refs shifted var under binder" do
      # Pi(omega, Type, let(lit(1), var(1)))
      # let binds at depth 1, body var(1) at depth 2 is shifted var 0.
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:let, {:lit, 1}, {:var, 1}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "dependent pi where body uses var 0 deeply nested in app" do
      # Pi(omega, Type, app(app(var(0), var(0)), var(0)))
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:type, {:llit, 0}}, {:app, {:app, {:var, 0}, {:var, 0}}, {:var, 0}}},
          []
        )

      assert result =~ "(x : Type)"
    end

    test "non-dependent pi with ann-like structure not referencing var 0" do
      # Pi(omega, Int, fst(snd(lit(1))))
      result =
        Pretty.pretty_term(
          {:pi, :omega, {:builtin, :Int}, {:fst, {:snd, {:lit, 1}}}},
          []
        )

      # Non-dependent, should use arrow notation.
      assert result =~ "->"
      refute result =~ "(x :"
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
