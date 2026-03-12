defmodule Haruspex.EraseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Erase

  # ============================================================================
  # Zero lambda erasure
  # ============================================================================

  describe "zero lambda erasure" do
    test "zero lambda is unwrapped" do
      # fn({a : Type}, x : a) : a do x end
      # Lam(:zero, Lam(:omega, Var(0)))
      # Type: Pi(:zero, Type, Pi(:omega, Var(0), Var(1)))
      term = {:lam, :zero, {:lam, :omega, {:var, 0}}}
      type = {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 1}}}

      result = Erase.erase(term, type)

      # Should become: Lam(:omega, Var(0)) — the zero lambda is removed.
      assert result == {:lam, :omega, {:var, 0}}
    end

    test "multiple consecutive zero lambdas are all removed" do
      # fn({a : Type}, {b : Type}, x : a) : a do x end
      # Lam(:zero, Lam(:zero, Lam(:omega, Var(0))))
      # Type: Pi(:zero, Type, Pi(:zero, Type, Pi(:omega, Var(1), Var(2))))
      term = {:lam, :zero, {:lam, :zero, {:lam, :omega, {:var, 0}}}}

      type =
        {:pi, :zero, {:type, {:llit, 0}},
         {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 1}, {:var, 2}}}}

      result = Erase.erase(term, type)

      assert result == {:lam, :omega, {:var, 0}}
    end

    test "omega lambda is preserved" do
      # fn(x : Int) : Int do x end
      term = {:lam, :omega, {:var, 0}}
      type = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}

      result = Erase.erase(term, type)

      assert result == {:lam, :omega, {:var, 0}}
    end

    test "interleaved zero and omega lambdas" do
      # fn({a : Type}, x : a, {b : Type}, y : b) : a
      # After erasure: fn(x, y) — two params.
      term = {:lam, :zero, {:lam, :omega, {:lam, :zero, {:lam, :omega, {:var, 2}}}}}

      type =
        {:pi, :zero, {:type, {:llit, 0}},
         {:pi, :omega, {:var, 0},
          {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 3}}}}}

      result = Erase.erase(term, type)

      # Two omega lambdas remain. var 2 (the 'x' param, originally at index 1
      # from the inner scope) shifted down twice to var 0.
      assert result == {:lam, :omega, {:lam, :omega, {:var, 1}}}
    end
  end

  # ============================================================================
  # Application erasure
  # ============================================================================

  describe "application erasure" do
    test "zero application is skipped" do
      # id(Int, 42) where id : {a : Type} -> a -> a
      # App(App(Var(0), Int), 42)
      # Var(0) has type Pi(:zero, Type, Pi(:omega, Var(0), Var(1)))
      id_type = {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 1}}}
      term = {:app, {:app, {:var, 0}, {:builtin, :Int}}, {:lit, 42}}
      type = {:builtin, :Int}
      result = erase_with_ctx(term, type, [id_type])

      # The type argument is skipped, only the value argument remains.
      assert result == {:app, {:var, 0}, {:lit, 42}}
    end

    test "omega application is preserved" do
      # add(1, 2)
      term = {:app, {:app, {:builtin, :add}, {:lit, 1}}, {:lit, 2}}
      type = {:builtin, :Int}

      result = Erase.erase(term, type)

      assert result == {:app, {:app, {:builtin, :add}, {:lit, 1}}, {:lit, 2}}
    end
  end

  # ============================================================================
  # Type-level erasure
  # ============================================================================

  describe "type-level erasure" do
    test "Pi is erased" do
      term = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      type = {:type, {:llit, 0}}

      assert Erase.erase(term, type) == :erased
    end

    test "Sigma is erased" do
      term = {:sigma, {:builtin, :Int}, {:builtin, :Int}}
      type = {:type, {:llit, 0}}

      assert Erase.erase(term, type) == :erased
    end

    test "Type is erased" do
      term = {:type, {:llit, 0}}
      type = {:type, {:llit, 1}}

      assert Erase.erase(term, type) == :erased
    end
  end

  # ============================================================================
  # Span erasure
  # ============================================================================

  describe "span erasure" do
    test "spanned term is unwrapped" do
      span = Pentiment.Span.byte(0, 5)
      term = {:spanned, span, {:lit, 42}}
      type = {:builtin, :Int}

      result = Erase.erase(term, type)

      assert result == {:lit, 42}
    end

    test "nested spans are all stripped" do
      span1 = Pentiment.Span.byte(0, 10)
      span2 = Pentiment.Span.byte(2, 6)
      term = {:spanned, span1, {:spanned, span2, {:lit, 42}}}
      type = {:builtin, :Int}

      result = Erase.erase(term, type)

      assert result == {:lit, 42}
    end
  end

  # ============================================================================
  # Meta erasure
  # ============================================================================

  describe "meta erasure" do
    test "unsolved meta raises CompilerBug" do
      term = {:meta, 0}
      type = {:builtin, :Int}

      assert_raise Haruspex.CompilerBug, ~r/unsolved meta 0/, fn ->
        Erase.erase(term, type)
      end
    end

    test "unsolved inserted meta raises CompilerBug" do
      term = {:inserted_meta, 3, [true, false]}
      type = {:builtin, :Int}

      assert_raise Haruspex.CompilerBug, ~r/unsolved inserted meta 3/, fn ->
        Erase.erase(term, type)
      end
    end
  end

  # ============================================================================
  # Let erasure
  # ============================================================================

  describe "let erasure" do
    test "let with runtime binding is preserved" do
      # let x = 42 in x
      term = {:let, {:lit, 42}, {:var, 0}}
      type = {:builtin, :Int}

      result = Erase.erase(term, type)

      assert result == {:let, {:lit, 42}, {:var, 0}}
    end

    test "let with type-level binding is eliminated" do
      # let T = Int in body (where body doesn't reference T computationally)
      # After erasure, T = :erased, so the let is removed.
      term = {:let, {:builtin, :Int}, {:lit, 42}}
      type = {:builtin, :Int}

      result = Erase.erase(term, type)

      # The let is eliminated; body is shifted to remove the binding.
      assert result == {:lit, 42}
    end
  end

  # ============================================================================
  # Structural terms
  # ============================================================================

  describe "structural erasure" do
    test "literal passes through" do
      assert Erase.erase({:lit, 42}, {:builtin, :Int}) == {:lit, 42}
      assert Erase.erase({:lit, 3.14}, {:builtin, :Float}) == {:lit, 3.14}
      assert Erase.erase({:lit, "hello"}, {:builtin, :String}) == {:lit, "hello"}
    end

    test "builtin passes through" do
      assert Erase.erase({:builtin, :add}, builtin_fun_type(:add)) == {:builtin, :add}
    end

    test "extern passes through" do
      term = {:extern, :math, :sqrt, 1}
      type = {:pi, :omega, {:builtin, :Float}, {:builtin, :Float}}

      assert Erase.erase(term, type) == {:extern, :math, :sqrt, 1}
    end

    test "pair erases both components" do
      term = {:pair, {:lit, 1}, {:lit, 2}}
      type = {:sigma, {:builtin, :Int}, {:builtin, :Int}}

      result = Erase.erase(term, type)

      assert result == {:pair, {:lit, 1}, {:lit, 2}}
    end

    test "fst erases inner" do
      pair_type = {:sigma, {:builtin, :Int}, {:builtin, :Int}}
      term = {:fst, {:var, 0}}
      type = {:builtin, :Int}

      result = erase_with_ctx(term, type, [pair_type])

      assert result == {:fst, {:var, 0}}
    end

    test "snd erases inner" do
      pair_type = {:sigma, {:builtin, :Int}, {:builtin, :Int}}
      term = {:snd, {:var, 0}}
      type = {:builtin, :Int}

      result = erase_with_ctx(term, type, [pair_type])

      assert result == {:snd, {:var, 0}}
    end
  end

  # ============================================================================
  # Integration: polymorphic identity
  # ============================================================================

  describe "integration" do
    test "polymorphic identity erases to unary function" do
      # def id({a : Type}, x : a) : a do x end
      term = {:lam, :zero, {:lam, :omega, {:var, 0}}}
      type = {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 1}}}

      result = Erase.erase(term, type)

      # One omega lambda remains.
      assert result == {:lam, :omega, {:var, 0}}
    end

    test "polymorphic const erases to binary function" do
      # def const({a : Type}, {b : Type}, x : a, y : b) : a do x end
      term = {:lam, :zero, {:lam, :zero, {:lam, :omega, {:lam, :omega, {:var, 1}}}}}

      type =
        {:pi, :zero, {:type, {:llit, 0}},
         {:pi, :zero, {:type, {:llit, 0}},
          {:pi, :omega, {:var, 1}, {:pi, :omega, {:var, 1}, {:var, 3}}}}}

      result = Erase.erase(term, type)

      # Two omega lambdas remain. Var(1) in the body shifts to Var(1)
      # because it referred to x (omega param at depth 2 from innermost),
      # which after removing two zero binders is at depth 1 from innermost.
      assert result == {:lam, :omega, {:lam, :omega, {:var, 1}}}
    end

    test "applying polymorphic identity erases type argument" do
      # id(Int, 42) where id is a variable with the polymorphic type
      id_type = {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 1}}}

      # App(App(id, Int), 42)
      term = {:app, {:app, {:var, 0}, {:builtin, :Int}}, {:lit, 42}}
      type = {:builtin, :Int}

      result = erase_with_ctx(term, type, [id_type])

      # Type argument skipped: id(42)
      assert result == {:app, {:var, 0}, {:lit, 42}}
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "erased output contains no zero-multiplicity lambdas" do
      check all(term <- erased_friendly_term(), max_runs: 100, max_shrinking_steps: 0) do
        {t, ty} = term
        erased = Erase.erase(t, ty)
        refute has_zero_lam?(erased)
      end
    end

    property "erased output contains no type-level nodes" do
      check all(term <- erased_friendly_term(), max_runs: 100, max_shrinking_steps: 0) do
        {t, ty} = term
        erased = Erase.erase(t, ty)
        refute has_type_node?(erased)
      end
    end

    property "erased output contains no spans" do
      check all(term <- erased_friendly_term(), max_runs: 100, max_shrinking_steps: 0) do
        {t, ty} = term
        erased = Erase.erase(t, ty)
        refute has_span?(erased)
      end
    end

    property "erased output contains no metas" do
      check all(term <- erased_friendly_term(), max_runs: 100, max_shrinking_steps: 0) do
        {t, ty} = term
        erased = Erase.erase(t, ty)
        refute has_meta?(erased)
      end
    end
  end

  # ============================================================================
  # Generators
  # ============================================================================

  # Generates {term, type} pairs that are valid inputs to Erase.erase/2.
  defp erased_friendly_term do
    gen all(
          choice <-
            StreamData.one_of([
              literal_term(),
              builtin_app_term(),
              identity_term(),
              const_term(),
              spanned_term()
            ])
        ) do
      choice
    end
  end

  defp literal_term do
    gen all(v <- StreamData.integer()) do
      {{:lit, v}, {:builtin, :Int}}
    end
  end

  defp builtin_app_term do
    gen all(
          a <- StreamData.integer(),
          b <- StreamData.integer()
        ) do
      term = {:app, {:app, {:builtin, :add}, {:lit, a}}, {:lit, b}}
      {term, {:builtin, :Int}}
    end
  end

  defp identity_term do
    StreamData.constant(
      {{:lam, :zero, {:lam, :omega, {:var, 0}}},
       {:pi, :zero, {:type, {:llit, 0}}, {:pi, :omega, {:var, 0}, {:var, 1}}}}
    )
  end

  defp const_term do
    StreamData.constant(
      {{:lam, :zero, {:lam, :zero, {:lam, :omega, {:lam, :omega, {:var, 1}}}}},
       {:pi, :zero, {:type, {:llit, 0}},
        {:pi, :zero, {:type, {:llit, 0}},
         {:pi, :omega, {:var, 1}, {:pi, :omega, {:var, 1}, {:var, 3}}}}}}
    )
  end

  defp spanned_term do
    gen all(v <- StreamData.integer()) do
      span = Pentiment.Span.byte(0, 5)
      {{:spanned, span, {:lit, v}}, {:builtin, :Int}}
    end
  end

  # ============================================================================
  # Predicate helpers
  # ============================================================================

  defp has_zero_lam?({:lam, :zero, _}), do: true
  defp has_zero_lam?({:lam, _, body}), do: has_zero_lam?(body)
  defp has_zero_lam?({:app, f, a}), do: has_zero_lam?(f) or has_zero_lam?(a)
  defp has_zero_lam?({:let, d, b}), do: has_zero_lam?(d) or has_zero_lam?(b)
  defp has_zero_lam?({:pair, a, b}), do: has_zero_lam?(a) or has_zero_lam?(b)
  defp has_zero_lam?({:fst, e}), do: has_zero_lam?(e)
  defp has_zero_lam?({:snd, e}), do: has_zero_lam?(e)
  defp has_zero_lam?(_), do: false

  defp has_type_node?({:pi, _, _, _}), do: true
  defp has_type_node?({:sigma, _, _}), do: true
  defp has_type_node?({:type, _}), do: true
  defp has_type_node?({:lam, _, body}), do: has_type_node?(body)
  defp has_type_node?({:app, f, a}), do: has_type_node?(f) or has_type_node?(a)
  defp has_type_node?({:let, d, b}), do: has_type_node?(d) or has_type_node?(b)
  defp has_type_node?({:pair, a, b}), do: has_type_node?(a) or has_type_node?(b)
  defp has_type_node?({:fst, e}), do: has_type_node?(e)
  defp has_type_node?({:snd, e}), do: has_type_node?(e)
  defp has_type_node?(_), do: false

  defp has_span?({:spanned, _, _}), do: true
  defp has_span?({:lam, _, body}), do: has_span?(body)
  defp has_span?({:app, f, a}), do: has_span?(f) or has_span?(a)
  defp has_span?({:let, d, b}), do: has_span?(d) or has_span?(b)
  defp has_span?({:pair, a, b}), do: has_span?(a) or has_span?(b)
  defp has_span?({:fst, e}), do: has_span?(e)
  defp has_span?({:snd, e}), do: has_span?(e)
  defp has_span?(_), do: false

  defp has_meta?({:meta, _}), do: true
  defp has_meta?({:inserted_meta, _, _}), do: true
  defp has_meta?({:lam, _, body}), do: has_meta?(body)
  defp has_meta?({:app, f, a}), do: has_meta?(f) or has_meta?(a)
  defp has_meta?({:let, d, b}), do: has_meta?(d) or has_meta?(b)
  defp has_meta?({:pair, a, b}), do: has_meta?(a) or has_meta?(b)
  defp has_meta?({:fst, e}), do: has_meta?(e)
  defp has_meta?({:snd, e}), do: has_meta?(e)
  defp has_meta?(_), do: false

  # ============================================================================
  # Synth mode: literal types
  # ============================================================================

  describe "synth mode literals" do
    test "float literal synthesizes Float type via let" do
      # let x = 1.0 in x — synth on 1.0 gives Float
      term = {:let, {:lit, 1.0}, {:var, 0}}
      type = {:builtin, :Float}
      result = Erase.erase(term, type)
      assert {:let, {:lit, 1.0}, {:var, 0}} = result
    end

    test "string literal synthesizes String type via let" do
      term = {:let, {:lit, "hello"}, {:var, 0}}
      type = {:builtin, :String}
      result = Erase.erase(term, type)
      assert {:let, {:lit, "hello"}, {:var, 0}} = result
    end

    test "boolean true synthesizes Atom type via let" do
      term = {:let, {:lit, true}, {:var, 0}}
      type = {:builtin, :Atom}
      result = Erase.erase(term, type)
      assert {:let, {:lit, true}, {:var, 0}} = result
    end

    test "boolean false synthesizes Atom type via let" do
      term = {:let, {:lit, false}, {:var, 0}}
      type = {:builtin, :Atom}
      result = Erase.erase(term, type)
      assert {:let, {:lit, false}, {:var, 0}} = result
    end

    test "atom literal synthesizes Atom type via let" do
      term = {:let, {:lit, :foo}, {:var, 0}}
      type = {:builtin, :Atom}
      result = Erase.erase(term, type)
      assert {:let, {:lit, :foo}, {:var, 0}} = result
    end
  end

  # ============================================================================
  # Synth mode: let, pair, projections, spans, type-level
  # ============================================================================

  describe "synth mode compound terms" do
    test "let in synth mode preserves runtime binding" do
      # App(let x = 42 in add(x), 10) — app forces synth on inner let
      let_term = {:let, {:lit, 42}, {:app, {:builtin, :add}, {:var, 0}}}
      term = {:app, let_term, {:lit, 10}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert {:app, {:let, {:lit, 42}, {:app, {:builtin, :add}, {:var, 0}}}, {:lit, 10}} = result
    end

    test "let in synth mode eliminates type-level binding" do
      # App(let T = Int in add, 10) where T has type Type
      # The let body (add) has type Int -> Int -> Int.
      # When T : Type, synth should eliminate the let.
      let_term = {:let, {:type, {:llit, 0}}, {:app, {:builtin, :add}, {:lit, 5}}}
      term = {:app, let_term, {:lit, 10}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert {:app, {:app, {:builtin, :add}, {:lit, 5}}, {:lit, 10}} = result
    end

    test "pair in synth mode erases both components" do
      # fst({1, 2}) — fst forces synth on the pair
      term = {:fst, {:pair, {:lit, 1}, {:lit, 2}}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert {:fst, {:pair, {:lit, 1}, {:lit, 2}}} = result
    end

    test "snd projection via synth" do
      pair_type = {:sigma, {:builtin, :Int}, {:builtin, :Int}}
      term = {:snd, {:var, 0}}
      type = {:builtin, :Int}
      result = erase_with_ctx(term, type, [pair_type])
      assert {:snd, {:var, 0}} = result
    end

    test "spanned term in synth mode is stripped" do
      span = Pentiment.Span.byte(0, 5)
      # App(spanned(add), 10) — app synths the spanned builtin
      term = {:app, {:spanned, span, {:app, {:builtin, :add}, {:lit, 1}}}, {:lit, 2}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert {:app, {:app, {:builtin, :add}, {:lit, 1}}, {:lit, 2}} = result
    end

    test "pi in synth mode erases to :erased" do
      # App forces synth on Pi, which should return {:erased, {:type, ...}}
      # We can test directly through a let whose def is a Pi
      term = {:let, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}, {:lit, 42}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      # Pi has type Type, so it's type-level → let is eliminated
      assert result == {:lit, 42}
    end

    test "sigma in synth mode erases" do
      term = {:let, {:sigma, {:builtin, :Int}, {:builtin, :Int}}, {:lit, 42}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert result == {:lit, 42}
    end

    test "type in synth mode erases" do
      term = {:let, {:type, {:llit, 0}}, {:lit, 42}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert result == {:lit, 42}
    end

    test "meta in synth mode raises CompilerBug" do
      # Force synth on meta via app
      term = {:app, {:meta, 5}, {:lit, 42}}
      type = {:builtin, :Int}

      assert_raise Haruspex.CompilerBug, ~r/unsolved meta 5/, fn ->
        Erase.erase(term, type)
      end
    end

    test "inserted_meta in synth mode raises CompilerBug" do
      term = {:app, {:inserted_meta, 7, [true]}, {:lit, 42}}
      type = {:builtin, :Int}

      assert_raise Haruspex.CompilerBug, ~r/unsolved inserted meta 7/, fn ->
        Erase.erase(term, type)
      end
    end

    test "fst in synth mode extracts sigma first type" do
      # App(fst(pair_var), 10) — app forces synth on fst
      pair_type = {:sigma, {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}, {:builtin, :Int}}
      # fst(pair_var) has type (Int -> Int), so App(fst(pair_var), 10) applies it
      term = {:app, {:fst, {:var, 0}}, {:lit, 10}}
      type = {:builtin, :Int}
      result = erase_with_ctx(term, type, [pair_type])
      assert {:app, {:fst, {:var, 0}}, {:lit, 10}} = result
    end

    test "snd in synth mode extracts sigma second type" do
      # let x = snd(pair_var) in x — let synth on snd
      pair_type = {:sigma, {:builtin, :Int}, {:builtin, :Int}}
      term = {:let, {:snd, {:var, 0}}, {:var, 0}}
      type = {:builtin, :Int}
      result = erase_with_ctx(term, type, [pair_type])
      assert {:let, {:snd, {:var, 0}}, {:var, 0}} = result
    end

    test "extern in synth mode raises CompilerBug" do
      # Force synth via app on extern
      term = {:app, {:extern, :math, :sqrt, 1}, {:lit, 4.0}}
      type = {:builtin, :Float}

      assert_raise Haruspex.CompilerBug, ~r/cannot synthesize type of extern/, fn ->
        Erase.erase(term, type)
      end
    end
  end

  # ============================================================================
  # Builtin type coverage
  # ============================================================================

  describe "builtin type variants" do
    test "float arithmetic builtins erase correctly" do
      for op <- [:fadd, :fsub, :fmul, :fdiv] do
        term = {:app, {:app, {:builtin, op}, {:lit, 1.0}}, {:lit, 2.0}}
        type = {:builtin, :Float}
        result = Erase.erase(term, type)
        assert {:app, {:app, {:builtin, ^op}, {:lit, 1.0}}, {:lit, 2.0}} = result
      end
    end

    test "comparison builtins erase correctly" do
      for op <- [:eq, :neq, :lt, :gt, :lte, :gte] do
        term = {:app, {:app, {:builtin, op}, {:lit, 1}}, {:lit, 2}}
        type = {:builtin, :Atom}
        result = Erase.erase(term, type)
        assert {:app, {:app, {:builtin, ^op}, {:lit, 1}}, {:lit, 2}} = result
      end
    end

    test "boolean builtins erase correctly" do
      for op <- [:and, :or] do
        term = {:app, {:app, {:builtin, op}, {:lit, true}}, {:lit, false}}
        type = {:builtin, :Atom}
        result = Erase.erase(term, type)
        assert {:app, {:app, {:builtin, ^op}, {:lit, true}}, {:lit, false}} = result
      end
    end

    test "unary builtins erase correctly" do
      term = {:app, {:builtin, :neg}, {:lit, 5}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      assert {:app, {:builtin, :neg}, {:lit, 5}} = result

      term = {:app, {:builtin, :not}, {:lit, true}}
      type = {:builtin, :Atom}
      result = Erase.erase(term, type)
      assert {:app, {:builtin, :not}, {:lit, true}} = result
    end

    test "type builtins (Int, Float, String, Bool, Atom) erase to :erased in check mode" do
      for builtin <- [:Int, :Float, :String, :Bool, :Atom] do
        term = {:builtin, builtin}
        type = {:type, {:llit, 0}}
        result = Erase.erase(term, type)
        assert result == {:builtin, builtin}
      end
    end

    test "type builtins in synth mode are type-level, eliminating let" do
      # let T = Float in 42 — synth on {:builtin, :Float} gives {:type, ...}
      # Since type-level, the let is eliminated.
      for builtin <- [:Float, :String, :Bool, :Atom] do
        term = {:let, {:builtin, builtin}, {:lit, 42}}
        type = {:builtin, :Int}
        result = Erase.erase(term, type)
        assert result == {:lit, 42}
      end
    end

    test "unknown builtin type falls back to type" do
      # Let with unknown builtin: synth will use fallback type {:type, {:llit, 0}}
      term = {:let, {:builtin, :unknown_op}, {:lit, 42}}
      type = {:builtin, :Int}
      result = Erase.erase(term, type)
      # unknown_op has type {:type, {:llit, 0}} → type-level → let eliminated
      assert result == {:lit, 42}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp builtin_fun_type(:add) do
    int = {:builtin, :Int}
    {:pi, :omega, int, {:pi, :omega, int, int}}
  end

  defp erase_with_ctx(term, type, types) do
    Erase.erase(term, type, %Erase{types: types})
  end
end
