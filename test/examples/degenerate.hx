# Degenerate and minimal constructs.

# Def with body that is just a literal.
def always_zero : Int do
  0
end

def always_true : Bool do
  true
end

def always_atom : Atom do
  :ok
end

def always_string : String do
  "hello"
end

# Empty params.
def no_params : Int do
  42
end

# Single-branch case.
def single_branch(x : Int) : Int do
  case x do
    n -> n
  end
end

# Trailing commas in args and params.
def trailing_comma_params(x : Int, y : Int,) : Int do
  add(x, y,)
end

# Let chains.
def many_lets(x : Int) : Int do
  let a = x
  let b = a + 1
  let c = b + 2
  let d = c + 3
  let e = d + 4
  e
end

# Multiple expressions in block (desugared as let _ = ...).
def multi_expr_block(x : Int) : Int do
  noop(x)
  noop(x)
  noop(x)
  x
end

# Def with no return type annotation.
def no_return_type(x : Int) do
  x
end

# Type with single constructor.
type Unit = unit

# Type with no type params.
type Void = absurd

# Empty mutual block.
mutual do
end
