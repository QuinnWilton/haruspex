# Numeric edge cases and dot access chains.

# Zero.
def zero_literal : Int do
  0
end

# Large number.
def big_number : Int do
  999999999
end

# Float literals.
def float_literals : Float do
  0.0
end

def small_float : Float do
  0.001
end

# Unary minus on literal.
def neg_literal : Int do
  -42
end

# Unary minus on float.
def neg_float : Float do
  -3.14
end

# Double negation.
def double_neg(x : Int) : Int do
  - -x
end

# Dot access chain.
def dot_chain(r : Record) : Int do
  r.x
end

def dot_chain2(r : Outer) : Int do
  r.inner.value
end

# Dot then application.
def dot_app(m : Module) : Int do
  m.func(42)
end

# Chained dot and application.
def chain_dot_app(m : Module) : Int do
  m.sub.func(1, 2)
end

# Parenthesized expression as function.
def paren_app(f : Int -> Int, g : Int -> Int, x : Int) : Int do
  f(g(x))
end

# Nested arithmetic.
def nested_arith(a : Int, b : Int, c : Int) : Int do
  (a + b) * (c - a) / (b + 1)
end

# Mixed comparison and boolean.
def complex_bool(x : Int, y : Int, z : Int) : Bool do
  (x > y && y > z) || (x == z && z != 0)
end

# Pipe into application.
def pipe_into_app(x : Int) : Int do
  x |> double |> add(1)
end
