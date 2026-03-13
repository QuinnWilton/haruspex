# Probing parsing ambiguities.

# Empty argument list.
def call_no_args : Int do
  get_value()
end

# Dot chain then app then dot.
def dot_app_dot(m : Mod) : Int do
  m.sub.func(1).result
end

# Minus ambiguity: is the second line subtraction or unary minus?
# In a block, newline separates expressions, so second line is unary minus.
def minus_ambiguity(x : Int) : Int do
  let a = x + 1
  -a
end

# Atom in operator expressions.
def atom_equality : Bool do
  :ok == :ok
end

def atom_inequality : Bool do
  :ok != :error
end

# Multiple sequential expressions in a block.
def sequential(x : Int) : Int do
  inc(x)
  dec(x)
  x
end

# Case with arrow in branch body (function type).
# This tests that -> in the branch body is parsed as part of the expression,
# not as a new branch.
def case_arrow_body(x : Int) : Type do
  case x do
    0 -> Int -> Bool
    _ -> Int -> Int
  end
end

# Let chain where each value depends on previous.
def fibonacci_lets : Int do
  let a = 0
  let b = 1
  let c = a + b
  let d = b + c
  let e = c + d
  let f = d + e
  f
end

# Parenthesized pi type as a return type.
def return_pi : (Int -> Int) -> Int do
  fn(f : Int -> Int) -> f(0) end
end

# Nested application (constructor-like).
def app_chain : List(List(Int)) do
  cons(cons(1, nil), nil)
end

# Sigma as return type.
def return_sigma : (x : Int, Bool) do
  unit
end

# Variable decl followed immediately by def.
@implicit {t : Type}

def use_variable(x : t) : t do
  x
end

# Mutual block with type and def.
mutual do
  type Even =
    | even_zero
    | even_succ(Odd)

  type Odd =
    | odd_succ(Even)

  def is_even(n : Nat) : Bool do
    case n do
      zero -> true
      succ(pred) -> is_odd(pred)
    end
  end

  def is_odd(n : Nat) : Bool do
    case n do
      zero -> false
      succ(pred) -> is_even(pred)
    end
  end
end
