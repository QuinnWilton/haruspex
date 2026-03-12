# Declaration edge cases: records, classes, instances, imports, annotations.

import Data.Nat
import Data.List.Utils
import Very.Deep.Module.Path

import Data.Option, open: true
import Data.Either, open: [left, right]

# Record with many fields.
record Point3D
  : x : Float
  , y : Float
  , z : Float

record Config(a : Type)
  : name : String
  , value : a
  , enabled : Bool
  , priority : Int

# Class with many methods.
class Show(a : Type) do
  show : a -> String
  show_list : List(a) -> String
end

class Eq(a : Type) do
  eq : a -> a -> Bool
  neq : a -> a -> Bool
end

# Instance with implementations.
instance Show(Int) do
  def show(x : Int) : String do
    "int"
  end

  def show_list(xs : List(Int)) : String do
    "list"
  end
end

instance Eq(Bool) do
  def eq(a : Bool, b : Bool) : Bool do
    case a do
      true -> b
      false -> not b
    end
  end

  def neq(a : Bool, b : Bool) : Bool do
    not eq(a, b)
  end
end

# Multiple annotations on one def.
@total
@private
def secret_add(x : Int, y : Int) : Int do
  x + y
end

@extern Kernel.length/1
def elixir_length(xs : List(a)) : Int do
  xs
end

@total
@extern Kernel.abs/1
def my_abs(x : Int) : Int do
  if x >= 0 do x else 0 - x end
end

# Unicode and escape sequences in strings.
def string_edge : String do
  ""
end

def escape_sequences : String do
  "hello\nworld\t\"quoted\"\r\n\\backslash\0null"
end
