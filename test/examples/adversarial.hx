# Adversarial parsing tests.

# Block where unary minus starts the next expression after newline.
# This should parse as two separate expressions: `x` then `-1`.
def block_minus(x : Int) : Int do
  x
  -1
end

# Annotation : in expression vs param position.
# (x : Int) as an annotation expression.
def ann_expr : Int do
  let r = (42 : Int)
  r
end

# Erased binder in expression position.
def erased_binder_expr : (0 n : Nat) -> Int do
  fn(n : Nat) -> 0 end
end

# Implicit binder in expression position.
def implicit_binder_expr : {a : Type} -> a -> a do
  fn(x : a) -> x end
end

# Refinement type with complex predicate.
def complex_refinement(x : {n : Int | n > 0 && n < 100 || n == -1}) : Int do
  x
end

# Pipe chain into higher-order.
def pipe_higher(x : Int) : Int do
  x |> inc |> double
end

# Nested case in let value.
def let_nested_case(x : Int, y : Int) : Int do
  let a = case x do
    0 -> case y do
      0 -> 0
      _ -> y
    end
    _ -> x
  end
  a
end

# If in case branch.
def if_in_case(x : Int) : Int do
  case x do
    0 -> if true do 100 else 200 end
    n -> n
  end
end

# Multiple defs with same name (parser should accept, type checker rejects).
def dup(x : Int) : Int do
  x
end

def dup(x : Int) : Int do
  x + 1
end

# Type with many constructors.
type Color
  | red
  | green
  | blue
  | yellow
  | cyan
  | magenta
  | white
  | black
  | rgb(Int, Int, Int)
  | rgba(Int, Int, Int, Int)
  | named(String)

# Record with single field.
record Wrapper(a : Type)
  : value : a

# Class with single method.
class Default(a : Type) do
  default_val : a
end

# Instance with single method.
instance Default(Int) do
  def default_val : Int do
    0
  end
end
