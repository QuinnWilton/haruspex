defmodule Haruspex.CoreTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Core

  # ============================================================================
  # Constructors
  # ============================================================================

  describe "constructors" do
    test "var" do
      assert Core.var(0) == {:var, 0}
      assert Core.var(3) == {:var, 3}
    end

    test "lam" do
      assert Core.lam(:omega, {:var, 0}) == {:lam, :omega, {:var, 0}}
      assert Core.lam(:zero, {:var, 0}) == {:lam, :zero, {:var, 0}}
    end

    test "app" do
      assert Core.app({:var, 1}, {:var, 0}) == {:app, {:var, 1}, {:var, 0}}
    end

    test "pi" do
      assert Core.pi(:omega, {:builtin, :Int}, {:var, 0}) ==
               {:pi, :omega, {:builtin, :Int}, {:var, 0}}
    end

    test "sigma" do
      assert Core.sigma({:builtin, :Int}, {:var, 0}) == {:sigma, {:builtin, :Int}, {:var, 0}}
    end

    test "pair" do
      assert Core.pair({:lit, 1}, {:lit, 2}) == {:pair, {:lit, 1}, {:lit, 2}}
    end

    test "fst and snd" do
      assert Core.fst({:var, 0}) == {:fst, {:var, 0}}
      assert Core.snd({:var, 0}) == {:snd, {:var, 0}}
    end

    test "let_" do
      assert Core.let_({:lit, 42}, {:var, 0}) == {:let, {:lit, 42}, {:var, 0}}
    end

    test "type" do
      assert Core.type({:llit, 0}) == {:type, {:llit, 0}}
      assert Core.type({:lsucc, {:llit, 0}}) == {:type, {:lsucc, {:llit, 0}}}
    end

    test "lit" do
      assert Core.lit(42) == {:lit, 42}
      assert Core.lit("hello") == {:lit, "hello"}
      assert Core.lit(3.14) == {:lit, 3.14}
      assert Core.lit(:foo) == {:lit, :foo}
    end

    test "builtin" do
      assert Core.builtin(:Int) == {:builtin, :Int}
      assert Core.builtin(:add) == {:builtin, :add}
    end

    test "extern" do
      assert Core.extern(Enum, :map, 2) == {:extern, Enum, :map, 2}
    end

    test "meta" do
      assert Core.meta(0) == {:meta, 0}
    end

    test "inserted_meta" do
      assert Core.inserted_meta(0, [true, false, true]) ==
               {:inserted_meta, 0, [true, false, true]}
    end

    test "spanned" do
      span = Pentiment.Span.Byte.new(0, 5)
      assert Core.spanned(span, {:var, 0}) == {:spanned, span, {:var, 0}}
    end
  end

  # ============================================================================
  # Substitution
  # ============================================================================

  describe "subst/3" do
    test "substitutes at target index" do
      # subst(Var(0), 0, Lit(42)) = Lit(42)
      assert Core.subst({:var, 0}, 0, {:lit, 42}) == {:lit, 42}
    end

    test "decrements indices above target" do
      # subst(Var(2), 1, Lit(42)) = Var(1)
      assert Core.subst({:var, 2}, 1, {:lit, 42}) == {:var, 1}
    end

    test "leaves indices below target unchanged" do
      # subst(Var(0), 1, Lit(42)) = Var(0)
      assert Core.subst({:var, 0}, 1, {:lit, 42}) == {:var, 0}
    end

    test "substitution under lambda shifts replacement" do
      # subst(Lam(ω, Var(1)), 0, Lit(42)) = Lam(ω, Lit(42))
      # The Var(1) inside the lambda refers to index 0 in the outer scope.
      assert Core.subst({:lam, :omega, {:var, 1}}, 0, {:lit, 42}) ==
               {:lam, :omega, {:lit, 42}}
    end

    test "substitution under lambda preserves bound variable" do
      # subst(Lam(ω, Var(0)), 0, Lit(42)) = Lam(ω, Var(0))
      assert Core.subst({:lam, :omega, {:var, 0}}, 0, {:lit, 42}) ==
               {:lam, :omega, {:var, 0}}
    end

    test "substitution under pi" do
      # Domain is not under a binder, codomain is.
      assert Core.subst({:pi, :omega, {:var, 0}, {:var, 1}}, 0, {:lit, 42}) ==
               {:pi, :omega, {:lit, 42}, {:lit, 42}}
    end

    test "substitution in application" do
      assert Core.subst({:app, {:var, 0}, {:var, 1}}, 0, {:lit, 42}) ==
               {:app, {:lit, 42}, {:var, 0}}
    end

    test "substitution leaves literals unchanged" do
      assert Core.subst({:lit, 99}, 0, {:lit, 42}) == {:lit, 99}
    end

    test "substitution leaves builtins unchanged" do
      assert Core.subst({:builtin, :add}, 0, {:lit, 42}) == {:builtin, :add}
    end

    test "substitution leaves metas unchanged" do
      assert Core.subst({:meta, 0}, 0, {:lit, 42}) == {:meta, 0}

      assert Core.subst({:inserted_meta, 0, [true]}, 0, {:lit, 42}) ==
               {:inserted_meta, 0, [true]}
    end

    test "substitution leaves externs unchanged" do
      assert Core.subst({:extern, Enum, :map, 2}, 0, {:lit, 42}) == {:extern, Enum, :map, 2}
    end

    test "substitution in pair" do
      assert Core.subst({:pair, {:var, 0}, {:var, 1}}, 0, {:lit, 42}) ==
               {:pair, {:lit, 42}, {:var, 0}}
    end

    test "substitution in fst and snd" do
      assert Core.subst({:fst, {:var, 0}}, 0, {:lit, 42}) == {:fst, {:lit, 42}}
      assert Core.subst({:snd, {:var, 0}}, 0, {:lit, 42}) == {:snd, {:lit, 42}}
    end

    test "substitution in sigma" do
      assert Core.subst({:sigma, {:var, 0}, {:var, 1}}, 0, {:lit, 42}) ==
               {:sigma, {:lit, 42}, {:lit, 42}}
    end

    test "substitution in let" do
      assert Core.subst({:let, {:var, 0}, {:var, 1}}, 0, {:lit, 42}) ==
               {:let, {:lit, 42}, {:lit, 42}}
    end

    test "substitution through spanned" do
      span = Pentiment.Span.Byte.new(0, 5)

      assert Core.subst({:spanned, span, {:var, 0}}, 0, {:lit, 42}) ==
               {:spanned, span, {:lit, 42}}
    end

    test "substitution identity: subst(t, ix, Var(ix)) == t" do
      # Substituting a variable for itself is identity.
      term = {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}
      assert Core.subst(term, 0, {:var, 0}) == term
    end
  end

  # ============================================================================
  # Shifting
  # ============================================================================

  describe "shift/3" do
    test "shifts free variables" do
      assert Core.shift({:var, 0}, 1, 0) == {:var, 1}
      assert Core.shift({:var, 2}, 3, 0) == {:var, 5}
    end

    test "does not shift bound variables (below cutoff)" do
      assert Core.shift({:var, 0}, 1, 1) == {:var, 0}
      assert Core.shift({:var, 1}, 1, 2) == {:var, 1}
    end

    test "shifts at cutoff boundary" do
      assert Core.shift({:var, 2}, 1, 2) == {:var, 3}
      assert Core.shift({:var, 1}, 1, 2) == {:var, 1}
    end

    test "shift under lambda increments cutoff" do
      # Lam(ω, Var(1)) — Var(1) is free (refers outside lambda).
      # With cutoff 0, shift by 1 → Lam(ω, Var(2)).
      assert Core.shift({:lam, :omega, {:var, 1}}, 1, 0) ==
               {:lam, :omega, {:var, 2}}
    end

    test "shift under lambda preserves bound variable" do
      # Lam(ω, Var(0)) — Var(0) is the lambda-bound variable.
      assert Core.shift({:lam, :omega, {:var, 0}}, 1, 0) ==
               {:lam, :omega, {:var, 0}}
    end

    test "negative shift" do
      assert Core.shift({:var, 3}, -1, 0) == {:var, 2}
    end

    test "shift leaves non-variable terms unchanged" do
      assert Core.shift({:lit, 42}, 1, 0) == {:lit, 42}
      assert Core.shift({:builtin, :add}, 1, 0) == {:builtin, :add}
      assert Core.shift({:type, {:llit, 0}}, 1, 0) == {:type, {:llit, 0}}
    end

    test "shift in pair" do
      assert Core.shift({:pair, {:var, 0}, {:var, 1}}, 1, 0) ==
               {:pair, {:var, 1}, {:var, 2}}
    end

    test "shift in fst and snd" do
      assert Core.shift({:fst, {:var, 0}}, 1, 0) == {:fst, {:var, 1}}
      assert Core.shift({:snd, {:var, 0}}, 1, 0) == {:snd, {:var, 1}}
    end

    test "shift in sigma" do
      assert Core.shift({:sigma, {:var, 0}, {:var, 0}}, 1, 0) ==
               {:sigma, {:var, 1}, {:var, 0}}
    end

    test "shift in let" do
      assert Core.shift({:let, {:var, 0}, {:var, 0}}, 1, 0) ==
               {:let, {:var, 1}, {:var, 0}}
    end

    test "shift in pi" do
      assert Core.shift({:pi, :omega, {:var, 0}, {:var, 0}}, 1, 0) ==
               {:pi, :omega, {:var, 1}, {:var, 0}}
    end

    test "shift in spanned" do
      span = Pentiment.Span.Byte.new(0, 5)

      assert Core.shift({:spanned, span, {:var, 0}}, 1, 0) ==
               {:spanned, span, {:var, 1}}
    end

    test "shift leaves extern and meta unchanged" do
      assert Core.shift({:extern, Enum, :map, 2}, 1, 0) == {:extern, Enum, :map, 2}
      assert Core.shift({:meta, 0}, 1, 0) == {:meta, 0}
      assert Core.shift({:inserted_meta, 0, [true]}, 1, 0) == {:inserted_meta, 0, [true]}
    end

    test "shift roundtrip for closed terms" do
      # shift(shift(t, n, 0), -n, 0) == t for closed terms.
      term = {:lam, :omega, {:app, {:var, 0}, {:lit, 42}}}
      assert Core.shift(Core.shift(term, 5, 0), -5, 0) == term
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "substitution identity: subst(t, ix, Var(ix)) == t for any leaf term" do
      check all(ix <- positive_integer()) do
        for term <- [{:lit, 42}, {:builtin, :add}, {:type, {:llit, 0}}, {:meta, 0}] do
          assert Core.subst(term, ix, {:var, ix}) == term
        end
      end
    end

    property "shift roundtrip: shift(shift(t, n, 0), -n, 0) == t for leaf terms" do
      check all(n <- positive_integer()) do
        for term <- [{:lit, 42}, {:builtin, :add}, {:type, {:llit, 0}}] do
          assert Core.shift(Core.shift(term, n, 0), -n, 0) == term
        end
      end
    end

    property "shift roundtrip for closed lambda" do
      check all(n <- integer(1..100)) do
        # Lam(ω, Var(0)) is closed — the variable is bound.
        term = {:lam, :omega, {:var, 0}}
        assert Core.shift(Core.shift(term, n, 0), -n, 0) == term
      end
    end

    property "well-scoped terms have all indices < context depth" do
      check all(
              depth <- integer(1..10),
              term <- well_scoped_term(depth)
            ) do
        assert all_indices_in_scope?(term, depth)
      end
    end

    property "substitution preserves well-scopedness" do
      check all(
              depth <- integer(1..10),
              term <- well_scoped_term(depth),
              replacement <- well_scoped_term(depth - 1)
            ) do
        # Substituting at index 0 removes one binding, so result is scoped to depth - 1.
        result = Core.subst(term, 0, replacement)
        assert all_indices_in_scope?(result, depth - 1)
      end
    end

    property "shift preserves well-scopedness (increases depth)" do
      check all(
              depth <- integer(1..10),
              term <- well_scoped_term(depth),
              n <- integer(1..5)
            ) do
        result = Core.shift(term, n, 0)
        assert all_indices_in_scope?(result, depth + n)
      end
    end
  end

  # ============================================================================
  # Generators
  # ============================================================================

  # Generate a well-scoped core term where all variable indices are < depth.
  # Uses sized recursion with proper depth tracking through binders.
  defp well_scoped_term(depth, max_size \\ 4)

  defp well_scoped_term(depth, _max_size) when depth <= 0 do
    leaf_term()
  end

  defp well_scoped_term(depth, max_size) do
    StreamData.sized(fn size ->
      well_scoped_term_sized(depth, min(size, max_size))
    end)
  end

  defp well_scoped_term_sized(depth, 0) do
    base_term(depth)
  end

  defp well_scoped_term_sized(depth, size) when depth <= 0 do
    well_scoped_term_sized(depth, 0)
    |> StreamData.resize(size)
  end

  defp well_scoped_term_sized(depth, size) do
    child_size = div(size, 2)

    StreamData.one_of([
      # Leaves and variables (no recursion).
      base_term(depth),
      # Lam: body is scoped to depth + 1.
      StreamData.bind(mult_gen(), fn m ->
        StreamData.map(well_scoped_term_sized(depth + 1, child_size), fn body ->
          {:lam, m, body}
        end)
      end),
      # App: both subterms at same depth.
      StreamData.bind(well_scoped_term_sized(depth, child_size), fn f ->
        StreamData.map(well_scoped_term_sized(depth, child_size), fn a ->
          {:app, f, a}
        end)
      end),
      # Pair: both subterms at same depth.
      StreamData.bind(well_scoped_term_sized(depth, child_size), fn a ->
        StreamData.map(well_scoped_term_sized(depth, child_size), fn b ->
          {:pair, a, b}
        end)
      end),
      # Fst / Snd.
      StreamData.map(well_scoped_term_sized(depth, child_size), &{:fst, &1}),
      StreamData.map(well_scoped_term_sized(depth, child_size), &{:snd, &1}),
      # Pi: domain at depth, codomain at depth + 1.
      StreamData.bind(mult_gen(), fn m ->
        StreamData.bind(well_scoped_term_sized(depth, child_size), fn dom ->
          StreamData.map(well_scoped_term_sized(depth + 1, child_size), fn cod ->
            {:pi, m, dom, cod}
          end)
        end)
      end),
      # Sigma: first at depth, second at depth + 1.
      StreamData.bind(well_scoped_term_sized(depth, child_size), fn a ->
        StreamData.map(well_scoped_term_sized(depth + 1, child_size), fn b ->
          {:sigma, a, b}
        end)
      end),
      # Let: definition at depth, body at depth + 1.
      StreamData.bind(well_scoped_term_sized(depth, child_size), fn d ->
        StreamData.map(well_scoped_term_sized(depth + 1, child_size), fn b ->
          {:let, d, b}
        end)
      end)
    ])
  end

  defp base_term(depth) when depth <= 0, do: leaf_term()

  defp base_term(depth) do
    StreamData.one_of([
      leaf_term(),
      StreamData.map(StreamData.integer(0..(depth - 1)), &{:var, &1})
    ])
  end

  defp leaf_term do
    StreamData.one_of([
      StreamData.map(StreamData.integer(), &{:lit, &1}),
      StreamData.constant({:builtin, :Int}),
      StreamData.constant({:type, {:llit, 0}}),
      StreamData.constant({:meta, 0})
    ])
  end

  defp mult_gen do
    StreamData.member_of([:zero, :omega])
  end

  # Check that every {:var, ix} in a term has ix < depth,
  # accounting for binders that increase the scope.
  defp all_indices_in_scope?(term, depth) do
    do_check_scope(term, depth)
  end

  defp do_check_scope({:var, ix}, depth), do: ix < depth
  defp do_check_scope({:lam, _, body}, depth), do: do_check_scope(body, depth + 1)

  defp do_check_scope({:app, f, a}, depth),
    do: do_check_scope(f, depth) and do_check_scope(a, depth)

  defp do_check_scope({:pi, _, dom, cod}, depth),
    do: do_check_scope(dom, depth) and do_check_scope(cod, depth + 1)

  defp do_check_scope({:sigma, a, b}, depth),
    do: do_check_scope(a, depth) and do_check_scope(b, depth + 1)

  defp do_check_scope({:pair, a, b}, depth),
    do: do_check_scope(a, depth) and do_check_scope(b, depth)

  defp do_check_scope({:fst, e}, depth), do: do_check_scope(e, depth)
  defp do_check_scope({:snd, e}, depth), do: do_check_scope(e, depth)

  defp do_check_scope({:let, d, b}, depth),
    do: do_check_scope(d, depth) and do_check_scope(b, depth + 1)

  defp do_check_scope({:spanned, _, inner}, depth), do: do_check_scope(inner, depth)
  defp do_check_scope(_, _depth), do: true

  # ============================================================================
  # ADT-related operations
  # ============================================================================

  describe "ADT constructors" do
    test "global/3 constructs a global reference" do
      assert Core.global(MyModule, :my_fun, 2) == {:global, MyModule, :my_fun, 2}
    end
  end

  describe "subst/3 for ADT terms" do
    test "substitution through :erased returns :erased" do
      assert Core.subst(:erased, 0, {:lit, 1}) == :erased
    end

    test "substitution through {:data, name, args}" do
      term = {:data, :Maybe, [{:var, 0}, {:lit, 42}]}

      assert Core.subst(term, 0, {:lit, 99}) ==
               {:data, :Maybe, [{:lit, 99}, {:lit, 42}]}
    end

    test "substitution through {:con, type_name, con_name, args}" do
      term = {:con, :Maybe, :Just, [{:var, 0}]}

      assert Core.subst(term, 0, {:lit, 7}) ==
               {:con, :Maybe, :Just, [{:lit, 7}]}
    end

    test "substitution through {:record_proj, field, expr}" do
      term = {:record_proj, :name, {:var, 0}}

      assert Core.subst(term, 0, {:lit, "alice"}) ==
               {:record_proj, :name, {:lit, "alice"}}
    end

    test "substitution through {:case, ...} with constructor branch" do
      # Constructor branch with arity 2 shifts replacement twice.
      term =
        {:case, {:var, 0},
         [
           {:Just, 1, {:var, 1}},
           {:Nothing, 0, {:lit, 0}}
         ]}

      result = Core.subst(term, 0, {:lit, 42})

      # Scrutinee: Var(0) -> Lit(42).
      # {:Just, 1, body}: target becomes 0+1=1, replacement shifted once.
      #   Var(1) at target 1 gets replaced with shifted Lit(42) = Lit(42).
      # {:Nothing, 0, body}: target stays 0, replacement not shifted.
      #   Lit(0) is unchanged.
      assert {:case, {:lit, 42}, branches} = result
      assert [{:Just, 1, {:lit, 42}}, {:Nothing, 0, {:lit, 0}}] = branches
    end
  end

  describe "shift/3 for ADT terms" do
    test "shift through {:data, name, args}" do
      term = {:data, :Maybe, [{:var, 0}, {:var, 1}]}

      assert Core.shift(term, 1, 0) ==
               {:data, :Maybe, [{:var, 1}, {:var, 2}]}
    end

    test "shift through {:con, type_name, con_name, args}" do
      term = {:con, :Maybe, :Just, [{:var, 0}]}

      assert Core.shift(term, 2, 0) ==
               {:con, :Maybe, :Just, [{:var, 2}]}
    end

    test "shift through {:record_proj, field, expr}" do
      term = {:record_proj, :name, {:var, 0}}

      assert Core.shift(term, 1, 0) ==
               {:record_proj, :name, {:var, 1}}
    end

    test "shift through {:case, ...} with constructor branch" do
      # Constructor branch with arity 2: cutoff increases by arity inside body.
      term =
        {:case, {:var, 0},
         [
           {:Just, 2, {:var, 2}},
           {:Nothing, 0, {:var, 0}}
         ]}

      result = Core.shift(term, 1, 0)

      # Scrutinee: Var(0) at cutoff 0 -> Var(1).
      # {:Just, 2, Var(2)}: cutoff becomes 0+2=2, Var(2) >= 2 -> Var(3).
      # {:Nothing, 0, Var(0)}: cutoff stays 0, Var(0) >= 0 -> Var(1).
      assert {:case, {:var, 1}, branches} = result
      assert [{:Just, 2, {:var, 3}}, {:Nothing, 0, {:var, 1}}] = branches
    end
  end
end
