# Lambda and closure edge cases.

# Lambda returning lambda.
def make_adder(x : Int) : Int -> Int do
  fn(y : Int) -> x + y end
end

# Lambda with many params.
def multi_param_lambda : Int -> Int -> Int -> Int -> Int do
  fn(a : Int, b : Int, c : Int, d : Int) -> a + b + c + d end
end

# Immediately-invoked lambda (via let).
def iife(x : Int) : Int do
  let f = fn(n : Int) -> n * 2 end
  f(x)
end

# Lambda in argument position.
def apply_fn(x : Int) : Int do
  map_int(x, fn(n : Int) -> n + 1 end)
end

# Nested lambdas.
def compose : (Int -> Int) -> (Int -> Int) -> Int -> Int do
  fn(f : Int -> Int) ->
    fn(g : Int -> Int) ->
      fn(x : Int) ->
        f(g(x))
      end
    end
  end
end

# Let inside let value expression.
def let_in_let(x : Int) : Int do
  let a = if x > 0 do x else 0 - x end
  let b = a + 1
  b
end
