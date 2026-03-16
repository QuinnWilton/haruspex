defmodule Haruspex.TotalityTest do
  use ExUnit.Case, async: true

  alias Haruspex.Totality

  # Nat ADT: type Nat = zero | succ(Nat)
  @nat_decl %{
    name: :Nat,
    params: [],
    constructors: [
      %{name: :zero, fields: [], return_type: {:data, :Nat, []}, span: nil},
      %{name: :succ, fields: [{:data, :Nat, []}], return_type: {:data, :Nat, []}, span: nil}
    ],
    universe_level: {:llit, 0},
    span: nil
  }

  # List ADT: type List(a) = nil | cons(a, List(a))
  @list_decl %{
    name: :List,
    params: [{:a, {:type, {:llit, 0}}}],
    constructors: [
      %{name: nil, fields: [], return_type: {:data, :List, [{:var, 0}]}, span: nil},
      %{
        name: :cons,
        fields: [{:var, 0}, {:data, :List, [{:var, 0}]}],
        return_type: {:data, :List, [{:var, 0}]},
        span: nil
      }
    ],
    universe_level: {:llit, 0},
    span: nil
  }

  @adts %{Nat: @nat_decl, List: @list_decl}

  defp new_db do
    db = Roux.Database.new()
    Roux.Lang.register(db, Haruspex)
    db
  end

  defp set_source(db, uri, source) do
    Roux.Input.set(db, :source_text, uri, source)
  end

  # ============================================================================
  # Accepted: structural decrease
  # ============================================================================

  describe "accepted: structural decrease" do
    test "add(n : Nat, m : Nat) : Nat — decrease on first arg" do
      # def add(n : Nat, m : Nat) : Nat do
      #   case n do
      #     zero -> m
      #     succ(k) -> succ(add(k, m))
      #   end
      # end
      #
      # Under check_definition: add at ix 0, then lam(n), lam(m)
      # In body (under 2 lams): n=var(1), m=var(0), add=var(2)
      # In succ branch (arity 1): k=var(0), m=var(1), n=var(2), add=var(3)
      type = {:pi, :omega, {:data, :Nat, []}, {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}}}

      body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 1},
           [
             {:zero, 0, {:var, 0}},
             {:succ, 1, {:con, :Nat, :succ, [{:app, {:app, {:var, 3}, {:var, 0}}, {:var, 1}}]}}
           ]}}}

      assert :total = Totality.check_totality(:add, type, body, @adts)
    end

    test "length(xs : List(a)) : Nat — decrease on list arg" do
      # def length(xs : List(a)) : Nat do
      #   case xs do
      #     nil -> zero
      #     cons(_, rest) -> succ(length(rest))
      #   end
      # end
      #
      # Under check_definition: length at ix 0, then lam(xs)
      # In body (under 1 lam): xs=var(0), length=var(1)
      # In cons branch (arity 2): _=var(1), rest=var(0), xs=var(2), length=var(3)
      type = {:pi, :omega, {:data, :List, [{:var, 0}]}, {:data, :Nat, []}}

      body =
        {:lam, :omega,
         {:case, {:var, 0},
          [
            {nil, 0, {:con, :Nat, :zero, []}},
            {:cons, 2, {:con, :Nat, :succ, [{:app, {:var, 3}, {:var, 0}}]}}
          ]}}

      assert :total = Totality.check_totality(:length, type, body, @adts)
    end

    test "trivially total — no recursive calls" do
      type = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body = {:lam, :omega, {:var, 0}}

      assert :total = Totality.check_totality(:id, type, body, @adts)
    end

    test "non-recursive function with case is total" do
      # def is_zero(n : Nat) : Bool do case n do zero -> true; succ(_) -> false end end
      type = {:pi, :omega, {:data, :Nat, []}, {:builtin, :Bool}}

      body =
        {:lam, :omega,
         {:case, {:var, 0},
          [
            {:zero, 0, {:lit, true}},
            {:succ, 1, {:lit, false}}
          ]}}

      assert :total = Totality.check_totality(:is_zero, type, body, @adts)
    end

    test "decrease on second parameter" do
      # def f(x : Int, n : Nat) : Int do
      #   case n do zero -> x; succ(k) -> f(x, k) end
      # end
      type =
        {:pi, :omega, {:builtin, :Int}, {:pi, :omega, {:data, :Nat, []}, {:builtin, :Int}}}

      body =
        {:lam, :omega,
         {:lam, :omega,
          {:case, {:var, 0},
           [
             {:zero, 0, {:var, 1}},
             {:succ, 1, {:app, {:app, {:var, 3}, {:var, 1}}, {:var, 0}}}
           ]}}}

      assert :total = Totality.check_totality(:f, type, body, @adts)
    end

    test "nested case: recursion on subterm of subterm" do
      # def depth(xs : List(a)) : Nat do
      #   case xs do
      #     nil -> zero
      #     cons(_, rest) ->
      #       case rest do
      #         nil -> succ(zero)
      #         cons(_, rest2) -> succ(succ(depth(rest2)))
      #       end
      #   end
      # end
      #
      # Under check_def: depth=var(0), lam(xs)
      # In body: xs=var(0), depth=var(1)
      # In outer cons branch (arity 2): _=var(1), rest=var(0), xs=var(2), depth=var(3)
      # rest is a subterm of xs. Case on rest:
      # In inner cons branch (arity 2): _=var(1), rest2=var(0), rest=var(2), ...depth=var(5)
      # rest2 is a subterm of rest, which is a subterm of xs.
      # Recursive call depth(rest2) = app(var(5), var(0))
      # rest2 at var(0) IS a subterm (introduced by case on rest, which is itself
      # a subterm tracked through the nested case on candidate param).
      type = {:pi, :omega, {:data, :List, [{:var, 0}]}, {:data, :Nat, []}}

      body =
        {:lam, :omega,
         {:case, {:var, 0},
          [
            {nil, 0, {:con, :Nat, :zero, []}},
            {
              :cons,
              2,
              # rest = var(0), case on rest
              {:case, {:var, 0},
               [
                 {nil, 0, {:con, :Nat, :succ, [{:con, :Nat, :zero, []}]}},
                 {
                   :cons,
                   2,
                   # rest2 = var(0), depth = var(5)
                   {:con, :Nat, :succ, [{:con, :Nat, :succ, [{:app, {:var, 5}, {:var, 0}}]}]}
                 }
               ]}
            }
          ]}}

      # This should be accepted because rest2 is a structural subterm.
      # The totality checker sees the outer case on xs (candidate param),
      # then inside that branch, rest (var 0) is a subterm. The inner case
      # is on rest, and rest2 (var 0 under inner branch) is also a subterm.
      assert :total = Totality.check_totality(:depth, type, body, @adts)
    end
  end

  # ============================================================================
  # Rejected: non-structural recursion
  # ============================================================================

  describe "rejected: non-structural recursion" do
    test "loop(n : Nat) : Nat — no decrease (same arg)" do
      # def loop(n : Nat) : Nat do loop(n) end
      # Under check_def: loop=var(0), then lam(n)
      # In body: n=var(0), loop=var(1)
      type = {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}}
      body = {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}

      assert {:not_total, {:no_decreasing_arg, :loop, nil}} =
               Totality.check_totality(:loop, type, body, @adts)
    end

    test "bad(n : Nat) : Nat — increase (succ(n))" do
      # def bad(n : Nat) : Nat do bad(succ(n)) end
      type = {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}}
      body = {:lam, :omega, {:app, {:var, 1}, {:con, :Nat, :succ, [{:var, 0}]}}}

      assert {:not_total, _} = Totality.check_totality(:bad, type, body, @adts)
    end

    test "nested(n : Nat) : Nat — nested recursion f(f(x))" do
      # def nested(n : Nat) : Nat do
      #   case n do zero -> zero; succ(k) -> nested(nested(k)) end
      # end
      # In succ branch: k=var(0), n=var(1), nested=var(2)
      # nested(nested(k)) = app(var(2), app(var(2), var(0)))
      # The arg to the OUTER call is app(var(2), var(0)) which is NOT a var — fails.
      type = {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}}

      body =
        {:lam, :omega,
         {:case, {:var, 0},
          [
            {:zero, 0, {:con, :Nat, :zero, []}},
            {:succ, 1, {:app, {:var, 2}, {:app, {:var, 2}, {:var, 0}}}}
          ]}}

      assert {:not_total, _} = Totality.check_totality(:nested, type, body, @adts)
    end

    test "recursion outside case" do
      # def bad(n : Nat) : Nat do
      #   let x = bad(n) in x
      # end
      type = {:pi, :omega, {:data, :Nat, []}, {:data, :Nat, []}}
      body = {:lam, :omega, {:let, {:app, {:var, 1}, {:var, 0}}, {:var, 0}}}

      assert {:not_total, _} = Totality.check_totality(:bad, type, body, @adts)
    end

    test "non-ADT parameter with recursion" do
      # def f(x : Int) : Int do f(x) end
      type = {:pi, :omega, {:builtin, :Int}, {:builtin, :Int}}
      body = {:lam, :omega, {:app, {:var, 1}, {:var, 0}}}

      assert {:not_total, {:no_decreasing_arg, :f, nil}} =
               Totality.check_totality(:f, type, body, @adts)
    end
  end

  # ============================================================================
  # Full pipeline integration
  # ============================================================================

  describe "full pipeline" do
    test "@total function passes check" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      type Nat = zero | succ(Nat)

      @total
      def add(n : Nat, m : Nat) : Nat do
        case n do
          zero -> m
          succ(k) -> succ(add(k, m))
        end
      end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :add})
    end

    test "@total on non-structural recursion fails check" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      type Nat = zero | succ(Nat)

      @total
      def loop(n : Nat) : Nat do loop(n) end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      result = Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :loop})
      assert {:error, {:no_decreasing_arg, :loop, nil}} = result
    end

    test "non-@total recursive function compiles fine" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      type Nat = zero | succ(Nat)

      def loop(n : Nat) : Nat do loop(n) end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      # Without @total, no totality check — type checking succeeds.
      {:ok, {_type, _body}} = Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :loop})
    end

    test "@total trivially total function passes" do
      db = new_db()

      set_source(db, "lib/test.hx", """
      @total
      def id(x : Int) : Int do x end
      """)

      {:ok, _} = Roux.Runtime.query(db, :haruspex_parse, "lib/test.hx")
      {:ok, _} = Roux.Runtime.query(db, :haruspex_check, {"lib/test.hx", :id})
    end
  end
end
