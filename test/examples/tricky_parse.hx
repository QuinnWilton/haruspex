# Tricky parsing scenarios designed to probe edge cases.

# Case branch body with let.
def case_with_let(x : Int) : Int do
  case x do
    0 ->
      let y = 1
      y + 1
    _ -> x
  end
end

# Case where branch body is an if.
def case_with_if(x : Int) : Int do
  case x do
    0 -> if true do 1 else 2 end
    _ -> x
  end
end

# If where then-branch is a case.
def if_with_case(x : Int) : Int do
  if x > 0 do
    case x do
      1 -> 10
      _ -> 20
    end
  else
    0
  end
end

# Let where value is a case.
def let_case(x : Int) : Int do
  let result = case x do
    0 -> 1
    _ -> x
  end
  result + 1
end

# Let where value is an if.
def let_if(x : Int) : Int do
  let result = if x > 0 do x else 0 - x end
  result
end

# Let where value is a lambda.
def let_lambda : Int -> Int do
  let f = fn(x : Int) -> x + 1 end
  f
end

# Annotation used as pi binder (the (name : Type) -> Body pattern).
def pi_binder : (x : Int) -> Int do
  fn(x : Int) -> x end
end

# Multiple pi binders chained.
def multi_pi : (x : Int) -> (y : Int) -> (z : Int) -> Int do
  fn(x : Int) -> fn(y : Int) -> fn(z : Int) -> x + y + z end end end
end

# Hole/wildcard in expression position.
def with_hole({a : Type}) : a do
  _
end

# Type used as expression (upper ident).
def type_expr : Type do
  Int
end

# Application of constructor.
def make_pair(x : Int) : List(Int) do
  cons(x, nil)
end

# Nested constructors in expression.
def nested_cons : List(Int) do
  cons(1, cons(2, cons(3, nil)))
end
