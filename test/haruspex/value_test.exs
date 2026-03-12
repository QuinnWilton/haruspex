defmodule Haruspex.ValueTest do
  use ExUnit.Case, async: true

  alias Haruspex.Value

  describe "value constructors" do
    test "vlam" do
      assert Value.vlam(:omega, [], {:var, 0}) == {:vlam, :omega, [], {:var, 0}}
    end

    test "vpi" do
      dom = Value.vtype({:llit, 0})
      assert Value.vpi(:omega, dom, [], {:var, 0}) == {:vpi, :omega, dom, [], {:var, 0}}
    end

    test "vsigma" do
      a = Value.vbuiltin(:Int)
      assert Value.vsigma(a, [], {:var, 0}) == {:vsigma, a, [], {:var, 0}}
    end

    test "vpair" do
      assert Value.vpair(Value.vlit(1), Value.vlit(2)) == {:vpair, {:vlit, 1}, {:vlit, 2}}
    end

    test "vtype" do
      assert Value.vtype({:llit, 0}) == {:vtype, {:llit, 0}}
    end

    test "vlit" do
      assert Value.vlit(42) == {:vlit, 42}
      assert Value.vlit("hello") == {:vlit, "hello"}
    end

    test "vbuiltin" do
      assert Value.vbuiltin(:Int) == {:vbuiltin, :Int}
      assert Value.vbuiltin(:add) == {:vbuiltin, :add}
    end

    test "vextern" do
      assert Value.vextern(Enum, :map, 2) == {:vextern, Enum, :map, 2}
    end

    test "vneutral" do
      type = Value.vbuiltin(:Int)
      ne = Value.nvar(0)
      assert Value.vneutral(type, ne) == {:vneutral, type, {:nvar, 0}}
    end
  end

  describe "neutral constructors" do
    test "nvar" do
      assert Value.nvar(0) == {:nvar, 0}
      assert Value.nvar(5) == {:nvar, 5}
    end

    test "napp" do
      assert Value.napp({:nvar, 0}, Value.vlit(42)) == {:napp, {:nvar, 0}, {:vlit, 42}}
    end

    test "nfst" do
      assert Value.nfst({:nvar, 0}) == {:nfst, {:nvar, 0}}
    end

    test "nsnd" do
      assert Value.nsnd({:nvar, 0}) == {:nsnd, {:nvar, 0}}
    end

    test "nmeta" do
      assert Value.nmeta(0) == {:nmeta, 0}
    end
  end

  describe "fresh_var/2" do
    test "creates a neutral variable at the given level" do
      type = Value.vbuiltin(:Int)
      assert Value.fresh_var(3, type) == {:vneutral, type, {:nvar, 3}}
    end
  end
end
