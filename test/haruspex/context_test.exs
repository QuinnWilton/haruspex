defmodule Haruspex.ContextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Haruspex.Context
  alias Haruspex.Value

  # ============================================================================
  # Construction
  # ============================================================================

  describe "empty/0" do
    test "has level 0" do
      assert Context.level(Context.empty()) == 0
    end

    test "has no bindings" do
      assert Context.names(Context.empty()) == []
    end

    test "has empty environment" do
      assert Context.env(Context.empty()) == []
    end
  end

  # ============================================================================
  # Extend
  # ============================================================================

  describe "extend/4" do
    test "increases level by 1" do
      ctx = Context.empty() |> Context.extend(:x, vtype0(), :omega)
      assert Context.level(ctx) == 1
    end

    test "adds binding with correct name" do
      ctx = Context.empty() |> Context.extend(:x, vtype0(), :omega)
      assert Context.lookup_name(ctx, 0) == :x
    end

    test "adds binding with correct type" do
      type = Value.vbuiltin(:Int)
      ctx = Context.empty() |> Context.extend(:x, type, :omega)
      assert Context.lookup_type(ctx, 0) == type
    end

    test "adds binding with correct multiplicity" do
      ctx = Context.empty() |> Context.extend(:x, vtype0(), :zero)
      assert Context.lookup_mult(ctx, 0) == :zero
    end

    test "extends env with fresh variable" do
      ctx = Context.empty() |> Context.extend(:x, vtype0(), :omega)
      [fresh | _] = Context.env(ctx)
      assert {:vneutral, _, {:nvar, 0}} = fresh
    end

    test "multiple extends give correct indices" do
      ctx =
        Context.empty()
        |> Context.extend(:x, Value.vbuiltin(:Int), :omega)
        |> Context.extend(:y, Value.vbuiltin(:String), :omega)
        |> Context.extend(:z, Value.vbuiltin(:Float), :zero)

      assert Context.level(ctx) == 3

      # Index 0 is the most recent binding (z).
      assert Context.lookup_name(ctx, 0) == :z
      assert Context.lookup_type(ctx, 0) == Value.vbuiltin(:Float)
      assert Context.lookup_mult(ctx, 0) == :zero

      # Index 1 is y.
      assert Context.lookup_name(ctx, 1) == :y
      assert Context.lookup_type(ctx, 1) == Value.vbuiltin(:String)

      # Index 2 is x.
      assert Context.lookup_name(ctx, 2) == :x
      assert Context.lookup_type(ctx, 2) == Value.vbuiltin(:Int)
    end
  end

  # ============================================================================
  # Extend with definition
  # ============================================================================

  describe "extend_def/5" do
    test "adds binding with definition value" do
      def_val = Value.vlit(42)
      ctx = Context.empty() |> Context.extend_def(:x, Value.vbuiltin(:Int), :omega, def_val)

      assert Context.level(ctx) == 1
      assert Context.lookup_name(ctx, 0) == :x
    end

    test "uses definition value in env (not fresh variable)" do
      def_val = Value.vlit(42)
      ctx = Context.empty() |> Context.extend_def(:x, Value.vbuiltin(:Int), :omega, def_val)

      [env_val | _] = Context.env(ctx)
      assert env_val == def_val
    end
  end

  # ============================================================================
  # Usage tracking
  # ============================================================================

  describe "use_var/2" do
    test "increments usage counter" do
      ctx =
        Context.empty()
        |> Context.extend(:x, vtype0(), :omega)
        |> Context.use_var(0)

      assert Context.check_usage(ctx, 0) == :ok
    end

    test "increments multiple times" do
      ctx =
        Context.empty()
        |> Context.extend(:x, vtype0(), :zero)
        |> Context.use_var(0)
        |> Context.use_var(0)

      assert {:error, {:multiplicity_violation, :x, :zero, 2}} = Context.check_usage(ctx, 0)
    end
  end

  describe "check_usage/2" do
    test "omega multiplicity allows any usage" do
      ctx = Context.empty() |> Context.extend(:x, vtype0(), :omega)
      assert Context.check_usage(ctx, 0) == :ok

      ctx = ctx |> Context.use_var(0) |> Context.use_var(0) |> Context.use_var(0)
      assert Context.check_usage(ctx, 0) == :ok
    end

    test "zero multiplicity with zero usage passes" do
      ctx = Context.empty() |> Context.extend(:x, vtype0(), :zero)
      assert Context.check_usage(ctx, 0) == :ok
    end

    test "zero multiplicity with non-zero usage fails" do
      ctx =
        Context.empty()
        |> Context.extend(:x, vtype0(), :zero)
        |> Context.use_var(0)

      assert {:error, {:multiplicity_violation, :x, :zero, 1}} = Context.check_usage(ctx, 0)
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  describe "names/1" do
    test "returns names in level order (oldest first)" do
      ctx =
        Context.empty()
        |> Context.extend(:a, vtype0(), :omega)
        |> Context.extend(:b, vtype0(), :omega)
        |> Context.extend(:c, vtype0(), :omega)

      assert Context.names(ctx) == [:a, :b, :c]
    end
  end

  describe "env/1" do
    test "returns env with most recent binding first" do
      ctx =
        Context.empty()
        |> Context.extend(:x, vtype0(), :omega)
        |> Context.extend(:y, vtype0(), :omega)

      env = Context.env(ctx)
      assert length(env) == 2

      # Most recent (y) is at level 1.
      assert {:vneutral, _, {:nvar, 1}} = hd(env)
    end
  end

  # ============================================================================
  # Property tests
  # ============================================================================

  describe "properties" do
    property "level equals number of extends" do
      check all(n <- integer(0..20)) do
        ctx =
          Enum.reduce(0..(n - 1)//1, Context.empty(), fn i, ctx ->
            name = String.to_atom("x#{i}")
            Context.extend(ctx, name, vtype0(), :omega)
          end)

        assert Context.level(ctx) == n
      end
    end

    property "env length equals level" do
      check all(n <- integer(0..20)) do
        ctx =
          Enum.reduce(0..(n - 1)//1, Context.empty(), fn i, ctx ->
            name = String.to_atom("x#{i}")
            Context.extend(ctx, name, vtype0(), :omega)
          end)

        assert length(Context.env(ctx)) == Context.level(ctx)
      end
    end

    property "lookup_type at any valid index does not crash" do
      check all(n <- integer(1..20)) do
        ctx =
          Enum.reduce(0..(n - 1)//1, Context.empty(), fn i, ctx ->
            name = String.to_atom("x#{i}")
            Context.extend(ctx, name, vtype0(), :omega)
          end)

        for ix <- 0..(n - 1) do
          assert Context.lookup_type(ctx, ix)
        end
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp vtype0, do: Value.vtype({:llit, 0})
end
